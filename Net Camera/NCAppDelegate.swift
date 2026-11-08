import AVFoundation
import AVKit
import Cocoa
import ImageIO
import UniformTypeIdentifiers

// MARK: - NCAppDelegate Class
@NSApplicationMain
class NCAppDelegate: NSObject, NSApplicationDelegate, NCUsbWatcherDelegate,
    AVCaptureVideoDataOutputSampleBufferDelegate
{

    // MARK: - USB Watcher
    let usb: NCUsbWatcher = NCUsbWatcher()

    /// A camera has been plugged in or unplugged. Both are handled the same
    /// way, by working out afresh whether there is a picture: the first camera
    /// arriving takes the app out of the no-picture state, and the last one
    /// leaving puts it back into it.
    func deviceCountChanged() {
        self.updateCameraAvailability()
    }

    // MARK: - Interface Builder Outlets
    @IBOutlet weak var window: NSWindow!
    @IBOutlet weak var selectSourceMenu: NSMenuItem!
    @IBOutlet weak var borderlessMenu: NSMenuItem!
    @IBOutlet weak var aspectRatioFixedMenu: NSMenuItem!
    @IBOutlet weak var mirroredMenu: NSMenuItem!
    @IBOutlet weak var upsideDownMenu: NSMenuItem!
    @IBOutlet weak var playerView: NSView!

    // MARK: - Settings Properties
    var isMirrored: Bool {
        get { NCSettingsManager.shared.isMirrored }
        set { NCSettingsManager.shared.setMirrored(newValue) }
    }
    var isUpsideDown: Bool {
        get { NCSettingsManager.shared.isUpsideDown }
        set { NCSettingsManager.shared.setUpsideDown(newValue) }
    }
    var position: Int {
        get { NCSettingsManager.shared.position }
        set { NCSettingsManager.shared.setPosition(newValue) }
    }
    var isBorderless: Bool {
        get { NCSettingsManager.shared.isBorderless }
        set { NCSettingsManager.shared.setBorderless(newValue) }
    }
    var isAspectRatioFixed: Bool {
        get { NCSettingsManager.shared.isAspectRatioFixed }
        set { NCSettingsManager.shared.setAspectRatioFixed(newValue) }
    }

    // MARK: - Window Properties
    var defaultBorderStyle: NSWindow.StyleMask = NSWindow.StyleMask.closable
    var windowTitle: String = "Net Camera"
    let defaultDeviceIndex: Int = 0
    var selectedDeviceIndex: Int = 0

    var devices: [AVCaptureDevice]!
    var captureSession: AVCaptureSession!
    var videoOutput: AVCaptureVideoDataOutput!

    var input: AVCaptureDeviceInput!

    // MARK: - Frame Pipeline
    /// Where frames are delivered and processed. One serial queue, so the
    /// transform's buffer pool and every sink see frames one at a time and in
    /// the order the camera produced them, and nothing on it ever waits for
    /// the main thread.
    let captureQueue: DispatchQueue = DispatchQueue(label: "com.xalior.NetCamera.capture")

    let frameTransform: NCFrameTransform = NCFrameTransform()
    let frameDistributor: NCFrameDistributor = NCFrameDistributor()
    let displaySink: NCDisplaySink = NCDisplaySink()

    // MARK: - Netcam
    /// The embedded web server. Always on: there is no toggle, because a netcam
    /// that has to be switched on is a netcam that is off when it is wanted.
    let httpServer: NCHTTPServer = NCHTTPServer()

    /// The picture as it goes out over the network. A sink like the window's,
    /// registered on the same distributor and handed the same processed frame,
    /// which is what makes the browser and the window show the same thing.
    let mjpegSink: NCMJPEGSink = NCMJPEGSink()

    /// The crop and orientation given to every frame. Menu actions write them
    /// on the main thread and the capture queue reads them once per frame, so
    /// they are guarded by a lock, and written and read together so a frame
    /// never gets the new crop with the old orientation. They are values copied
    /// out of the settings rather than a look at them: the settings and the
    /// menus belong to the main thread, and this is the only application state
    /// the capture queue ever sees.
    private let geometryLock: NSLock = NSLock()
    private var frameOrientation: NCFrameOrientation = NCFrameOrientation(
        position: 0, isMirrored: false, isUpsideDown: false)
    private var frameCrop: NCFrameCrop = .none

    /// Whether the current run of dropped frames has already been traced.
    /// Capture queue only.
    private var frameDropReported: Bool = false

    private func publish(_ orientation: NCFrameOrientation, crop: NCFrameCrop) {
        geometryLock.lock()
        defer { geometryLock.unlock() }
        frameOrientation = orientation
        frameCrop = crop
    }

    private var currentFrameGeometry: (orientation: NCFrameOrientation, crop: NCFrameCrop) {
        geometryLock.lock()
        defer { geometryLock.unlock() }
        return (frameOrientation, frameCrop)
    }

    // MARK: - Error Handling
    func errorMessage(message: String) {
        let popup: NSAlert = NSAlert()
        popup.messageText = message
        popup.runModal()
    }

    // MARK: - Camera Availability

    /// What the app currently believes about the picture. Main thread only.
    private(set) var availability: NCCameraAvailability = .undetermined

    /// Whether access has already been asked for while the answer has stayed
    /// undecided.
    ///
    /// It stops two things. A re-check made while the system's own prompt is
    /// still on screen would otherwise queue a second request behind it. And a
    /// request that comes back without settling anything — which is what
    /// happens on a Mac with no camera — would otherwise be asked again
    /// immediately, for ever. The flag is cleared as soon as the state is
    /// anything other than undecided, so a camera plugged in later still gets
    /// the question asked.
    private var hasRequestedCameraAccess: Bool = false

    /// Whether launch has finished, so the notifications that arrive around it
    /// do not act on a window and menus that are not built yet.
    private var hasFinishedLaunching: Bool = false

    /// The sheet explaining why there is no picture, while it is on screen.
    ///
    /// It is a sheet rather than a modal alert because the explanation has to
    /// last: an alert the user dismisses leaves a black window explaining
    /// nothing, whereas a sheet stays attached to the window until either the
    /// user acts on it or the picture arrives and the app takes it down.
    private var noPictureSheet: NSAlert?

    /// Works out whether there is a picture to show, and puts the app into that
    /// state.
    ///
    /// This is the single road into and out of every no-picture condition.
    /// Permission that has not been granted, a Mac with no camera, and the last
    /// camera being unplugged are one state reached three ways, and none of
    /// them stops the app: the window, the menus and the web server all stay
    /// exactly as they were.
    func updateCameraAvailability() {
        self.detectVideoDevices()

        let status: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
        let resolved: NCCameraAvailability = NCCameraAvailability.resolve(
            authorization: status, deviceCount: self.devices.count)
        // The two facts and the conclusion drawn from them, together, because
        // any of the three alone leaves the other two to be guessed at.
        NSLog(
            "Camera availability: authorization %d, %d device(s) -> %@",
            status.rawValue, self.devices.count, String(describing: resolved))
        self.enter(resolved)

        if resolved == .undetermined {
            self.requestCameraAccess()
        } else {
            self.hasRequestedCameraAccess = false
        }
    }

    /// Asks for camera access, at a moment this app chooses.
    ///
    /// Left alone, the permission request would arrive as a side effect of the
    /// capture session starting, which puts a system prompt on screen at a
    /// moment nothing here decided and gives the app no way to know what was
    /// answered. Asking outright means the answer comes back to a completion
    /// handler, and a refusal becomes a state the app can explain rather than
    /// a window that stays black.
    private func requestCameraAccess() {
        guard !self.hasRequestedCameraAccess else { return }
        self.hasRequestedCameraAccess = true
        NSLog("Camera access has not been decided; asking for it")
        AVCaptureDevice.requestAccess(for: .video) { granted in
            // The answer arrives on a queue of AVFoundation's choosing, and
            // everything it leads to — menus, the window, the capture session —
            // belongs to the main thread.
            DispatchQueue.main.async { [weak self] in
                NSLog("Camera access was %@", granted ? "granted" : "refused")
                self?.updateCameraAvailability()
            }
        }
    }

    /// Moves the app into a state, whether or not it was already in it.
    ///
    /// Re-entering the same state is ordinary and must stay cheap: every USB
    /// event and every return to the foreground comes through here.
    private func enter(_ availability: NCCameraAvailability) {
        let changed: Bool = availability != self.availability
        self.availability = availability
        if changed {
            NSLog("Camera availability is now %@", String(describing: availability))
        }

        if availability.hasPicture {
            self.startCaptureWithVideoDevice(defaultDevice: self.selectedDeviceIndex)
        } else {
            self.stopCapture()
            self.showNoPicture(
                explanation: availability.explanation,
                titleDetail: availability.windowTitleDetail,
                offersSystemSettings: availability.offersSystemSettings)
        }
    }

    /// Gives up the capture session and everything that depends on it, leaving
    /// the window, the menus and the web server standing.
    private func stopCapture() {
        // Said before the session goes, so a browser watching is told the
        // stream has ended rather than left holding a connection that will
        // never carry another byte.
        self.mjpegSink.setLive(false)

        if self.captureSession != nil {
            // Late callbacks from a session being torn down would deliver the
            // old camera's picture into a window that is explaining why there
            // is none.
            self.videoOutput?.setSampleBufferDelegate(nil, queue: nil)
            self.captureSession.stopRunning()
        }
        self.captureSession = nil
        self.videoOutput = nil
        self.input = nil
        // Otherwise the last frame stays frozen in the window, which reads as a
        // picture that is live and merely very still.
        self.displaySink.clear()
    }

    /// Says, in the window, that there is no picture and what can be done about
    /// it.
    ///
    /// The window title carries the state permanently and the sheet carries the
    /// detail. Both are needed: the title is the shortest true statement and
    /// survives everything, and the sheet is where a route out of the problem
    /// can be offered.
    private func showNoPicture(
        explanation: String?, titleDetail: String, offersSystemSettings: Bool
    ) {
        self.setWindowTitle(detail: titleDetail)

        guard self.hasFinishedLaunching, let explanation: String = explanation else { return }
        // One sheet at a time. Coming back from System Settings with the
        // problem unfixed re-enters this state, and a stack of identical sheets
        // would be the result.
        guard self.noPictureSheet == nil else { return }

        let sheet: NSAlert = NSAlert()
        sheet.messageText = "There is no picture"
        sheet.informativeText = explanation
        if offersSystemSettings {
            sheet.addButton(withTitle: "Open Camera Settings")
        }
        sheet.addButton(withTitle: "OK")

        self.noPictureSheet = sheet
        sheet.beginSheetModal(for: self.window) { [weak self] response in
            guard let self else { return }
            self.noPictureSheet = nil
            guard offersSystemSettings, response == .alertFirstButtonReturn else { return }
            self.openCameraSettings()
        }
    }

    /// Takes down the explanation, because there is a picture again.
    private func dismissNoPictureSheet() {
        guard let sheet: NSAlert = self.noPictureSheet else { return }
        self.noPictureSheet = nil
        self.window.endSheet(sheet.window)
    }

    /// Opens Privacy & Security settings at its Camera section.
    ///
    /// The only route out of a refusal that a sandboxed app has: it cannot
    /// change the setting itself, and asking a second time is not possible
    /// because macOS answers a request that has already been decided without
    /// consulting the user at all.
    private func openCameraSettings() {
        guard let url: URL = NCCameraAvailability.systemSettingsURL else { return }
        let opened: Bool = NSWorkspace.shared.open(url)
        NSLog("Camera settings %@", opened ? "opened" : "would not open")
        if !opened {
            self.errorMessage(
                message:
                    "Net Camera could not open Privacy & Security settings. Open System Settings, "
                    + "then Privacy & Security, then Camera, and switch Camera on for Net Camera.")
        }
    }

    /// The window's title, always in the `Net Camera: [<detail>]` shape.
    ///
    /// The nib bakes the bare string "Net Camera" into the window, and a
    /// bracketed detail is the only evidence from outside that the real
    /// delegate is running — when the nib's class lookup fails the app still
    /// builds, still launches and still opens a normal-looking window wearing
    /// that bare title. Every state names itself here rather than leaving the
    /// title alone, so the signal survives having no camera.
    private func setWindowTitle(detail: String) {
        self.windowTitle = String(format: "Net Camera: [%@]", detail)
        self.window.title = self.windowTitle
        // Traced because the title is the app's own statement of what it is
        // doing, and reading it back off the window needs permissions an
        // unattended test run does not have.
        NSLog("Window title is now %@", self.windowTitle)
    }

    // MARK: - Device Management

    /// Rebuilds the device list and the whole of the Select Source menu.
    ///
    /// Called at launch and again on every USB hot-plug, which means it can run
    /// **while the menu the user is looking at is open** — plug a camera in with
    /// Select Source pulled down and the new device appears in it there and then,
    /// and can be chosen without closing anything.
    ///
    /// That is worth preserving deliberately, because it is not something AppKit
    /// owes anybody: a menu ordinarily settles its contents when it opens. It
    /// survives here because the submenu is replaced wholesale rather than
    /// mutated item by item, and because the watcher's settling delay means the
    /// capture device is ready by the time the item exists to be clicked.
    /// Rebuilding this incrementally, or acting on the hot-plug sooner, would
    /// each take it away — and would do so silently, since nothing about a menu
    /// that is merely stale looks broken.
    func detectVideoDevices() {
        NSLog("Detecting video devices...")
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
            mediaType: .video,
            position: .unspecified)
        self.devices = discoverySession.devices
        NSLog("%d devices found", devices.count)

        let deviceMenu: NSMenu = NSMenu()
        var deviceIndex: Int = 0

        // An empty menu looks like a menu that is broken. Saying there is
        // nothing to choose from is the same statement the window is making,
        // in the place a user goes looking for cameras.
        if self.devices.isEmpty {
            let emptyItem: NSMenuItem = NSMenuItem(
                title: "No cameras connected", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            deviceMenu.addItem(emptyItem)
        }

        // Fall back to the camera the profile names, or else the first device:
        // before capture has started, or once the selected camera has been unplugged, there
        // is no session device to match against. refreshSourceMenuState() settles the real
        // selection once the menu is built, and keeps a camera that is already running.
        self.selectedDeviceIndex = self.savedDeviceIndex ?? defaultDeviceIndex

        for device: AVCaptureDevice in self.devices {
            // The device item carries neither an action nor a key equivalent. AppKit fires
            // neither on a menu item that owns a submenu, and every device owns one — so both
            // live on the submenu's "Use This Camera" item instead. The item keeps its
            // checkmark, which is display state and works on a submenu owner.
            let deviceMenuItem: NSMenuItem = NSMenuItem(
                title: device.localizedName, action: nil, keyEquivalent: "")
            deviceMenuItem.representedObject = deviceIndex

            // Every device carries its resolution submenu. Net Camera's audience wants the
            // control, so it is unconditional rather than hidden behind a preference.
            addResolutionsTo(menuItem: deviceMenuItem, forDevice: device, deviceIndex: deviceIndex)

            deviceMenu.addItem(deviceMenuItem)
            deviceIndex += 1
        }

        selectSourceMenu.submenu = deviceMenu
        refreshSourceMenuState()
    }

    /// Where the camera the profile names sits in the device list, if it is connected.
    /// Matched by name, the only thing the profile keeps of it.
    var savedDeviceIndex: Int? {
        let name: String = NCSettingsManager.shared.deviceName
        guard !name.isEmpty else { return nil }
        return self.devices?.firstIndex { $0.localizedName == name }
    }

    /// The device the capture session is currently running on, or nil before the first
    /// session exists.
    var activeCaptureDevice: AVCaptureDevice? {
        (self.captureSession?.inputs.first as? AVCaptureDeviceInput)?.device
    }

    /// Recompute every checkmark in Select Source from what the hardware is actually doing —
    /// the session's device, and that device's activeFormat. Menu state is derived rather
    /// than remembered, so it cannot drift from the capture state it claims to describe.
    func refreshSourceMenuState() {
        guard let deviceMenu = selectSourceMenu.submenu, self.devices != nil else { return }
        let activeDevice =
            self.activeCaptureDevice
            ?? (self.devices.indices.contains(selectedDeviceIndex)
                ? self.devices[selectedDeviceIndex] : self.devices.first)

        for deviceMenuItem: NSMenuItem in deviceMenu.items {
            guard let deviceIndex = deviceMenuItem.representedObject as? Int,
                self.devices.indices.contains(deviceIndex)
            else { continue }
            let device: AVCaptureDevice = self.devices[deviceIndex]
            let isActive: Bool = (device == activeDevice)
            deviceMenuItem.state = isActive ? .on : .off
            if isActive { self.selectedDeviceIndex = deviceIndex }

            let active: NCResolution = Self.captureFormat(of: device.activeFormat)
            for item: NSMenuItem in deviceMenuItem.submenu?.items ?? [] {
                guard let index = item.representedObject as? Int else { continue }
                if item.action == #selector(deviceMenuChanged) {
                    item.state = isActive ? .on : .off
                } else if device.formats.indices.contains(index) {
                    // Resolution items are matched on size and pixel format, not on format
                    // identity: the submenu lists each combination once, so the active format
                    // is often another entry of the same combination that no menu item stands
                    // for individually.
                    item.state =
                        Self.captureFormat(of: device.formats[index]) == active ? .on : .off
                }
            }
        }
    }

    func startCaptureWithVideoDevice(defaultDevice: Int) {
        NSLog("Starting capture with device index %d", defaultDevice)
        // Every camera the app knew about can go away between one main-thread
        // turn and the next, so the index is checked rather than trusted.
        guard self.devices?.indices.contains(defaultDevice) == true else {
            NSLog("There is no device at index %d to capture from", defaultDevice)
            return
        }
        let device: AVCaptureDevice = self.devices[defaultDevice]

        if let session: AVCaptureSession = self.captureSession {
            // if we are "restarting" a session but the device is the same exit early.
            // The session's device is asked for rather than assumed: a camera that has
            // been unplugged takes its input out of the session with it, leaving a
            // session that is still there and has no device at all.
            if let currentDevice: AVCaptureDevice = self.activeCaptureDevice,
                currentDevice == device
            {
                // A USB hot-plug lands here: the session is left alone, but re-assert the
                // chosen resolution in case the device was reconfigured behind us.
                self.applyChosenResolution(to: device)
                self.pictureIsShowing(from: device)
                return
            }

            // Late callbacks from the outgoing session would carry the old
            // camera's picture into the new one's window.
            self.videoOutput?.setSampleBufferDelegate(nil, queue: nil)
            session.stopRunning()
        }
        captureSession = AVCaptureSession()

        do {
            self.input = try AVCaptureDeviceInput(device: device)
            self.captureSession.addInput(input)

            self.videoOutput = AVCaptureVideoDataOutput()
            // BGRA is what the transform renders into and what every consumer
            // of the frame reads.
            self.videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            // A frame that arrives late is worth less than the one behind it,
            // so the newest picture wins rather than a backlog forming.
            self.videoOutput.alwaysDiscardsLateVideoFrames = true
            self.videoOutput.setSampleBufferDelegate(self, queue: self.captureQueue)

            guard self.captureSession.canAddOutput(self.videoOutput) else {
                NSLog("The session will not take a video data output")
                self.cameraDidNotStart(
                    reason:
                        "Unfortunately, this camera cannot deliver frames to Net Camera. Try a different one."
                )
                return
            }
            self.captureSession.addOutput(self.videoOutput)

            // The connection hands over the camera's own picture and nothing
            // else: orientation belongs to NCFrameTransform, which every
            // consumer of the frame shares. The built-in FaceTime camera
            // mirrors itself unless told not to, and that mirror would compose
            // on top of the transform — mirroring the picture on one camera
            // and not on another, with no setting saying so.
            if let connection: AVCaptureConnection = self.videoOutput.connection(with: .video),
                connection.isVideoMirroringSupported
            {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }

            self.captureSession.startRunning()

            self.adoptSavedResolution(for: device)
            // Before applySettings, which sizes the window from the format now in force.
            self.applyChosenResolution(to: device)
            self.applySettings()
            self.pictureIsShowing(from: device)
        } catch {
            NSLog("Error while opening device: %@", String(describing: error))
            self.cameraDidNotStart(
                reason:
                    "Unfortunately, there was an error when trying to access the camera. Try again or select a different one."
            )
        }
    }

    /// Everything that follows from the picture being on screen: the window
    /// names the camera, the explanation of its absence comes down, and the
    /// network stream has something to send again.
    private func pictureIsShowing(from device: AVCaptureDevice) {
        self.setWindowTitle(detail: device.localizedName)
        self.dismissNoPictureSheet()
        self.mjpegSink.setLive(true)
    }

    /// A camera that was there and would not start. Not fatal either: the app
    /// falls back into the same no-picture state as every other reason for
    /// having none, so another camera can be chosen or this one plugged in
    /// again.
    private func cameraDidNotStart(reason: String) {
        self.stopCapture()
        self.setWindowTitle(detail: "camera unavailable")
        self.errorMessage(message: reason)
    }

    // MARK: - Settings Management
    func logSettings(label: String) {
        NCSettingsManager.shared.logSettings(label: label)
    }

    /// Puts the window back the way it was: borderless if it was, and where it was.
    ///
    /// The frame is AppKit's to keep, through frame autosave, which writes it whenever the
    /// window moves or is resized. A frame kept by the settings from before that is used
    /// once, the first time there is no autosaved one.
    func restoreWindow() {
        if self.isBorderless {
            self.removeBorder()
        }

        let name: String = NCSettingsManager.windowFrameAutosaveName
        let legacyFrame: NSRect? = NCSettingsManager.shared.takeLegacyWindowFrame()
        if !self.window.setFrameUsingName(name), let legacyFrame {
            NSLog("Window frame taken over from the old settings: %@", NSStringFromRect(legacyFrame))
            self.window.setFrame(legacyFrame, display: false)
        }
        self.window.setFrameAutosaveName(name)
    }

    func applySettings() {
        NCSettingsManager.shared.logSettings(label: "applySettings")

        // The three settings that decide which way round the picture is, handed
        // to the pipeline as one value, with the margins cut off it. Every
        // consumer sees the same geometry because they all read the same
        // processed frame.
        self.publish(
            NCFrameOrientation(
                position: self.position, isMirrored: self.isMirrored,
                isUpsideDown: self.isUpsideDown),
            crop: NCSettingsManager.shared.crop)
        self.fixAspectRatio()

        self.borderlessMenu.state = convertToNSControlStateValue(
            (isBorderless ? NSControl.StateValue.on.rawValue : NSControl.StateValue.off.rawValue))
        self.mirroredMenu.state = convertToNSControlStateValue(
            (isMirrored ? NSControl.StateValue.on.rawValue : NSControl.StateValue.off.rawValue))
        self.upsideDownMenu.state = convertToNSControlStateValue(
            (isUpsideDown ? NSControl.StateValue.on.rawValue : NSControl.StateValue.off.rawValue))
        self.aspectRatioFixedMenu.state = convertToNSControlStateValue(
            (isAspectRatioFixed
                ? NSControl.StateValue.on.rawValue : NSControl.StateValue.off.rawValue))
    }

    /// Writes the running camera and its resolution into the profile in use.
    ///
    /// Called only when the user has chosen a camera or a resolution, never when capture
    /// starts by itself: a profile whose camera is not plugged in falls back to another one
    /// for the moment, and must not be rewritten to name that other camera for good.
    private func recordRunningCameraInProfile() {
        guard let device: AVCaptureDevice = self.activeCaptureDevice else { return }
        NCSettingsManager.shared.setCamera(
            device.localizedName, resolution: Self.captureFormat(of: device.activeFormat))
    }

    // MARK: - Display Actions
    @IBAction func mirrorHorizontally(_ sender: NSMenuItem) {
        NSLog("Mirror image menu item selected")
        isMirrored = !isMirrored
        self.applySettings()
    }

    @IBAction func mirrorVertically(_ sender: NSMenuItem) {
        NSLog("Mirror image vertically menu item selected")
        isUpsideDown = !isUpsideDown
        self.applySettings()
    }

    func swapWH() {
        var currentSize: CGSize = self.window.contentLayoutRect.size
        swap(&currentSize.height, &currentSize.width)
        self.window.setContentSize(currentSize)
    }

    @IBAction func rotateLeft(_ sender: NSMenuItem) {
        NSLog("Rotate Left menu item selected with position %d", position)
        position = position - 1
        if position == -1 { position = 3 }
        self.swapWH()
        self.applySettings()
    }

    @IBAction func rotateRight(_ sender: NSMenuItem) {
        NSLog("Rotate Right menu item selected with position %d", position)
        position = position + 1
        if position == 4 { position = 0 }
        self.swapWH()
        self.applySettings()
    }

    // MARK: - Display Helpers
    private func addBorder() {
        window.styleMask = defaultBorderStyle
        window.title = self.windowTitle
        self.window.level = convertToNSWindowLevel(Int(CGWindowLevelForKey(.normalWindow)))
        window.isMovableByWindowBackground = false
    }

    private func removeBorder() {
        defaultBorderStyle = window.styleMask
        self.window.styleMask = [NSWindow.StyleMask.borderless, NSWindow.StyleMask.resizable]
        self.window.level = convertToNSWindowLevel(Int(CGWindowLevelForKey(.maximumWindow)))
        window.isMovableByWindowBackground = true
    }

    @IBAction func borderless(_ sender: NSMenuItem) {
        NSLog("Borderless menu item selected")
        if self.window.styleMask.contains(.fullScreen) {
            NSLog("Ignoring borderless command as window is full screen")
            return
        }
        isBorderless = !isBorderless
        sender.state = convertToNSControlStateValue(
            (isBorderless ? NSControl.StateValue.on.rawValue : NSControl.StateValue.off.rawValue))
        if isBorderless {
            removeBorder()
        } else {
            addBorder()
        }
        fixAspectRatio()
    }

    @IBAction func enterFullScreen(_ sender: NSMenuItem) {
        NSLog("Enter full screen menu item selected")
        playerView.window?.toggleFullScreen(self)
        // no effect when borderless is enabled ?
    }

    @IBAction func toggleFixAspectRatio(_ sender: NSMenuItem) {
        isAspectRatioFixed = !isAspectRatioFixed
        sender.state = convertToNSControlStateValue(
            (isAspectRatioFixed
                ? NSControl.StateValue.on.rawValue : NSControl.StateValue.off.rawValue))
        fixAspectRatio()
    }

    func isLandscape() -> Bool {
        return position % 2 == 0
    }

    /// Locks the window to the shape of the picture, when there is a picture
    /// and the user asked for the lock. With no camera there is no shape to
    /// lock to, so the window is left free to be any size — the setting is
    /// remembered and applied again as soon as a camera starts.
    func fixAspectRatio() {
        if isAspectRatioFixed, let picture = self.croppedPictureSize {
            let height: Int32 = Int32(picture.height)
            let width: Int32 = Int32(picture.width)
            let size: NSSize =
                self.isLandscape()
                ? NSMakeSize(CGFloat(width), CGFloat(height))
                : NSMakeSize(CGFloat(height), CGFloat(width))
            self.window.contentAspectRatio = size

            let ratio: CGFloat = CGFloat(Float(width) / Float(height))
            var currentSize: CGSize = self.window.contentLayoutRect.size
            if self.isLandscape() {
                currentSize.height = currentSize.width / ratio
            } else {
                currentSize.height = currentSize.width * ratio
            }
            NSLog(
                "fixAspectRatio : %f - %d,%d - %f,%f - %f,%f", ratio, width, height, size.width,
                size.height, currentSize.width, currentSize.height)
            self.window.setContentSize(currentSize)
        } else {
            self.window.contentResizeIncrements = NSMakeSize(1.0, 1.0)
        }
    }

    @IBAction func fitToActualSize(_ sender: NSMenuItem) {
        // Nothing to fit to while there is no picture.
        guard let picture = self.croppedPictureSize else { return }
        var currentSize: CGSize = self.window.contentLayoutRect.size
        currentSize.width = CGFloat(self.isLandscape() ? picture.width : picture.height)
        currentSize.height = CGFloat(self.isLandscape() ? picture.height : picture.width)
        self.window.setContentSize(currentSize)
    }

    // MARK: - Cropping

    /// The camera's picture size, before cropping and orientation, or nil
    /// while there is no camera.
    private var sourcePictureSize: (width: Int, height: Int)? {
        guard let device: AVCaptureDevice = self.activeCaptureDevice else { return nil }
        let dimensions = device.activeFormat.formatDescription.dimensions
        return (Int(dimensions.width), Int(dimensions.height))
    }

    /// The picture size once cropped, still before orientation: the shape the
    /// window locks to and fits to, because it is the shape the frames have.
    private var croppedPictureSize: (width: Int, height: Int)? {
        guard let source = self.sourcePictureSize else { return nil }
        return NCSettingsManager.shared.crop.keptSize(width: source.width, height: source.height)
    }

    /// The crop dialog while it is open, so a second Crop… brings it forward
    /// rather than opening another.
    var cropPanel: NCCropPanel?

    /// The Profile menu, built in code because its lower half is the list of profiles.
    var profileMenu: NSMenu?

    @IBAction func showCropPanel(_ sender: NSMenuItem) {
        if let cropPanel {
            cropPanel.show(beside: self.window)
            return
        }
        let panel = NCCropPanel(
            crop: NCSettingsManager.shared.crop,
            sourceSize: self.sourcePictureSize,
            onChange: { [weak self] crop in
                NSLog("Crop is now t:%d l:%d b:%d r:%d", crop.top, crop.left, crop.bottom, crop.right)
                NCSettingsManager.shared.setCrop(crop)
                // Republishes the geometry and relocks the window to the new shape.
                self?.applySettings()
            },
            onFinish: { [weak self] in
                self?.cropPanel = nil
            })
        self.cropPanel = panel
        panel.show(beside: self.window)
    }

    // MARK: - Saving Stills

    /// Writes the picture to a file, as one more consumer of the processed
    /// frame.
    ///
    /// Nothing here photographs the window. The window is a sink like any other
    /// and holds no privileged copy of the picture, so the file is made from the
    /// same frame the window is drawing — at the camera's own resolution, the
    /// way round the user asked for it. What the window happens to be doing is
    /// therefore irrelevant to saving: full screen, the border and the window's
    /// size have no bearing on the file.
    @IBAction func saveImage(_ sender: NSMenuItem) {
        NSLog("Save Image menu item selected")
        NCStillCapture.requestStill(from: self.frameDistributor) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let image):
                self.presentSavePanel(for: image)
            case .failure(let failure):
                // A request that produced nothing says so. Saving that silently
                // does nothing is indistinguishable from a broken menu item.
                NSLog("Save Image failed: %@", String(describing: failure))
                self.errorMessage(message: failure.message)
            }
        }
    }

    /// Copies the picture to the clipboard: the same still Save Image writes — cropped,
    /// turned and mirrored, at the camera's resolution rather than the window's — without
    /// a file in between.
    @IBAction func copyPicture(_ sender: Any?) {
        NSLog("Copy Picture menu item selected")
        NCStillCapture.requestStill(from: self.frameDistributor) { [weak self] result in
            switch result {
            case .success(let image):
                if !NCStillCapture.copy(image) {
                    self?.errorMessage(
                        message: "Unfortunately, the picture could not be copied to the clipboard.")
                }
            case .failure(let failure):
                NSLog("Copy Picture failed: %@", String(describing: failure))
                self?.errorMessage(message: failure.message)
            }
        }
    }

    /// Edit › Copy and ⌘C, when nothing nearer in the responder chain has anything to copy
    /// — no text field being edited — copy the picture, which is all the window shows.
    @IBAction func copy(_ sender: Any?) {
        self.copyPicture(sender)
    }

    /// The save panel: the filename pattern and the PNG write this app has
    /// always had, over an image that now comes from the pipeline.
    private func presentSavePanel(for image: CGImage) {
        let now: Date = Date()
        let dateFormatter: DateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let date: String = dateFormatter.string(from: now)
        dateFormatter.dateFormat = "h.mm.ss a"
        let time: String = dateFormatter.string(from: now)

        let panel: NSSavePanel = NSSavePanel()
        panel.nameFieldStringValue = String(format: "Net Camera Image %@ at %@.png", date, time)
        panel.beginSheetModal(for: self.window) { (result: NSApplication.ModalResponse) in
            guard result == NSApplication.ModalResponse.OK, let url: URL = panel.url else { return }
            NSLog("Saving image to %@", url.absoluteString)
            let destination: CGImageDestination? = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil)
            if destination == nil {
                NSLog(
                    "Could not write file - destination returned from CGImageDestinationCreateWithURL was nil"
                )
                self.errorMessage(
                    message: "Unfortunately, the image could not be saved to this location."
                )
            } else {
                CGImageDestinationAddImage(destination!, image, nil)
                CGImageDestinationFinalize(destination!)
            }
        }
    }

    // MARK: - Device Menu Actions
    @objc func deviceMenuChanged(_ sender: NSMenuItem) {
        NSLog("Device Menu changed")
        guard let deviceIndex = sender.representedObject as? Int,
            self.devices.indices.contains(deviceIndex)
        else { return }

        self.startCaptureWithVideoDevice(defaultDevice: deviceIndex)
        self.refreshSourceMenuState()
        self.recordRunningCameraInProfile()
    }

    // MARK: - Frame Tap
    /// Every frame the camera produces, cropped, oriented and handed to the
    /// sinks.
    ///
    /// Runs on the capture queue. It reads the guarded geometry and nothing
    /// else of the application's: no menus, no settings, no window.
    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let source: CVPixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            reportFrameDropped(reason: "the sample buffer carried no image buffer")
            return
        }

        let geometry = self.currentFrameGeometry
        guard
            let processed: CVPixelBuffer = self.frameTransform.apply(
                geometry.orientation, cropping: geometry.crop, to: source)
        else {
            reportFrameDropped(reason: "no buffer was vended for the oriented frame")
            return
        }

        self.frameDropReported = false
        self.frameDistributor.deliver(
            processed, at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    /// Traces the first drop of a run and stays quiet until frames flow again,
    /// so a pipeline that cannot process a frame says so once rather than
    /// thirty times a second.
    private func reportFrameDropped(reason: String) {
        guard !self.frameDropReported else { return }
        self.frameDropReported = true
        NSLog("Dropped a frame: %@", reason)
    }

    // MARK: - Application Lifecycle
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // The window hosts the display sink's layer for the lifetime of the
        // app. It belongs to the picture rather than to any one capture
        // session, and survives every camera change and hot-plug.
        self.playerView.layer = self.displaySink.layer
        self.playerView.layer?.backgroundColor = CGColor.black
        // A renderer that stops taking frames and will not be talked round is
        // replaced wholesale, and the window has to host whatever replaces it.
        self.displaySink.onLayerReplaced = { [weak self] layer in
            self?.playerView.layer = layer
            self?.playerView.layer?.backgroundColor = CGColor.black
        }
        self.frameDistributor.add(self.displaySink)
        // The window first and the network second, because registration order
        // is delivery order and the picture on the desk should not wait behind
        // an encode. With nobody watching the stream, the second sink costs
        // nothing at all.
        self.frameDistributor.add(self.mjpegSink)

        // Before the camera, because the server depends on nothing the camera
        // provides, and because a camera that takes its time — or is not there
        // at all — must not decide whether the app is reachable over the
        // network.
        self.httpServer.start(streaming: self.mjpegSink) { [weak self] failure in
            self?.errorMessage(message: failure.message)
        }

        // Settings belong to the window and the profile, neither of which needs
        // a camera to exist, so they are read before anything is known about
        // one and survive a launch that finds no camera at all.
        self.restoreWindow()
        self.installProfileMenu()

        // Listening before asking, so a camera plugged in while the permission
        // prompt is still on screen is not missed.
        usb.delegate = self

        self.hasFinishedLaunching = true
        self.updateCameraAvailability()
    }

    /// Coming back to the app is the moment to look again.
    ///
    /// macOS gives no notification when camera permission is granted, so a user
    /// who goes to Privacy & Security, switches Camera on and comes back would
    /// otherwise be looking at an app that still believes it was refused. This
    /// is the cheapest reliable moment to find out: it costs one call to
    /// AVFoundation, and only when there is no picture.
    func applicationDidBecomeActive(_ aNotification: Notification) {
        guard self.hasFinishedLaunching, self.captureSession == nil else { return }
        self.updateCameraAvailability()
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // The listener is given up deliberately rather than left to the process
        // exiting, so a quit-and-relaunch always finds the port free.
        self.httpServer.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: Resolutions

    /// The resolution chosen for each camera, held as an index into that camera's formats and
    /// keyed by its uniqueID. A camera keeps its own choice, and keeps it while another camera
    /// is on screen.
    var chosenFormatIndex: [String: Int] = [:]

    @objc func sourceResolutionsMenuChanged(_ sender: NSMenuItem) {
        guard let formatIndex = sender.representedObject as? Int,
            let deviceMenuItem = sender.parent,
            let deviceIndex = deviceMenuItem.representedObject as? Int,
            self.devices.indices.contains(deviceIndex)
        else { return }

        self.chosenFormatIndex[self.devices[deviceIndex].uniqueID] = formatIndex
        self.selectedDeviceIndex = deviceIndex

        // Choosing a resolution also chooses its camera, so the device may change here too.
        // startCaptureWithVideoDevice applies the choice on both of its paths.
        self.startCaptureWithVideoDevice(defaultDevice: deviceIndex)
        // Staying on the same camera skips the session rebuild, and with it the window sizing
        // that applySettings does — so relock the window to the shape now being captured.
        self.fixAspectRatio()
        self.refreshSourceMenuState()
        self.recordRunningCameraInProfile()
    }

    /// Takes the profile's resolution as the choice for the camera it names.
    ///
    /// At a camera's first start, only when nothing has been chosen for it yet, so a
    /// resolution picked from the menu since launch is never overridden. `overriding` is for
    /// switching profiles, when the profile's resolution is exactly what was asked for. The
    /// format is found the way the menu finds it — the fastest of the formats with that size
    /// and pixel format — or the fastest of that size, for a profile that names no pixel
    /// format. A camera that no longer offers it keeps the format it has.
    func adoptSavedResolution(for device: AVCaptureDevice, overriding: Bool = false) {
        guard overriding || self.chosenFormatIndex[device.uniqueID] == nil,
            device.localizedName == NCSettingsManager.shared.deviceName,
            let saved: NCResolution = NCSettingsManager.shared.resolution
        else { return }

        let candidates = device.formats.indices.filter {
            saved.isSatisfied(by: Self.captureFormat(of: device.formats[$0]))
        }
        guard
            let formatIndex = candidates.max(by: {
                Self.maxFrameRate(of: device.formats[$0]) < Self.maxFrameRate(of: device.formats[$1])
            })
        else {
            NSLog(
                "%@ no longer offers the saved %dx%d %@; leaving it as it is",
                device.localizedName, saved.width, saved.height, saved.pixelFormat ?? "")
            return
        }
        NSLog(
            "Restoring %dx%d %@ on %@", saved.width, saved.height, saved.pixelFormat ?? "",
            device.localizedName)
        self.chosenFormatIndex[device.uniqueID] = formatIndex
    }

    /// Put the camera on the resolution chosen for it, if one has been.
    ///
    /// This runs on every capture start rather than only when the menu is used, because
    /// adding an input to a fresh AVCaptureSession lets the session's preset choose the
    /// format — which silently discards an earlier choice whenever the user switches camera
    /// and back, or a USB hot-plug restarts capture.
    func applyChosenResolution(to device: AVCaptureDevice) {
        guard let formatIndex = self.chosenFormatIndex[device.uniqueID],
            device.formats.indices.contains(formatIndex)
        else { return }

        let format: AVCaptureDevice.Format = device.formats[formatIndex]
        do {
            try device.lockForConfiguration()
        } catch {
            // Another process can hold the device's configuration; losing the race costs the
            // chosen resolution, not the picture, so carry on at whatever format is in force.
            NSLog(
                "Could not lock %@ for configuration: %@", device.localizedName,
                error.localizedDescription)
            return
        }
        defer { device.unlockForConfiguration() }

        device.activeFormat = format
        // Run the format as fast as it will go: the shortest frame duration it supports.
        if !format.videoSupportedFrameRateRanges.isEmpty {
            device.activeVideoMinFrameDuration = format.videoSupportedFrameRateRanges.reduce(
                CMTime.positiveInfinity
            ) { CMTimeMinimum($0, $1.minFrameDuration) }
        }
    }

    // MARK: - source resolutions

    /// Build a device's submenu: the item that selects the camera, then one item per
    /// distinct resolution the device advertises. Net Camera reports what the hardware
    /// claims to support; it does not audit whether the hardware can deliver it.
    func addResolutionsTo(menuItem: NSMenuItem, forDevice device: AVCaptureDevice, deviceIndex: Int)
    {
        let resolutionsMenu: NSMenu = NSMenu()

        // Selecting the camera. This carries the action and the Cmd-N key equivalent that the
        // device item itself cannot, because AppKit honours neither on a submenu owner.
        let selectItem: NSMenuItem = NSMenuItem(
            title: "Use This Camera", action: #selector(deviceMenuChanged),
            keyEquivalent: deviceIndex < 9 ? String(deviceIndex + 1) : "")
        selectItem.target = self
        selectItem.representedObject = deviceIndex
        resolutionsMenu.addItem(selectItem)
        resolutionsMenu.addItem(NSMenuItem.separator())

        // Devices can advertise the same size in several pixel formats — a capture dongle
        // typically offers uncompressed YUY2 at a low frame rate and compressed video at a
        // high one — and the same combination more than once. Each size and pixel format is
        // listed once, in the order the device first lists it, and the fastest entry of that
        // combination stands for it.
        var order: [NCResolution] = []
        var fastest: [NCResolution: Int] = [:]
        for (formatIndex, format) in device.formats.enumerated() {
            let key: NCResolution = Self.captureFormat(of: format)
            guard let best = fastest[key] else {
                order.append(key)
                fastest[key] = formatIndex
                continue
            }
            if Self.maxFrameRate(of: format) > Self.maxFrameRate(of: device.formats[best]) {
                fastest[key] = formatIndex
            }
        }

        for key: NCResolution in order {
            guard let formatIndex: Int = fastest[key] else { continue }
            let formatsOfThisSize: Int = order.filter {
                $0.width == key.width && $0.height == key.height
            }.count
            let title: String = NCPixelFormat.menuTitle(
                width: key.width, height: key.height, code: key.pixelFormat ?? "",
                maxFrameRate: Self.maxFrameRate(of: device.formats[formatIndex]),
                sizeHasSeveralFormats: formatsOfThisSize > 1)

            let resolutionMenuItem: NSMenuItem = NSMenuItem(
                title: title, action: #selector(sourceResolutionsMenuChanged),
                keyEquivalent: "")
            resolutionMenuItem.target = self
            resolutionMenuItem.representedObject = formatIndex
            resolutionsMenu.addItem(resolutionMenuItem)
        }

        menuItem.submenu = resolutionsMenu
    }

    /// A camera format as size and pixel format, the terms the menu and the profiles use.
    static func captureFormat(of format: AVCaptureDevice.Format) -> NCResolution {
        let description: CMFormatDescription = format.formatDescription
        let dims = CMVideoFormatDescriptionGetDimensions(description)
        return NCResolution(
            width: Int(dims.width), height: Int(dims.height),
            pixelFormat: NCPixelFormat.code(CMFormatDescriptionGetMediaSubType(description)))
    }

    /// The highest frame rate a format supports, which is what it is run at.
    static func maxFrameRate(of format: AVCaptureDevice.Format) -> Double {
        format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
    }


}

// MARK: - Helper Functions
// Helper function inserted by Swift 4.2 migrator.
private func convertToNSControlStateValue(_ input: Int) -> NSControl.StateValue {
    NSControl.StateValue(rawValue: input)
}

// Helper function inserted by Swift 4.2 migrator.
private func convertToNSWindowLevel(_ input: Int) -> NSWindow.Level {
    NSWindow.Level(rawValue: input)
}
