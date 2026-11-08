import AVFoundation
import Cocoa

/// The app's settings, every one of them written to disk as it changes.
///
/// The picture's settings — camera, resolution, crop, mirroring, rotation —
/// belong to the profile in use, and are read from and written to it here so
/// that nothing else has to know profiles exist. The window's settings —
/// borderless mode and the aspect-ratio lock — are the app's, the same
/// whichever profile is in use. The window's frame is left to AppKit's own
/// frame autosave.
class NCSettingsManager {
    // MARK: - Keys

    private enum Key {
        static let borderless = "borderless"
        static let aspectRatioFixed = "aspectRatioFixed"
    }

    // MARK: - Profiles

    private(set) var profiles: NCProfileStore

    private var profile: NCProfile { profiles.active }

    // MARK: - Picture settings, from the profile in use

    var isMirrored: Bool { profile.isMirrored }
    var isUpsideDown: Bool { profile.isUpsideDown }
    var position: Int { profile.position }
    var crop: NCFrameCrop { profile.crop }

    /// The camera the profile names, or empty when it names none.
    var deviceName: String { profile.deviceName }

    /// The capture resolution for `deviceName`, or `nil` for the camera's own.
    var resolution: NCResolution? { profile.resolution }

    func setMirrored(_ value: Bool) {
        profiles.updateActive { $0.isMirrored = value }
    }

    func setUpsideDown(_ value: Bool) {
        profiles.updateActive { $0.isUpsideDown = value }
    }

    func setPosition(_ value: Int) {
        profiles.updateActive { $0.position = value }
    }

    func setCrop(_ value: NCFrameCrop) {
        profiles.updateActive { $0.crop = value }
    }

    var recording: NCRecordingOptions { profile.recording }

    func setRecording(_ value: NCRecordingOptions) {
        profiles.updateActive { $0.recording = value }
    }

    /// The camera, and the resolution it runs at, together: a resolution only
    /// means something for the camera it was chosen on.
    func setCamera(_ name: String, resolution: NCResolution?) {
        profiles.updateActive {
            $0.deviceName = name
            $0.resolution = resolution
        }
    }

    // MARK: - Window settings, the app's

    private(set) var isBorderless: Bool
    private(set) var isAspectRatioFixed: Bool

    func setBorderless(_ value: Bool) {
        isBorderless = value
        UserDefaults.standard.set(value, forKey: Key.borderless)
    }

    func setAspectRatioFixed(_ value: Bool) {
        isAspectRatioFixed = value
        UserDefaults.standard.set(value, forKey: Key.aspectRatioFixed)
    }

    // MARK: - Singleton

    static let shared: NCSettingsManager = NCSettingsManager()

    private init() {
        profiles = NCProfileStore()
        isBorderless = UserDefaults.standard.bool(forKey: Key.borderless)
        isAspectRatioFixed = UserDefaults.standard.bool(forKey: Key.aspectRatioFixed)
        logSettings(label: "loaded")
    }

    // MARK: - Clearing

    /// Deletes every setting the app has written, every profile included, and
    /// starts again from the defaults.
    ///
    /// What is held in memory is replaced as well as what is on disk. With
    /// every change written through, a store left holding the old profiles
    /// would write them all straight back at the next change.
    func clearAll() {
        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
        profiles = NCProfileStore()
        isBorderless = false
        isAspectRatioFixed = false
        logSettings(label: "cleared")
    }

    // MARK: - Window frame

    /// The name AppKit keeps the window's frame under.
    static let windowFrameAutosaveName = "NetCameraWindow"

    /// The window's frame as the settings kept it before AppKit's autosave
    /// took over, once only: it is read, handed back and removed, so the first
    /// launch after the change opens the window where it was and AppKit keeps
    /// it from then on. `nil` when there is nothing usable to hand back.
    func takeLegacyWindowFrame() -> NSRect? {
        let defaults = UserDefaults.standard
        let keys = ["frameX", "frameY", "frameW", "frameH"]
        defer { keys.forEach(defaults.removeObject(forKey:)) }
        let width = defaults.float(forKey: "frameW")
        let height = defaults.float(forKey: "frameH")
        guard width > 100, height > 100 else { return nil }
        return NSRect(
            x: CGFloat(defaults.float(forKey: "frameX")),
            y: CGFloat(defaults.float(forKey: "frameY")),
            width: CGFloat(width), height: CGFloat(height))
    }

    // MARK: - Logging

    func logSettings(label: String) {
        NSLog(
            "%@ : profile %@ of %d, camera '%@' at %dx%d, %@mirrored,%@upsideDown,position:%d,"
                + "crop(t,l,b,r):%d,%d,%d,%d, %@borderless,%@aspectRatioFixed",
            label, profile.name, profiles.profiles.count, deviceName,
            resolution?.width ?? 0, resolution?.height ?? 0,
            isMirrored ? "+" : "-",
            isUpsideDown ? "+" : "-",
            position,
            crop.top, crop.left, crop.bottom, crop.right,
            isBorderless ? "+" : "-",
            isAspectRatioFixed ? "+" : "-")
    }
}
