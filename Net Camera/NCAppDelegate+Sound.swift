import AVFoundation
import Cocoa

// MARK: - Sound tap

/// Where captured sound goes: filtered once, then played and recorded.
///
/// Every captured buffer has its constant offset taken out (see
/// `NCDCBlocker`) before anything hears it, so the speakers and a recording
/// get the same sound. It is played while monitoring is on, and handed to
/// whatever recording is running.
///
/// Sound arrives on the tap's own queue while monitoring and recordings are
/// switched on the main thread, so those are handed over under a lock; the
/// filter, the converter and the monitor are only ever touched on the queue.
final class NCSoundTap: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    let queue: DispatchQueue = DispatchQueue(label: "com.xalior.NetCamera.sound")

    private let lock = NSLock()
    private var recorder: NCMovieRecorder?
    private var format: CMAudioFormatDescription?
    private var isMonitoring = false
    private var removesOffset = true

    // Sound queue only.
    private var blocker = NCDCBlocker()
    private var converter: AVAudioConverter?
    private let monitor = NCSoundMonitor()

    /// The format of the latest filtered sound, which is what a recording's
    /// sound track receives, or `nil` before any has arrived.
    var currentFormat: CMAudioFormatDescription? {
        lock.lock()
        defer { lock.unlock() }
        return format
    }

    func setRecorder(_ recorder: NCMovieRecorder?) {
        lock.lock()
        defer { lock.unlock() }
        self.recorder = recorder
    }

    func setMonitoring(_ monitoring: Bool) {
        lock.lock()
        let wasMonitoring = isMonitoring
        isMonitoring = monitoring
        lock.unlock()
        if wasMonitoring && !monitoring {
            queue.async { [monitor] in monitor.stop() }
        }
    }

    func setRemovesOffset(_ removes: Bool) {
        lock.lock()
        let wasRemoving = removesOffset
        removesOffset = removes
        lock.unlock()
        // Coming back on, the filter starts from the level the sound is at
        // then, rather than from wherever it was left.
        if removes && !wasRemoving {
            queue.async { [self] in blocker.reset() }
        }
    }

    /// Forgets everything about the sound so far, for when the input changes
    /// or goes.
    func reset() {
        lock.lock()
        format = nil
        lock.unlock()
        queue.async { [self] in
            blocker.reset()
            converter = nil
            monitor.stop()
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let sound = NCSoundBuffers.pcmBuffer(from: sampleBuffer, converter: &converter)
        else { return }

        lock.lock()
        format = sound.format.formatDescription
        let recorder = self.recorder
        let monitoring = isMonitoring
        let removing = removesOffset
        lock.unlock()

        if removing {
            blocker.process(sound)
        }

        if monitoring {
            monitor.play(sound)
        }
        if let recorder,
            let filtered = NCSoundBuffers.sampleBuffer(
                from: sound, at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        {
            recorder.receiveSound(filtered)
        }
    }
}

// MARK: - Sound

/// The sound input: chosen per profile from Camera › Sound Input, heard
/// through the speakers while Monitor Sound is on, and recorded alongside the
/// picture. With no input chosen there is no sound anywhere.
///
/// The sound is taken in the same capture session as the picture, so the two
/// carry times from the same clock and a recording keeps them together without
/// any lining up of its own.
extension NCAppDelegate {
    // MARK: - Devices

    /// Every sound input macOS offers.
    func soundDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        ).devices
    }

    /// The sound input the profile names, if it is connected.
    private var wantedSoundDevice: AVCaptureDevice? {
        let name = NCSettingsManager.shared.soundInputName
        guard !name.isEmpty else { return nil }
        return soundDevices().first { $0.localizedName == name }
    }

    // MARK: - Session

    /// Brings the capture session's sound into line with the profile and with
    /// Monitor Sound. Cheap when nothing has changed, so it can be called
    /// whenever anything might have: a new session, a profile, a hot-plug.
    func updateSound() {
        guard let session = self.captureSession else { return }
        var device = self.wantedSoundDevice

        if device != nil {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                break
            case .notDetermined:
                // Asked once; the answer comes back here.
                AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                    DispatchQueue.main.async {
                        NSLog("Sound input access was %@", granted ? "granted" : "refused")
                        self?.updateSound()
                    }
                }
                device = nil
            default:
                reportSoundRefused()
                device = nil
            }
        }

        if self.soundInput?.device != device {
            session.beginConfiguration()
            if let old = self.soundInput {
                session.removeInput(old)
                self.soundInput = nil
            }
            self.soundTap.reset()
            if let device {
                attachSound(device, to: session)
            }
            session.commitConfiguration()

            // Reconfiguring the session puts the camera back on the session preset's format,
            // throwing away the resolution chosen for it: measured with a capture dongle on
            // 720x576, which came back at 1920x1080. So the choice is put back, and the window
            // relocked to it.
            if let camera = self.activeCaptureDevice {
                self.applyChosenResolution(to: camera)
                self.fixAspectRatio()
                self.refreshSourceMenuState()
            }
        }

        self.soundTap.setMonitoring(
            self.soundInput != nil && NCSettingsManager.shared.monitorsSound)
        self.soundTap.setRemovesOffset(NCSettingsManager.shared.removesSoundOffset)
    }

    /// Adds a sound input to the session, with the output that hands its
    /// sound to the tap the first time. Called inside a configuration block.
    private func attachSound(_ device: AVCaptureDevice, to session: AVCaptureSession) {
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                NSLog("The session will not take %@ as a sound input", device.localizedName)
                return
            }
            session.addInput(input)
            self.soundInput = input
        } catch {
            NSLog(
                "Could not open %@ for sound: %@", device.localizedName,
                error.localizedDescription)
            return
        }

        if self.soundDataOutput == nil {
            let data = AVCaptureAudioDataOutput()
            // Float, one buffer per channel: what the filter and the player work in,
            // so the sound needs no converting on its way through.
            data.audioSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: true,
            ]
            data.setSampleBufferDelegate(self.soundTap, queue: self.soundTap.queue)
            if session.canAddOutput(data) {
                session.addOutput(data)
                self.soundDataOutput = data
            }
        }
        NSLog("Sound input is now %@", device.localizedName)
    }

    /// Forgets the session's sound, which goes with the session itself.
    func forgetSound() {
        self.soundDataOutput?.setSampleBufferDelegate(nil, queue: nil)
        self.soundInput = nil
        self.soundDataOutput = nil
        self.soundTap.setMonitoring(false)
        self.soundTap.reset()
    }

    /// Says once why there is no sound when access has been refused, rather
    /// than leaving a sound input chosen that does nothing.
    private func reportSoundRefused() {
        guard !self.hasReportedSoundRefused else { return }
        self.hasReportedSoundRefused = true
        self.errorMessage(
            message:
                "Net Camera is not allowed to use sound inputs, so there is no sound. To allow it, "
                + "open System Settings, then Privacy & Security, then Microphone, and switch it "
                + "on for Net Camera.")
    }

    // MARK: - Menu

    /// Puts Sound Input into the Camera menu, after Select Source.
    func installSoundMenu() {
        guard let cameraMenu = self.selectSourceMenu.menu else { return }
        let index = cameraMenu.index(of: self.selectSourceMenu) + 1
        let menu = NSMenu(title: "Sound Input")
        menu.delegate = self
        let item = NSMenuItem(title: "Sound Input", action: nil, keyEquivalent: "")
        item.submenu = menu
        cameraMenu.insertItem(item, at: index)
    }

    /// Built afresh each time it opens, so inputs plugged in since are there.
    func updateSoundMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let chosen = NCSettingsManager.shared.soundInputName

        let none = NSMenuItem(title: "None", action: #selector(chooseSoundInput(_:)), keyEquivalent: "")
        none.target = self
        none.representedObject = ""
        none.state = chosen.isEmpty ? .on : .off
        menu.addItem(none)

        let names = soundDevices().map(\.localizedName)
        for name in names {
            let item = NSMenuItem(title: name, action: #selector(chooseSoundInput(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
            item.state = name == chosen ? .on : .off
            menu.addItem(item)
        }
        // The profile's input, when it is not plugged in, so it is clear what
        // the profile wants and why there is no sound.
        if !chosen.isEmpty && !names.contains(chosen) {
            let missing = NSMenuItem(title: "\(chosen) (not connected)", action: nil, keyEquivalent: "")
            missing.state = .on
            missing.isEnabled = false
            menu.addItem(missing)
        }

        menu.addItem(.separator())
        let monitor = NSMenuItem(
            title: "Monitor Sound", action: #selector(toggleMonitorSound(_:)), keyEquivalent: "")
        monitor.target = self
        monitor.state = NCSettingsManager.shared.monitorsSound ? .on : .off
        menu.addItem(monitor)

        let offset = NSMenuItem(
            title: "Remove DC Offset", action: #selector(toggleRemoveSoundOffset(_:)),
            keyEquivalent: "")
        offset.target = self
        offset.state = NCSettingsManager.shared.removesSoundOffset ? .on : .off
        menu.addItem(offset)
    }

    @objc func toggleRemoveSoundOffset(_ sender: NSMenuItem) {
        NCSettingsManager.shared.setRemovesSoundOffset(
            !NCSettingsManager.shared.removesSoundOffset)
        updateSound()
    }

    @objc func chooseSoundInput(_ sender: NSMenuItem) {
        let name = sender.representedObject as? String ?? ""
        NSLog("Sound input chosen: %@", name.isEmpty ? "none" : name)
        // A new choice is worth explaining again if access is still refused.
        self.hasReportedSoundRefused = false
        NCSettingsManager.shared.setSoundInputName(name)
        updateSound()
    }

    @objc func toggleMonitorSound(_ sender: NSMenuItem) {
        NCSettingsManager.shared.setMonitorsSound(!NCSettingsManager.shared.monitorsSound)
        updateSound()
    }
}
