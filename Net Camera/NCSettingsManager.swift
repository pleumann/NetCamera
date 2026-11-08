import AVFoundation
import Cocoa

class NCSettingsManager {
    // MARK: - Properties
    private(set) var isMirrored: Bool = false
    private(set) var isUpsideDown: Bool = false
    private(set) var isBorderless: Bool = false
    private(set) var isAspectRatioFixed: Bool = false
    private(set) var position: Int = 0
    private(set) var deviceName: String = "-"
    private(set) var savedDeviceName: String = "-"

    /// The margins cut off the camera's picture. One set for every camera for
    /// now; different sources wanting different margins is what profiles are
    /// for, later.
    private(set) var crop: NCFrameCrop = .none

    /// The capture resolution of the camera named by `deviceName`, as it was
    /// when the settings were saved. Held as dimensions rather than as an index
    /// into the camera's formats, whose order is the driver's to change.
    /// `nil` when none has been saved.
    private(set) var resolution: (width: Int, height: Int)?

    // MARK: - Frame Properties
    private(set) var frameX: Float = 100
    private(set) var frameY: Float = 100
    private(set) var frameWidth: Float = 0
    private(set) var frameHeight: Float = 0

    // MARK: - Singleton
    static let shared: NCSettingsManager = NCSettingsManager()

    private init() {
        loadSettings()
    }

    // MARK: - Property Setters
    func setMirrored(_ value: Bool) {
        isMirrored = value
    }

    func setUpsideDown(_ value: Bool) {
        isUpsideDown = value
    }

    func setBorderless(_ value: Bool) {
        isBorderless = value
    }

    func setAspectRatioFixed(_ value: Bool) {
        isAspectRatioFixed = value
    }

    func setPosition(_ value: Int) {
        position = value
    }

    func setDeviceName(_ value: String) {
        deviceName = value
    }

    func setCrop(_ value: NCFrameCrop) {
        crop = value
    }

    func setResolution(_ value: (width: Int, height: Int)?) {
        resolution = value
    }

    func setFrameProperties(x: Float, y: Float, width: Float, height: Float) {
        frameX = x
        frameY = y
        frameWidth = width
        frameHeight = height
    }

    // MARK: - Settings Management
    func loadSettings() {
        logSettings(label: "before loadSettings")

        savedDeviceName = UserDefaults.standard.object(forKey: "deviceName") as? String ?? ""
        isBorderless = UserDefaults.standard.object(forKey: "borderless") as? Bool ?? false
        isMirrored = UserDefaults.standard.object(forKey: "mirrored") as? Bool ?? false
        isUpsideDown = UserDefaults.standard.object(forKey: "upsideDown") as? Bool ?? false
        isAspectRatioFixed =
            UserDefaults.standard.object(forKey: "aspectRatioFixed") as? Bool ?? false
        position = UserDefaults.standard.object(forKey: "position") as? Int ?? 0
        crop = NCFrameCrop(
            top: UserDefaults.standard.object(forKey: "cropTop") as? Int ?? 0,
            left: UserDefaults.standard.object(forKey: "cropLeft") as? Int ?? 0,
            bottom: UserDefaults.standard.object(forKey: "cropBottom") as? Int ?? 0,
            right: UserDefaults.standard.object(forKey: "cropRight") as? Int ?? 0)
        if let width = UserDefaults.standard.object(forKey: "resolutionWidth") as? Int,
            let height = UserDefaults.standard.object(forKey: "resolutionHeight") as? Int,
            width > 0, height > 0
        {
            resolution = (width, height)
        } else {
            resolution = nil
        }

        frameWidth = UserDefaults.standard.object(forKey: "frameW") as? Float ?? 0
        frameHeight = UserDefaults.standard.object(forKey: "frameH") as? Float ?? 0
        if 100 < frameWidth && 100 < frameHeight {
            frameX = UserDefaults.standard.object(forKey: "frameX") as? Float ?? 100
            frameY = UserDefaults.standard.object(forKey: "frameY") as? Float ?? 100
            NSLog("loaded : x:%f,y:%f,w:%f,h:%f", frameX, frameY, frameWidth, frameHeight)
        }

        logSettings(label: "after loadSettings")
    }

    func saveSettings() {
        logSettings(label: "saveSettings")
        // What is on disk is what a hot-plug falls back to from now on, not only after a
        // relaunch.
        savedDeviceName = deviceName
        UserDefaults.standard.set(deviceName, forKey: "deviceName")
        UserDefaults.standard.set(isBorderless, forKey: "borderless")
        UserDefaults.standard.set(isMirrored, forKey: "mirrored")
        UserDefaults.standard.set(isUpsideDown, forKey: "upsideDown")
        UserDefaults.standard.set(isAspectRatioFixed, forKey: "aspectRatioFixed")
        UserDefaults.standard.set(position, forKey: "position")
        UserDefaults.standard.set(crop.top, forKey: "cropTop")
        UserDefaults.standard.set(crop.left, forKey: "cropLeft")
        UserDefaults.standard.set(crop.bottom, forKey: "cropBottom")
        UserDefaults.standard.set(crop.right, forKey: "cropRight")
        if let resolution {
            UserDefaults.standard.set(resolution.width, forKey: "resolutionWidth")
            UserDefaults.standard.set(resolution.height, forKey: "resolutionHeight")
        } else {
            UserDefaults.standard.removeObject(forKey: "resolutionWidth")
            UserDefaults.standard.removeObject(forKey: "resolutionHeight")
        }
        UserDefaults.standard.set(frameX, forKey: "frameX")
        UserDefaults.standard.set(frameY, forKey: "frameY")
        UserDefaults.standard.set(frameWidth, forKey: "frameW")
        UserDefaults.standard.set(frameHeight, forKey: "frameH")
    }

    func clearSettings() {
        if let appDomain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: appDomain)
        }
        loadSettings()  // Reset to defaults
    }

    func logSettings(label: String) {
        NSLog(
            "%@ : %@,%@,%@borderless,%@mirrored,%@upsideDown,%@aspectRetioFixed,position:%d,"
                + "crop(t,l,b,r):%d,%d,%d,%d,resolution:%dx%d",
            label, deviceName, savedDeviceName,
            isBorderless ? "+" : "-",
            isMirrored ? "+" : "-",
            isUpsideDown ? "+" : "-",
            isAspectRatioFixed ? "+" : "-",
            position,
            crop.top, crop.left, crop.bottom, crop.right,
            resolution?.width ?? 0, resolution?.height ?? 0)
    }
}
