import Foundation
import Testing
@testable import LustroCore

/// Builds a throwaway home folder with files of a given age.
struct AgedHome {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("lustro-de-\(UUID().uuidString)")
    var home: URL { root }

    @discardableResult
    func file(_ relative: String, bytes: Int = 4096, daysOld: Double = 90) throws -> URL {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
        let date = Date().addingTimeInterval(-daysOld * 86_400)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        var parent = url.deletingLastPathComponent()
        while parent.path.count > home.path.count {
            try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: parent.path)
            parent = parent.deletingLastPathComponent()
        }
        return url
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Suite struct KnowledgeBaseTests {
    let home = URL(fileURLWithPath: "/Users/me")
    var base: AppKnowledgeBase { .bundled() }

    func protected(_ relative: String) -> String? {
        base.protectingApp(for: home.appendingPathComponent(relative), home: home)?.name
    }

    @Test func bundledFileIsValid() {
        #expect(!base.apps.isEmpty)
        #expect(base.validationErrors() == [])
    }

    @Test func profilesAreProtectedButTheirCachesAreNot() {
        #expect(protected("Library/Application Support/Google/Chrome/Default/Login Data") == "Google Chrome")
        #expect(protected("Library/Application Support/Google/Chrome/Default/GPUCache") == nil)
        #expect(protected("Library/Application Support/Google/Chrome/Profile 2/Code Cache/js") == nil)
        #expect(protected("Library/Caches/Google/Chrome") == nil)
    }

    @Test func foldersContainingProtectedDataAreProtected() {
        #expect(protected("Library/Application Support/Code") == "Visual Studio Code")
        #expect(protected("Library/Application Support/Code/Backups/123") == "Visual Studio Code")
        #expect(protected("Library/Application Support/Code/CachedData") == nil)
        #expect(protected("Library/Application Support/Google") == "Google Chrome")
        #expect(protected("Library/Application Support/Notion") == nil)
    }

    @Test func validationCatchesUnsafeEntries() {
        let bad = AppKnowledgeBase(apps: [
            .init(bundleIDs: [], name: "Empty", files: nil, never: nil, why: "x"),
            .init(bundleIDs: ["a.b.c"], name: "Broad", files: [.init(path: "~/Library", kind: "cache")], never: ["/etc"], why: "Long enough reason"),
        ])
        let errors = bad.validationErrors()
        #expect(errors.contains("Empty: no bundleIDs"))
        #expect(errors.contains("Empty: explain why"))
        #expect(errors.contains("Broad: ~/Library is too broad"))
        #expect(errors.contains("Broad: /etc must start with ~/"))
    }

    @Test func junkScannerRespectsNeverEntries() throws {
        let fake = AgedHome()
        defer { fake.remove() }
        try fake.file("Library/Application Support/Code/Cache/data", bytes: 10_000)
        try fake.file("Library/Application Support/Code/Backups/unsaved", bytes: 10_000)
        let catalog = RuleCatalog(version: 1, categories: [
            JunkCategory(id: "test", section: "S", title: "T", detail: "D", risk: .safe, autoSelect: true, minAgeHours: nil,
                         requiresFullDiskAccess: nil, owners: nil, icon: nil, tint: nil, keepNewestPerDevice: nil,
                         targets: [JunkTarget(path: "~/Library/Application Support/Code/*", exclude: nil)])])
        let scanner = JunkScanner(catalog: catalog, policy: SafetyPolicy(home: fake.home))
        let (items, _) = scanner.scan(catalog.categories[0])
        #expect(items.map(\.url.lastPathComponent) == ["Cache"])
    }

    @Test func uninstallerSeparatesProtectedData() throws {
        let fake = AgedHome()
        defer { fake.remove() }
        try fake.file("Library/Preferences/com.microsoft.VSCode.plist")
        try fake.file("Library/Application Support/Code/User/settings.json")
        let app = InstalledApp(url: fake.home.appendingPathComponent("Applications/Visual Studio Code.app"), name: "Code",
                               bundleID: "com.microsoft.VSCode", version: nil, size: 0)
        let plan = Uninstaller(home: fake.home).removalPlan(for: app)
        let support = try #require(plan.first { $0.id == "leftovers" })
        let data = try #require(plan.first { $0.id == "app-data" })
        #expect(support.items.map(\.url.lastPathComponent) == ["com.microsoft.VSCode.plist"])
        #expect(data.items.map(\.url.lastPathComponent) == ["Code"])
        #expect(data.risk == .caution && !data.autoSelect)
    }
}

@Suite struct LeftoverTests {
    @Test func bundleIDShape() {
        #expect(LeftoverScanner.looksLikeBundleID("com.spotify.client"))
        #expect(LeftoverScanner.looksLikeBundleID("io.github.user.tool-name"))
        #expect(!LeftoverScanner.looksLikeBundleID("Google"))
        #expect(!LeftoverScanner.looksLikeBundleID("com.google"))
        #expect(!LeftoverScanner.looksLikeBundleID("My App.data.files"))
    }

    @Test func ownerCheckIsConservative() {
        let owned = LeftoverScanner.ownerCheck(knownIDs: ["com.microsoft.VSCode", "com.adobe.acc.AdobeCreativeCloud", "com.google.keystone.agent"],
                                               lookup: { $0 == "com.registered.App" })
        #expect(owned("com.microsoft.VSCode"))
        #expect(owned("com.microsoft.vscode.ShipIt"))           // helper of an installed app
        #expect(owned("com.google.Keystone"))                   // extended by a known ID
        #expect(owned("com.microsoft.Word"))                    // same vendor as an installed app: left alone
        #expect(owned("com.adobe.Photoshop"))
        #expect(owned("group.com.adobe.shared"))
        #expect(owned("com.registered.App.Helper"))             // LaunchServices knows the app
        #expect(!owned("com.openai.atlas"))
        #expect(LeftoverScanner.isSystemID("com.firebase.FIRInstallations"))
        #expect(LeftoverScanner.isSystemID("org.cups.PrintingPrefs"))
        #expect(!LeftoverScanner.isSystemID("com.openai.atlas"))
    }

    @Test func findsOnlyOldUnownedUnprotected() throws {
        let fake = AgedHome()
        defer { fake.remove() }
        try fake.file("Library/Application Support/com.gone.App/data.db", bytes: 50_000)
        try fake.file("Library/Preferences/com.gone.App.plist")
        try fake.file("Library/Saved Application State/com.gone.App.savedState/window.data")
        try fake.file("Library/Application Support/com.installed.App/data.db")          // owned
        try fake.file("Library/Application Support/com.installed.App.helper/data.db")   // owned through prefix
        try fake.file("Library/Application Support/com.recent.Tool/state", daysOld: 2)  // still in use
        try fake.file("Library/Preferences/com.apple.finder.plist")                      // system
        try fake.file("Library/Application Support/Some Folder/data")                    // not a bundle ID
        try fake.file("Library/Containers/com.gone.Sandboxed/Data/x")                    // needs Full Disk Access
        try fake.file("Library/HTTPStorages/com.gone.App.binarycookies")                 // listed once, under its own ID
        try fake.file("Library/Preferences/com.firebase.FIRInstallations.plist")         // written by an SDK

        let scanner = LeftoverScanner(home: fake.home, policy: SafetyPolicy(home: fake.home),
                                      isOwned: LeftoverScanner.installedOwnerCheck(installedIDs: ["com.installed.App"]))
        let group = try #require(scanner.scan())
        #expect(group.items.map(\.url.lastPathComponent).sorted()
                == ["com.gone.App", "com.gone.App.binarycookies", "com.gone.App.plist", "com.gone.App.savedState"])
        #expect(group.risk == .review && !group.autoSelect)
        #expect(group.items.first?.evidence?.hasPrefix("No installed app has the ID com.gone.App") == true)

        let withAccess = LeftoverScanner(home: fake.home, policy: SafetyPolicy(home: fake.home), hasFullDiskAccess: true,
                                         isOwned: { _ in false })
        #expect(withAccess.scan()?.items.contains { $0.url.lastPathComponent == "com.gone.Sandboxed" } == true)
    }
}

@Suite struct OpenFileTests {
    @Test func filesHeldOpenAreSkipped() async throws {
        let fake = AgedHome()
        defer { fake.remove() }
        let busy = try fake.file("Library/Caches/busy/log.txt")
        let idle = try fake.file("Library/Caches/idle/log.txt")
        let tail = Process()
        tail.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        tail.arguments = ["-f", busy.path]
        try tail.run()
        defer { tail.terminate() }
        try await Task.sleep(for: .milliseconds(300))

        let busyFolder = busy.deletingLastPathComponent(), idleFolder = idle.deletingLastPathComponent()
        let holders = OpenFiles.holders(of: [busyFolder, idleFolder])
        #expect(holders[busyFolder]?.contains { $0.name == "tail" } == true)
        #expect(holders[idleFolder] == nil)

        let items = [busyFolder, idleFolder].map { ScanItem(url: $0, size: 1, isDirectory: true) }
        let report = await Remover(policy: SafetyPolicy(home: fake.home), mode: .permanent).remove(items)
        #expect(report.removed.map(\.url.lastPathComponent) == ["idle"])
        #expect(report.failures.first?.reason.hasPrefix("In use by tail") == true)
        #expect(FileManager.default.fileExists(atPath: busy.path))
    }
}

@Suite struct BackupExclusionTests {
    @Test func excludesAndRestores() throws {
        let fake = AgedHome()
        defer { fake.remove() }
        let folder = try fake.file("Projects/app/node_modules/x/index.js").deletingLastPathComponent().deletingLastPathComponent()
        #expect(!BackupExclusion.isExcluded(folder))
        #expect(BackupExclusion.setExcluded(true, [folder]).isEmpty)
        #expect(BackupExclusion.isExcluded(folder))
        BackupExclusion.setExcluded(false, [folder])
        #expect(!BackupExclusion.isExcluded(folder))
    }
}
