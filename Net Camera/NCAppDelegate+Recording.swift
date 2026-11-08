import AVFoundation
import Cocoa
import UniformTypeIdentifiers

// MARK: - Recording

/// Start Recording… and the recording options, in the Camera menu.
///
/// The file is chosen when the recording starts, not when it ends, so that
/// stopping is a single keystroke and a recording cut short by the picture
/// changing or the camera going away is already where the user wanted it.
extension NCAppDelegate: NSMenuDelegate {
    private var recordingOptions: NCRecordingOptions { NCSettingsManager.shared.recording }

    // MARK: - Menu

    /// Puts Start Recording… and Recording Options into the Camera menu, after
    /// Copy Picture.
    func installRecordingMenu() {
        guard let cameraMenu = self.selectSourceMenu.menu else { return }
        let anchor = cameraMenu.items.firstIndex { $0.action == #selector(copyPicture(_:)) }
        var index = anchor.map { $0 + 1 } ?? cameraMenu.items.count

        let record = NSMenuItem(
            title: "Start Recording…", action: #selector(toggleRecording(_:)), keyEquivalent: "R")
        record.keyEquivalentModifierMask = [.command]
        record.target = self
        cameraMenu.insertItem(record, at: index)
        self.recordMenuItem = record
        index += 1

        let options = NSMenu(title: "Recording Options")
        options.delegate = self
        let optionsItem = NSMenuItem(title: "Recording Options", action: nil, keyEquivalent: "")
        optionsItem.submenu = options
        cameraMenu.insertItem(optionsItem, at: index)

        installRecordingLamp()
    }

    // MARK: - Lamp

    /// A lamp at the right-hand end of the title bar: grey, and red while a
    /// recording runs. On the right rather than in the title, where it would
    /// sit beside the three window buttons and pass for a fourth; always there
    /// rather than appearing, so it is where the eye already knows to look.
    private func installRecordingLamp() {
        let lamp = NSImageView()
        lamp.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Recording")
        lamp.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        lamp.translatesAutoresizingMaskIntoConstraints = false
        self.recordingLampImage = lamp

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 30, height: 28))
        container.addSubview(lamp)
        NSLayoutConstraint.activate([
            lamp.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            lamp.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
        ])

        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = container
        accessory.layoutAttribute = .trailing
        self.window.addTitlebarAccessoryViewController(accessory)
        self.recordingLamp = accessory
        updateRecordingLamp()
    }

    private func updateRecordingLamp() {
        let recording = self.movieRecorder != nil
        self.recordingLampImage?.contentTintColor = recording ? .systemRed : .tertiaryLabelColor
        self.recordingLampImage?.toolTip = recording ? "Recording" : "Not recording"
        self.recordingLampImage?.setAccessibilityLabel(recording ? "Recording" : "Not recording")
    }

    /// The options are read from the profile in use each time the submenu
    /// opens, so a change of profile shows without anything having to be
    /// told about it.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == "Recording Options" else { return }
        menu.removeAllItems()
        let options = recordingOptions

        let original = option("Original Size", #selector(chooseRecordingSize(_:)))
        original.state = options.size == nil ? .on : .off
        menu.addItem(original)
        for (index, size) in NCRecordingOptions.presetSizes.enumerated() {
            let item = option("\(size.width)x\(size.height)", #selector(chooseRecordingSize(_:)))
            item.representedObject = index
            item.state = options.size == size ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let smooth = option("Smooth Scaling", #selector(chooseRecordingScaling(_:)))
        smooth.state = options.isSharp ? .off : .on
        menu.addItem(smooth)
        let sharp = option("Sharp Scaling", #selector(chooseRecordingScaling(_:)))
        sharp.representedObject = true
        sharp.state = options.isSharp ? .on : .off
        menu.addItem(sharp)

        menu.addItem(.separator())
        let proportions = option("Keep Proportions", #selector(toggleKeepProportions(_:)))
        proportions.state = options.keepsProportions ? .on : .off
        menu.addItem(proportions)
    }

    // MARK: - What a recording rules out

    /// Everything that can change the picture's size, which a recording cannot
    /// follow. Mirroring, renaming or duplicating a profile, and anything that
    /// only concerns the window, leave the picture's size alone and stay
    /// available. The recording options are here too: a recording keeps the
    /// options it started with, and changing them while it runs would look as
    /// if it did something.
    private static let actionsRuledOutWhileRecording: Set<Selector> = [
        #selector(rotateLeft(_:)),
        #selector(rotateRight(_:)),
        #selector(showCropPanel(_:)),
        #selector(deviceMenuChanged(_:)),
        #selector(sourceResolutionsMenuChanged(_:)),
        #selector(chooseProfile(_:)),
        #selector(newProfile(_:)),
        #selector(removeProfile(_:)),
        #selector(clearSettings(_:)),
        #selector(chooseRecordingSize(_:)),
        #selector(chooseRecordingScaling(_:)),
        #selector(toggleKeepProportions(_:)),
    ]

    /// Whether an action may run now. Greys the menu item out and stops its
    /// key equivalent alike.
    func isAllowedWhileRecording(_ action: Selector?) -> Bool {
        guard self.movieRecorder != nil, let action else { return true }
        return !Self.actionsRuledOutWhileRecording.contains(action)
    }

    private func option(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: - Options

    @objc func chooseRecordingSize(_ sender: NSMenuItem) {
        var options = recordingOptions
        if let index = sender.representedObject as? Int,
            NCRecordingOptions.presetSizes.indices.contains(index)
        {
            options.size = NCRecordingOptions.presetSizes[index]
        } else {
            options.size = nil
        }
        NCSettingsManager.shared.setRecording(options)
    }

    @objc func chooseRecordingScaling(_ sender: NSMenuItem) {
        var options = recordingOptions
        options.isSharp = sender.representedObject as? Bool ?? false
        NCSettingsManager.shared.setRecording(options)
    }

    @objc func toggleKeepProportions(_ sender: NSMenuItem) {
        var options = recordingOptions
        options.keepsProportions.toggle()
        NCSettingsManager.shared.setRecording(options)
    }

    // MARK: - Starting and stopping

    @objc func toggleRecording(_ sender: Any?) {
        if let recorder = self.movieRecorder {
            recorder.stop()
            return
        }
        guard self.captureSession != nil, self.availability.hasPicture else {
            self.errorMessage(message: "There is no picture to record. Select a camera first.")
            return
        }

        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.string(from: now)
        formatter.dateFormat = "h.mm.ss a"
        let time = formatter.string(from: now)

        let panel = NSSavePanel()
        panel.nameFieldStringValue = String(format: "Net Camera Video %@ at %@.mov", date, time)
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.beginSheetModal(for: self.window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.startRecording(to: url)
        }
    }

    private func startRecording(to url: URL) {
        NSLog("Recording to %@", url.path)
        // The crop cannot change during a recording, so the panel goes, keeping
        // the crop it shows.
        self.cropPanel?.dismiss()
        self.movieRecorder = NCMovieRecorder.start(
            recordingTo: url, options: recordingOptions, from: self.frameDistributor
        ) { [weak self] outcome in
            self?.recordingEnded(outcome)
        }
        self.recordingStateChanged()
    }

    private func recordingEnded(_ outcome: NCMovieRecorder.Outcome) {
        self.movieRecorder = nil
        self.recordingStateChanged()

        if self.terminateAfterRecording {
            NSApp.reply(toApplicationShouldTerminate: true)
            return
        }

        switch outcome.ending {
        case .stopped:
            break
        case .pictureChangedSize:
            self.errorMessage(
                message:
                    "The recording stopped because the picture changed size. "
                    + "Everything recorded until then has been saved.")
        case .failed(let reason):
            self.errorMessage(message: reason)
        }
    }

    private func recordingStateChanged() {
        let recording = self.movieRecorder != nil
        self.recordMenuItem?.title = recording ? "Stop Recording" : "Start Recording…"
        updateRecordingLamp()
    }
}
