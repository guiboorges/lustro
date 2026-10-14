import Foundation
import Testing
@testable import LustroCore

/// Regression cases from the security audit (run-1, commit 55a7a05). Each one is a way another program
/// in the same account could have pointed Lustro's file access at data it cannot reach itself.
@Suite struct SecurityRegressionTests {
    // MARK: Uninstaller

    @Test func infoPlistValuesCannotLeaveLibrary() throws {
        let home = try FakeHome()
        try home.dir("Library/Application Support")
        try home.dir("Library/Caches")
        try home.file("Documents/Thesis/draft.txt")
        let uninstaller = Uninstaller(home: home.url, searchRoots: [])

        for (id, name) in [("com.example.notes", "../../Documents/Thesis"), ("../../Documents/Thesis", "Notes Helper")] {
            let found = uninstaller.leftovers(bundleID: id, name: name)
            #expect(found.isEmpty, "\(id) / \(name) reached \(found.map(\.url.path))")
        }
        #expect(PathPattern.expand(home.url.path + "/Library/Caches/../../Documents/Thesis", home: home.url).isEmpty)
    }

    @Test func slashInNameCannotFollowALinkOutOfLibrary() throws {
        let home = try FakeHome()
        let elsewhere = try home.dir("Elsewhere")
        try home.file("Elsewhere/Victim.app/Contents/Info.plist")
        try home.dir("Library/Application Support")
        try FileManager.default.createSymbolicLink(at: home.url.appendingPathComponent("Library/Application Support/link"),
                                                   withDestinationURL: elsewhere)
        let found = Uninstaller(home: home.url, searchRoots: [elsewhere])
            .leftovers(bundleID: "com.example.lure", name: "link/Victim.app")
        #expect(found.isEmpty)
    }

    @Test func vendorPrefixIdentifiersOnlyMatchExactly() throws {
        let home = try FakeHome()
        try home.file("Library/Preferences/com.google.Chrome.plist", bytes: 10)
        try home.file("Library/Containers/com.apple.Notes/Data/x")
        try home.file("Library/Group Containers/group.com.apple.notes/x")
        try home.file("Library/Caches/com.google.SoftwareUpdate/x")
        let uninstaller = Uninstaller(home: home.url, searchRoots: [])

        #expect(uninstaller.leftovers(bundleID: "com", name: "Odd").isEmpty)
        #expect(uninstaller.leftovers(bundleID: "com.google", name: "Odd").isEmpty)
        #expect(Uninstaller.isProtectedBundle("com.apple"))
        #expect(Uninstaller.isProtectedBundle("COM.APPLE.MAIL"))
        #expect(Uninstaller.isProtectedBundle("Com.Apple.Safari"))
    }

    @Test func prefixMatchesSkipOtherInstalledApps() throws {
        let home = try FakeHome()
        try home.file("Library/Preferences/com.acme.Widget.plist", bytes: 10)
        try home.file("Library/Preferences/com.acme.Widget.helper.plist", bytes: 10)
        try home.file("Library/Preferences/com.acme.Widget.beta.plist", bytes: 10)
        let found = Uninstaller(home: home.url, searchRoots: [])
            .leftovers(bundleID: "com.acme.Widget", name: "Widget", otherBundleIDs: ["com.acme.Widget.beta"])
            .map(\.url.lastPathComponent)
        #expect(Set(found) == ["com.acme.Widget.plist", "com.acme.Widget.helper.plist"])
    }

    // MARK: Paths reached through links

    @Test func refusesItemsReachedThroughALinkInsideHome() throws {
        let home = try FakeHome()
        let documents = try home.dir("Documents")
        try home.file("Documents/thesis.txt")
        try home.dir("Library/Developer/Xcode")
        let derived = home.url.appendingPathComponent("Library/Developer/Xcode/DerivedData")
        try FileManager.default.createSymbolicLink(at: derived, withDestinationURL: documents)

        let policy = SafetyPolicy(home: home.url)
        let listed = PathPattern.expand(derived.path + "/*", home: home.url)
        #expect(!listed.isEmpty) // the listing still follows the link…
        for url in listed {      // …but nothing in it may be removed
            #expect(throws: SafetyViolation.redirected(url.standardizedFileURL.path)) { try policy.validate(url) }
        }
        #expect(policy.isAllowed(derived)) // removing the link itself never touches its target
    }

    @Test func symlinkedTrashCannotForcePermanentDeletion() async throws {
        let home = try FakeHome()
        let documents = try home.dir("Documents")
        let precious = try home.file("Documents/precious.txt")
        try FileManager.default.createSymbolicLink(at: home.url.appendingPathComponent(".Trash"), withDestinationURL: documents)

        let item = ScanItem(url: home.url.appendingPathComponent(".Trash/precious.txt"), size: 1, isDirectory: false)
        let report = await Remover(policy: SafetyPolicy(home: home.url), mode: .trash, skipOpenFiles: false).remove([item])
        #expect(report.removed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: precious.path))
    }

    @Test func parentSwappedAfterScanIsRefused() async throws {
        let home = try FakeHome()
        let cache = try home.file("Library/Caches/com.example/data.bin")
        let victim = try home.file("Documents/data.bin")
        let item = try #require(DiskUsage.item(for: cache))

        let folder = cache.deletingLastPathComponent()
        try FileManager.default.moveItem(at: folder, to: home.url.appendingPathComponent("Library/Caches/moved"))
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: victim.deletingLastPathComponent())

        let report = await Remover(policy: SafetyPolicy(home: home.url), mode: .permanent, skipOpenFiles: false).remove([item])
        #expect(report.removed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: victim.path))
    }

    @Test func itemReplacedAfterScanIsRefused() async throws {
        let home = try FakeHome()
        let file = try home.file("Library/Caches/com.example/data.bin")
        let item = try #require(DiskUsage.item(for: file))
        try FileManager.default.removeItem(at: file)
        try home.file("Library/Caches/com.example/data.bin")

        let report = await Remover(policy: SafetyPolicy(home: home.url), mode: .permanent, skipOpenFiles: false).remove([item])
        #expect(report.removed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: Letter case

    @Test func protectionsIgnoreLetterCase() throws {
        let home = try FakeHome()
        try home.file("Library/Application Support/Lustro/history.json")
        let variant = home.url.appendingPathComponent("Library/Application Support/LUSTRO")
        #expect(throws: SafetyViolation.self) { try SafetyPolicy(home: home.url).validate(variant) }
        #expect(!SafetyPolicy(home: home.url).isAllowed(home.url.appendingPathComponent("DOCUMENTS")))

        let kb = AppKnowledgeBase(apps: [AppKnowledgeBase.App(bundleIDs: ["com.docker.docker"], name: "Docker", files: nil,
                                                              never: ["~/Library/Containers/com.docker.docker"], why: "VMs")])
        let path = home.url.appendingPathComponent("Library/Containers/COM.DOCKER.DOCKER/Data")
        #expect(kb.protectingApp(for: path, home: home.url)?.name == "Docker")
    }

    // MARK: Shared temp folders

    @Test func ownFilesInSharedTempAreAllowed() throws {
        let file = URL(fileURLWithPath: "/private/tmp/lustro-test-\(UUID().uuidString)")
        try Data([1]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(SafetyPolicy(home: URL(fileURLWithPath: NSHomeDirectory())).isAllowed(file))
    }

    // MARK: History restore

    private func entry(_ store: HistoryStore, original: URL, trashed: URL) throws -> HistoryEntry {
        var report = RemovalReport(dryRun: false, mode: .trash)
        let item = ScanItem(url: original, size: 1, isDirectory: false)
        report.removed = [item]
        report.trashLocations[item.id] = trashed
        return try #require(store.record(module: "Cleanup", report: report))
    }

    @Test func restoreOnlyTakesItemsFromTheTrash() throws {
        let home = try FakeHome()
        let store = HistoryStore(fileURL: home.url.appendingPathComponent("state/history.json"))
        // history.json edited to "put back" a file that was never in the Trash.
        let protected = try home.file("Library/Messages/chat.db")
        let destination = home.url.appendingPathComponent("Public/chat.db")
        let edited = try entry(store, original: destination, trashed: protected)
        let failures = store.restore(entryID: edited.id, policy: SafetyPolicy(home: home.url))
        #expect(failures[destination.path] != nil)
        #expect(FileManager.default.fileExists(atPath: protected.path))
    }

    @Test func restoreRefusesProtectedAndRedirectedDestinations() throws {
        let home = try FakeHome()
        let store = HistoryStore(fileURL: home.url.appendingPathComponent("state/history.json"))
        let policy = SafetyPolicy(home: home.url)
        let secret = try home.dir("Library/Safari")
        try home.dir("Library/Caches")
        try FileManager.default.createSymbolicLink(at: home.url.appendingPathComponent("Library/Caches/link"), withDestinationURL: secret)

        for destination in ["Library/Safari/History.db", "Library/Caches/link/History.db", "../outside.txt"] {
            let trashed = try home.file(".Trash/planted-\(UUID().uuidString)")
            let original = URL(fileURLWithPath: home.url.path + "/" + destination)
            let edited = try entry(store, original: original, trashed: trashed)
            let failures = store.restore(entryID: edited.id, policy: policy)
            #expect(!failures.isEmpty, "restored into \(destination)")
            #expect(FileManager.default.fileExists(atPath: trashed.path))
        }
        #expect(!FileManager.default.fileExists(atPath: secret.appendingPathComponent("History.db").path))
    }

    // MARK: Lustro's own state folder

    @Test func stateFolderThatIsALinkIsNotUsed() throws {
        let home = try FakeHome()
        let victim = try home.dir("Library/Safari")
        let support = try home.dir("Library/Application Support")
        let state = support.appendingPathComponent("Lustro")
        try FileManager.default.createSymbolicLink(at: state, withDestinationURL: victim)

        #expect(!StateDirectory.isSafe(state, home: home.url))
        #expect(throws: StateDirectory.Unsafe.self) { try StateDirectory.prepare(state, home: home.url) }
        let store = HistoryStore(fileURL: state.appendingPathComponent("history.json"))
        var report = RemovalReport(dryRun: false, mode: .permanent)
        report.removed = [ScanItem(url: home.url.appendingPathComponent("x"), size: 1, isDirectory: false)]
        store.record(module: "Cleanup", report: report)
        #expect((try FileManager.default.contentsOfDirectory(atPath: victim.path)).isEmpty)
    }

    @Test func migrationNeverMovesALink() throws {
        let home = try FakeHome()
        let support = try home.dir("Library/Application Support")
        let elsewhere = try home.dir("Elsewhere")
        try FileManager.default.createSymbolicLink(at: support.appendingPathComponent("Limpo"), withDestinationURL: elsewhere)
        LustroSettings.migrateFromPreviousName(home: home.url)
        #expect(!FileManager.default.fileExists(atPath: support.appendingPathComponent("Lustro").path))
    }

    // MARK: Uninstaller identity

    @Test func unsignedAppsDoNotGetSupportFilesPreselected() throws {
        let home = try FakeHome()
        let apps = try home.dir("Applications")
        try home.file("Applications/Impostor.app/Contents/Info.plist", bytes: 0)
        let plist: [String: Any] = ["CFBundleIdentifier": "com.example.victim", "CFBundleName": "Impostor", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: apps.appendingPathComponent("Impostor.app/Contents/Info.plist"))
        try home.file("Library/Containers/com.example.victim/Data/db.sqlite")

        let uninstaller = Uninstaller(home: home.url, searchRoots: [apps])
        let app = try #require(uninstaller.installedApps(measureSizes: false).first)
        let support = try #require(uninstaller.removalPlan(for: app).first { $0.id == "leftovers" })
        #expect(!support.autoSelect)
        #expect(support.items.contains { $0.url.lastPathComponent == "com.example.victim" })
    }

    // MARK: Apps that belong to root

    /// Finder (and the password dialog) is only for real app folders owned by root inside an applications folder.
    @Test func onlyRootOwnedAppFoldersGoThroughFinder() throws {
        let home = try FakeHome()
        let apps = try home.dir("Applications")
        try home.file("Applications/Mine.app/Contents/Info.plist")
        try FileManager.default.createSymbolicLink(at: apps.appendingPathComponent("Link.app"),
                                                   withDestinationURL: URL(fileURLWithPath: "/System/Applications/Calculator.app"))
        #expect(!FinderTrash.isEligible(apps.appendingPathComponent("Mine.app"), roots: [apps]))
        #expect(!FinderTrash.isEligible(apps.appendingPathComponent("Link.app"), roots: [apps]))

        let calculator = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        #expect(!FinderTrash.isEligible(calculator))
        #expect(FinderTrash.isEligible(calculator, roots: [URL(fileURLWithPath: "/System/Applications")]))
        #expect(!FinderTrash.isEligible(URL(fileURLWithPath: "/System/Applications"), roots: [URL(fileURLWithPath: "/System")]))
    }

    // MARK: Knowledge base

    @Test func unreadableKnowledgeBaseProtectsEverything() {
        var kb = AppKnowledgeBase(apps: [])
        #expect(kb.protectingApp(for: URL(fileURLWithPath: "/tmp/x"), home: URL(fileURLWithPath: "/tmp")) == nil)
        kb = AppKnowledgeBase.unavailableForTesting()
        #expect(kb.protectingApp(for: URL(fileURLWithPath: "/tmp/x"), home: URL(fileURLWithPath: "/tmp")) != nil)
    }
}
