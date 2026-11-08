import AVFoundation
import Cocoa

// MARK: - Profiles

/// The Profile menu: create, duplicate, rename and remove profiles, and choose
/// the one in use from the list beneath.
///
/// There is no saving and no file to pick. Every change to the picture's
/// settings is written into the profile in use as it is made, so choosing
/// another profile never loses anything, and the profile in use when the app
/// quits is the one it starts with.
extension NCAppDelegate {
    private var store: NCProfileStore { NCSettingsManager.shared.profiles }

    // MARK: - Menu

    /// Puts the Profile menu into the menu bar, after Camera.
    func installProfileMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }
        // Items are enabled by validateMenuItem(_:), which knows about the last
        // profile and about recordings.
        let menu = NSMenu(title: "Profile")
        let item = NSMenuItem(title: "Profile", action: nil, keyEquivalent: "")
        item.submenu = menu

        let cameraIndex = mainMenu.items.firstIndex { $0.title == "Camera" }
        mainMenu.insertItem(item, at: cameraIndex.map { $0 + 1 } ?? mainMenu.items.count)
        self.profileMenu = menu
        rebuildProfileMenu()
    }

    /// Rebuilds the menu whole, after every change to the profiles. The list is
    /// short and changes rarely, so there is nothing to gain from patching it.
    private func rebuildProfileMenu() {
        guard let menu = self.profileMenu else { return }
        menu.removeAllItems()

        menu.addItem(item("New Profile…", #selector(newProfile(_:))))
        menu.addItem(item("Duplicate Profile…", #selector(duplicateProfile(_:))))
        menu.addItem(item("Rename Profile…", #selector(renameProfile(_:))))
        menu.addItem(item("Remove Profile…", #selector(removeProfile(_:))))
        menu.addItem(.separator())

        for (index, profile) in store.profiles.enumerated() {
            let entry = item(profile.name, #selector(chooseProfile(_:)))
            entry.representedObject = index
            entry.state = index == store.activeIndex ? .on : .off
            menu.addItem(entry)
        }

        menu.addItem(.separator())
        menu.addItem(item("Clear All Settings…", #selector(clearSettings(_:))))

        // Every change to the profiles ends here, renaming and duplicating
        // included, and the title names the profile in use.
        self.showProfileInTitle()
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: - Actions

    /// A new profile with every picture setting at its default, put in use.
    @objc func newProfile(_ sender: NSMenuItem) {
        guard
            let name = askForProfileName(
                title: "New Profile",
                message: "The new profile starts with no crop, mirroring or rotation.",
                proposed: store.unusedName(from: "Untitled"),
                validate: { self.store.validated($0) })
        else { return }
        let previous = store.active
        store.create(named: name)
        profileChanged(from: previous)
    }

    /// A copy of the profile in use, under a new name, put in use.
    @objc func duplicateProfile(_ sender: NSMenuItem) {
        let template = store.active
        guard
            let name = askForProfileName(
                title: "Duplicate Profile",
                message: "The copy of “\(template.name)” starts with all of its settings.",
                proposed: store.unusedName(from: template.name),
                validate: { self.store.validated($0) })
        else { return }
        store.create(named: name, from: template)
        // The same settings under another name: nothing about the picture changes.
        rebuildProfileMenu()
    }

    @objc func renameProfile(_ sender: NSMenuItem) {
        let index = store.activeIndex
        guard
            let name = askForProfileName(
                title: "Rename Profile",
                message: "A new name for “\(store.active.name)”.",
                proposed: store.active.name,
                validate: { self.store.validated($0, ignoring: index) })
        else { return }
        store.rename(index, to: name)
        rebuildProfileMenu()
    }

    @objc func removeProfile(_ sender: NSMenuItem) {
        guard store.profiles.count > 1 else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove the profile “\(store.active.name)”?"
        alert.informativeText = "Its settings are lost. This cannot be undone."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let previous = store.active
        store.remove(store.activeIndex)
        profileChanged(from: previous)
    }

    /// Deletes every setting and every profile, after asking, and puts the
    /// picture and the window back to the defaults.
    @IBAction func clearSettings(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Clear all settings?"
        alert.informativeText =
            "Every profile is removed and all settings go back to their defaults. "
            + "This cannot be undone."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let previous = store.active
        if self.isBorderless {
            self.borderless(self.borderlessMenu)
        }
        NCSettingsManager.shared.clearAll()
        profileChanged(from: previous)
    }

    @objc func chooseProfile(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        let previous = store.active
        guard store.activate(index) else { return }
        profileChanged(from: previous)
    }

    // MARK: - Validation

    /// Greys out what cannot be done now: removing the only profile, and
    /// anything a recording in progress rules out.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(removeProfile(_:)) && store.profiles.count < 2 {
            return false
        }
        return isAllowedWhileRecording(menuItem.action)
    }

    // MARK: - Switching

    /// Puts the picture into the state the profile now in use describes.
    ///
    /// The window stays where it is: it is the app's, not the profile's. It is
    /// only turned on its side when the new profile's picture is, and relocked
    /// to the new shape if the aspect ratio is fixed.
    private func profileChanged(from previous: NCProfile) {
        let current = store.active
        NSLog("Profile is now %@", current.name)

        // The panel was opened on the old profile's crop; a Cancel now would
        // write that into this one.
        self.cropPanel?.dismiss()

        if previous.position % 2 != current.position % 2 {
            self.swapWH()
        }

        // The profile's camera, when it names one that is connected, at the
        // profile's resolution. One that is not connected leaves the camera
        // that is running alone; the profile still names its own.
        if let deviceIndex = self.savedDeviceIndex {
            self.selectedDeviceIndex = deviceIndex
            self.adoptSavedResolution(for: self.devices[deviceIndex], overriding: true)
            if self.availability.hasPicture {
                self.startCaptureWithVideoDevice(defaultDevice: deviceIndex)
            }
        }

        self.applySettings()
        self.refreshSourceMenuState()
        rebuildProfileMenu()
    }

    // MARK: - Naming

    /// Asks for a name, saying what is wrong with one that will not do and
    /// asking again, until a usable one is given or the user cancels.
    private func askForProfileName(
        title: String, message: String, proposed: String,
        validate: (String) -> Result<String, NCProfileStore.NameProblem>
    ) -> String? {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = proposed

        var problem: NCProfileStore.NameProblem?
        while true {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = problem.map { "\($0.message)\n\n\(message)" } ?? message
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            alert.layout()
            field.selectText(nil)

            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            switch validate(field.stringValue) {
            case .success(let name):
                return name
            case .failure(let reason):
                problem = reason
            }
        }
    }
}
