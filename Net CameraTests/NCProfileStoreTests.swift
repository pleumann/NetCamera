import XCTest

/// The profile store over a throwaway defaults domain, so nothing here reads
/// or writes the app's real settings.
final class NCProfileStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "NCProfileStoreTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    private func makeProfile(_ name: String) -> NCProfile {
        var profile = NCProfile(name: name)
        profile.deviceName = "USB3. 0 capture"
        profile.resolution = NCResolution(width: 720, height: 576)
        profile.crop = NCFrameCrop(top: 1, left: 16, bottom: 2, right: 3)
        profile.isMirrored = true
        profile.isUpsideDown = false
        profile.position = 3
        return profile
    }

    // MARK: - Starting out

    func testAnEmptyDomainStartsWithOneDefaultProfile() {
        let store = NCProfileStore(defaults: defaults)

        XCTAssertEqual(store.profiles, [NCProfile(name: NCProfileStore.defaultName)])
        XCTAssertEqual(store.activeIndex, 0)
    }

    /// The settings saved before there were profiles become the first profile,
    /// and the keys they lived under are gone afterwards.
    func testTheOldFlatSettingsBecomeTheFirstProfile() {
        defaults.set("USB3. 0 capture", forKey: "deviceName")
        defaults.set(720, forKey: "resolutionWidth")
        defaults.set(576, forKey: "resolutionHeight")
        defaults.set(16, forKey: "cropLeft")
        defaults.set(true, forKey: "mirrored")
        defaults.set(1, forKey: "position")
        defaults.set(true, forKey: "borderless")

        let store = NCProfileStore(defaults: defaults)

        var expected = NCProfile(name: NCProfileStore.defaultName)
        expected.deviceName = "USB3. 0 capture"
        expected.resolution = NCResolution(width: 720, height: 576)
        expected.crop = NCFrameCrop(top: 0, left: 16, bottom: 0, right: 0)
        expected.isMirrored = true
        expected.position = 1
        XCTAssertEqual(store.active, expected)

        for key in NCProfile.legacyKeys {
            XCTAssertNil(defaults.object(forKey: key), "\(key) is removed once taken over")
        }
        XCTAssertEqual(
            defaults.object(forKey: "borderless") as? Bool, true,
            "the window's settings are not the profile's and stay where they were")
    }

    /// Taken over once only: a later start reads the profiles, not the flat
    /// keys, even if something has written those again.
    func testTheOldSettingsAreTakenOverOnlyOnce() {
        _ = NCProfileStore(defaults: defaults)
        defaults.set(99, forKey: "cropTop")

        let store = NCProfileStore(defaults: defaults)

        XCTAssertEqual(store.active.crop, .none)
    }

    // MARK: - Persistence

    /// Every change is on disk as soon as it is made: a second store over the
    /// same domain sees the same profiles and the same one in use.
    func testEveryChangeIsWrittenThrough() {
        let store = NCProfileStore(defaults: defaults)
        store.create(named: "Next", from: makeProfile("ignored"))
        store.create(named: "Agon")
        store.updateActive { $0.crop = NCFrameCrop(top: 0, left: 8, bottom: 0, right: 8) }

        let reread = NCProfileStore(defaults: defaults)

        XCTAssertEqual(reread.profiles, store.profiles)
        XCTAssertEqual(reread.active.name, "Agon")
        XCTAssertEqual(reread.active.crop, NCFrameCrop(top: 0, left: 8, bottom: 0, right: 8))
        XCTAssertEqual(reread.profiles[1], makeProfile("Next"))
    }

    func testAProfileSurvivesItsPropertyListForm() {
        let profile = makeProfile("Next")
        XCTAssertEqual(NCProfile(dictionary: profile.dictionary), profile)

        var withoutResolution = profile
        withoutResolution.resolution = nil
        XCTAssertEqual(NCProfile(dictionary: withoutResolution.dictionary), withoutResolution)
    }

    /// Unreadable entries are dropped rather than failing the whole list, and a
    /// list with nothing usable left still gives one profile to work with.
    func testUnreadableStoredProfilesAreSkipped() {
        defaults.set(
            [["name": ""], "not a profile", ["name": "Next", "cropLeft": "sixteen"],
             ["name": "next"]],
            forKey: NCProfileStore.profilesKey)

        let store = NCProfileStore(defaults: defaults)
        XCTAssertEqual(store.profiles.map(\.name), ["Next"], "the nameless and the duplicate go")
        XCTAssertEqual(store.active.crop, .none, "a field of the wrong type takes its default")

        defaults.set([] as [Any], forKey: NCProfileStore.profilesKey)
        XCTAssertEqual(
            NCProfileStore(defaults: defaults).profiles.map(\.name), [NCProfileStore.defaultName])
    }

    func testAnActiveNameThatIsGoneFallsBackToTheFirstProfile() {
        let store = NCProfileStore(defaults: defaults)
        store.create(named: "Next")
        defaults.set("Gone", forKey: NCProfileStore.activeKey)

        XCTAssertEqual(NCProfileStore(defaults: defaults).activeIndex, 0)
    }

    // MARK: - Names

    func testNamesAreTrimmedAndMustBeNonEmptyAndUnique() {
        let store = NCProfileStore(defaults: defaults)

        XCTAssertEqual(store.create(named: "  Next \n").map(\.name), .success("Next"))
        XCTAssertEqual(store.create(named: "   ").map(\.name), .failure(.empty))
        XCTAssertEqual(store.create(named: "NEXT").map(\.name), .failure(.taken))
        XCTAssertEqual(store.profiles.count, 2)
    }

    func testAProfileMayBeRenamedToItselfInAnotherCaseButNotToAnother() {
        let store = NCProfileStore(defaults: defaults)
        store.create(named: "Next")
        let next = store.activeIndex

        XCTAssertEqual(store.rename(next, to: "NEXT"), .success("NEXT"))
        XCTAssertEqual(store.rename(next, to: "default"), .failure(.taken))
        XCTAssertEqual(store.rename(next, to: ""), .failure(.empty))
        XCTAssertEqual(store.profiles.map(\.name), [NCProfileStore.defaultName, "NEXT"])
        XCTAssertEqual(defaults.string(forKey: NCProfileStore.activeKey), "NEXT")
    }

    func testUnusedNamesCountUpFromTheBase() {
        let store = NCProfileStore(defaults: defaults)
        XCTAssertEqual(store.unusedName(from: "Next"), "Next")
        store.create(named: "Next")
        store.create(named: "Next 2")
        XCTAssertEqual(store.unusedName(from: "next"), "next 3")
    }

    // MARK: - Changes

    func testCreatingPutsTheNewProfileInUseAsACopyOrFresh() {
        let store = NCProfileStore(defaults: defaults)
        store.create(named: "Next", from: makeProfile("Template"))
        XCTAssertEqual(store.active, makeProfile("Next"))

        store.create(named: "Agon")
        XCTAssertEqual(store.active, NCProfile(name: "Agon"))
    }

    /// Changes go to the profile in use and no other, and cannot rename it.
    func testUpdatesChangeOnlyTheProfileInUseAndNeverItsName() {
        let store = NCProfileStore(defaults: defaults)
        store.create(named: "Next")
        store.activate(0)

        store.updateActive {
            $0.position = 2
            $0.name = "Sneaky"
        }

        XCTAssertEqual(store.profiles[0].position, 2)
        XCTAssertEqual(store.profiles[0].name, NCProfileStore.defaultName)
        XCTAssertEqual(store.profiles[1], NCProfile(name: "Next"))
    }

    func testTheLastProfileCannotBeRemoved() {
        let store = NCProfileStore(defaults: defaults)
        XCTAssertFalse(store.remove(0))
        XCTAssertEqual(store.profiles.count, 1)
    }

    /// Removing keeps the same profile in use when another one goes, and hands
    /// over to the one before when the one in use goes — or to the new first
    /// one when it was first.
    func testRemovingKeepsAProfileInUse() {
        let store = NCProfileStore(defaults: defaults)
        store.create(named: "A")
        store.create(named: "B")
        store.create(named: "C")  // [Default, A, B, C], C in use

        XCTAssertTrue(store.remove(1))
        XCTAssertEqual(store.active.name, "C", "removing another keeps the one in use")

        XCTAssertTrue(store.remove(store.activeIndex))
        XCTAssertEqual(store.active.name, "B", "the one before takes over")

        store.activate(0)
        XCTAssertTrue(store.remove(0))
        XCTAssertEqual(store.active.name, "B", "the new first one takes over")
        XCTAssertEqual(defaults.string(forKey: NCProfileStore.activeKey), "B")
    }

    func testActivatingReportsWhetherAnythingChanged() {
        let store = NCProfileStore(defaults: defaults)
        store.create(named: "Next")

        XCTAssertFalse(store.activate(1), "already in use")
        XCTAssertFalse(store.activate(7), "no such profile")
        XCTAssertTrue(store.activate(0))
        XCTAssertEqual(defaults.string(forKey: NCProfileStore.activeKey), NCProfileStore.defaultName)
    }
}
