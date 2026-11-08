import Foundation

// MARK: - Resolution

/// A capture resolution, held as dimensions rather than as an index into a
/// camera's formats, whose order is the driver's to change.
struct NCResolution: Equatable {
    let width: Int
    let height: Int
}

// MARK: - Profile

/// Everything that decides what the picture is, for one source.
///
/// Different machines fed through the same capture device want different
/// settings — a different signal, different black margins, perhaps a
/// different camera altogether — so these travel together and are switched
/// together. What decides where the picture is shown — the window's frame,
/// borderless mode, the aspect-ratio lock — is the app's, not a profile's.
struct NCProfile: Equatable {
    var name: String

    /// The camera, by name. Empty when the profile names no camera, in which
    /// case whichever one is connected is used.
    var deviceName: String = ""

    /// The capture resolution for `deviceName`. `nil` leaves the camera at its
    /// own default.
    var resolution: NCResolution?

    var crop: NCFrameCrop = .none
    var isMirrored: Bool = false
    var isUpsideDown: Bool = false
    var position: Int = 0

    init(name: String) {
        self.name = name
    }

    // MARK: Property list form

    private enum Key {
        static let name = "name"
        static let deviceName = "deviceName"
        static let resolutionWidth = "resolutionWidth"
        static let resolutionHeight = "resolutionHeight"
        static let cropTop = "cropTop"
        static let cropLeft = "cropLeft"
        static let cropBottom = "cropBottom"
        static let cropRight = "cropRight"
        static let mirrored = "mirrored"
        static let upsideDown = "upsideDown"
        static let position = "position"
    }

    /// Reads a profile back, forgivingly: anything missing or of the wrong type
    /// takes its default, because a value read back from `UserDefaults`
    /// carries no guarantee. Only a profile with no usable name is rejected,
    /// since a profile is found by its name.
    init?(dictionary: [String: Any]) {
        guard let name = dictionary[Key.name] as? String,
            !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        self.init(name: name, values: { dictionary[$0] })
    }

    /// The same fields read from the flat keys that held the settings before
    /// there were profiles, so that what was saved then becomes the first
    /// profile.
    init(name: String, legacy defaults: UserDefaults) {
        self.init(name: name, values: { defaults.object(forKey: $0) })
    }

    private init(name: String, values: (String) -> Any?) {
        self.name = name
        deviceName = values(Key.deviceName) as? String ?? ""
        if let width = values(Key.resolutionWidth) as? Int,
            let height = values(Key.resolutionHeight) as? Int,
            width > 0, height > 0
        {
            resolution = NCResolution(width: width, height: height)
        }
        crop = NCFrameCrop(
            top: values(Key.cropTop) as? Int ?? 0,
            left: values(Key.cropLeft) as? Int ?? 0,
            bottom: values(Key.cropBottom) as? Int ?? 0,
            right: values(Key.cropRight) as? Int ?? 0)
        isMirrored = values(Key.mirrored) as? Bool ?? false
        isUpsideDown = values(Key.upsideDown) as? Bool ?? false
        position = values(Key.position) as? Int ?? 0
    }

    var dictionary: [String: Any] {
        var result: [String: Any] = [
            Key.name: name,
            Key.deviceName: deviceName,
            Key.cropTop: crop.top,
            Key.cropLeft: crop.left,
            Key.cropBottom: crop.bottom,
            Key.cropRight: crop.right,
            Key.mirrored: isMirrored,
            Key.upsideDown: isUpsideDown,
            Key.position: position,
        ]
        if let resolution {
            result[Key.resolutionWidth] = resolution.width
            result[Key.resolutionHeight] = resolution.height
        }
        return result
    }

    /// The keys the settings used before there were profiles, which the first
    /// profile is built from and which are then removed.
    static let legacyKeys: [String] = [
        Key.deviceName, Key.resolutionWidth, Key.resolutionHeight,
        Key.cropTop, Key.cropLeft, Key.cropBottom, Key.cropRight,
        Key.mirrored, Key.upsideDown, Key.position,
    ]
}

// MARK: - Profile store

/// The profiles, which one is in use, and every change to either, written
/// through to `UserDefaults` as it happens.
///
/// There is always at least one profile and always exactly one in use: the
/// last profile cannot be removed, and a store that finds nothing usable on
/// disk starts with a single default one. Names are unique, ignoring case and
/// surrounding white space, because a profile is chosen by its name and two
/// that read the same are two that cannot be told apart in a menu.
final class NCProfileStore {
    // MARK: - Errors

    enum NameProblem: Error, Equatable {
        case empty
        case taken

        var message: String {
            switch self {
            case .empty: return "A profile needs a name."
            case .taken: return "There is already a profile with that name."
            }
        }
    }

    // MARK: - Properties

    static let profilesKey = "profiles"
    static let activeKey = "activeProfile"
    static let defaultName = "Default"

    private let defaults: UserDefaults

    private(set) var profiles: [NCProfile]
    private(set) var activeIndex: Int

    var active: NCProfile { profiles[activeIndex] }

    // MARK: - Lifecycle

    /// Reads the profiles from `defaults`. The first time — when there are no
    /// profiles stored at all — the settings saved before there were profiles
    /// become a profile of their own, and the keys they lived under are
    /// removed so nothing reads them again.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let stored = defaults.array(forKey: Self.profilesKey) {
            var seen: Set<String> = []
            profiles = stored.compactMap { ($0 as? [String: Any]).flatMap(NCProfile.init) }
                .filter { seen.insert(Self.normalised($0.name)).inserted }
        } else {
            profiles = [NCProfile(name: Self.defaultName, legacy: defaults)]
            NCProfile.legacyKeys.forEach(defaults.removeObject(forKey:))
        }
        if profiles.isEmpty {
            profiles = [NCProfile(name: Self.defaultName)]
        }

        let activeName = defaults.string(forKey: Self.activeKey) ?? ""
        activeIndex = profiles.firstIndex { Self.normalised($0.name) == Self.normalised(activeName) } ?? 0
        save()
    }

    // MARK: - Names

    private static func normalised(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func index(named name: String) -> Int? {
        profiles.firstIndex { Self.normalised($0.name) == Self.normalised(name) }
    }

    /// The name as it will be stored, or why it cannot be. `ignoring` is the
    /// profile being renamed, which may keep its own name or change its case.
    func validated(_ name: String, ignoring: Int? = nil) -> Result<String, NameProblem> {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        if let existing = index(named: trimmed), existing != ignoring {
            return .failure(.taken)
        }
        return .success(trimmed)
    }

    /// A name not yet in use, built from `base`: `base` itself if it is free,
    /// otherwise `base 2`, `base 3` and so on.
    func unusedName(from base: String) -> String {
        if index(named: base) == nil { return base }
        var counter = 2
        while index(named: "\(base) \(counter)") != nil { counter += 1 }
        return "\(base) \(counter)"
    }

    // MARK: - Changes

    /// Changes the profile in use. The name is not changed here, whatever the
    /// closure does to it: renaming goes through `rename`, which checks it.
    func updateActive(_ change: (inout NCProfile) -> Void) {
        var updated = active
        change(&updated)
        updated.name = active.name
        guard updated != active else { return }
        profiles[activeIndex] = updated
        save()
    }

    /// Puts the profile at `index` in use. Returns whether that changed which
    /// profile is in use.
    @discardableResult
    func activate(_ index: Int) -> Bool {
        guard profiles.indices.contains(index), index != activeIndex else { return false }
        activeIndex = index
        save()
        return true
    }

    /// Adds a profile and puts it in use: a copy of `template` under the new
    /// name, or a profile with every setting at its default when there is no
    /// template.
    @discardableResult
    func create(named name: String, from template: NCProfile? = nil) -> Result<NCProfile, NameProblem> {
        switch validated(name) {
        case .failure(let problem):
            return .failure(problem)
        case .success(let name):
            var profile = template ?? NCProfile(name: name)
            profile.name = name
            profiles.append(profile)
            activeIndex = profiles.count - 1
            save()
            return .success(profile)
        }
    }

    @discardableResult
    func rename(_ index: Int, to name: String) -> Result<String, NameProblem> {
        guard profiles.indices.contains(index) else { return .failure(.empty) }
        switch validated(name, ignoring: index) {
        case .failure(let problem):
            return .failure(problem)
        case .success(let name):
            profiles[index].name = name
            save()
            return .success(name)
        }
    }

    /// Removes the profile at `index`, unless it is the only one. When the
    /// profile in use goes, the one before it in the list takes its place, or
    /// the new first one when it was first. Returns whether anything was
    /// removed.
    @discardableResult
    func remove(_ index: Int) -> Bool {
        guard profiles.count > 1, profiles.indices.contains(index) else { return false }
        profiles.remove(at: index)
        if index < activeIndex {
            activeIndex -= 1
        } else if index == activeIndex {
            activeIndex = max(0, index - 1)
        }
        save()
        return true
    }

    // MARK: - Persistence

    private func save() {
        defaults.set(profiles.map(\.dictionary), forKey: Self.profilesKey)
        defaults.set(active.name, forKey: Self.activeKey)
    }
}
