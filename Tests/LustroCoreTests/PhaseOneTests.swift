import Foundation
import Testing
@testable import LustroCore

@Suite struct ProtectionFlagTests {
    @Test func lockedFilesAreRefused() throws {
        let home = try FakeHome()
        let file = try home.file("Library/Caches/com.example/locked.bin")
        #expect(chflags(file.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { chflags(file.path, 0) }
        #expect(throws: SafetyViolation.systemProtected(file.path)) { try SafetyPolicy(home: home.url).validate(file) }
    }
}

@Suite struct HistoryTests {
    @Test func recordsAndRestores() async throws {
        let home = try FakeHome()
        let store = HistoryStore(fileURL: home.url.appendingPathComponent("history.json"))
        // Simulate an item that was moved to a trash folder.
        let original = home.url.appendingPathComponent("Library/Caches/com.example")
        let trashed = try home.dir(".Trash/com.example")
        try Data("x".utf8).write(to: trashed.appendingPathComponent("blob"))

        var report = RemovalReport(dryRun: false, mode: .trash)
        let item = ScanItem(url: original, size: 1234, isDirectory: true)
        report.removed = [item]
        report.trashLocations[item.id] = trashed
        let entry = try #require(store.record(module: "Cleanup", report: report, rules: [item.id: "system-user-caches"]))

        #expect(store.load().first?.status() == .inTrash)
        #expect(store.load().first?.items.first?.rule == "system-user-caches")

        let failures = store.restore(entryID: entry.id, policy: SafetyPolicy(home: home.url))
        #expect(failures.isEmpty)
        #expect(FileManager.default.fileExists(atPath: original.appendingPathComponent("blob").path))
        #expect(store.load().first?.status() == .restored)
    }

    @Test func neverOverwritesOnRestore() throws {
        let home = try FakeHome()
        let store = HistoryStore(fileURL: home.url.appendingPathComponent("history.json"))
        let original = try home.file("Library/Caches/again/data")   // something new took its place
        let trashed = try home.file(".Trash/data")
        var report = RemovalReport(dryRun: false, mode: .trash)
        let item = ScanItem(url: original, size: 1, isDirectory: false)
        report.removed = [item]
        report.trashLocations[item.id] = trashed
        let entry = try #require(store.record(module: "Cleanup", report: report))
        let failures = store.restore(entryID: entry.id, policy: SafetyPolicy(home: home.url))
        #expect(failures[original.path] != nil)
        #expect(FileManager.default.fileExists(atPath: trashed.path))
    }

    @Test func dryRunsAreSimulations() throws {
        let home = try FakeHome()
        let store = HistoryStore(fileURL: home.url.appendingPathComponent("history.json"))
        var report = RemovalReport(dryRun: true, mode: .trash)
        report.removed = [ScanItem(url: home.url.appendingPathComponent("x"), size: 1, isDirectory: false)]
        #expect(store.record(module: "Cleanup", report: report)?.status() == .simulation)
    }
}

@Suite struct ExplainerTests {
    @Test func explainsOwnerAgeAndProtection() throws {
        let home = try FakeHome()
        let cache = try home.dir("Library/Caches/com.google.Chrome")
        let item = ScanItem(url: cache, size: 10, isDirectory: true,
                            lastModified: Date().addingTimeInterval(-5 * 86_400), evidence: "Listed by rule system-user-caches")
        let group = ScanGroup(id: "system-user-caches", title: "App caches", detail: "", section: "System",
                              risk: .safe, autoSelect: true, items: [item])
        let chrome = RunningApp(bundleID: "com.google.Chrome", name: "Google Chrome", pid: 1)
        let reasons = Explainer(policy: SafetyPolicy(home: home.url))
            .reasons(for: item, in: group, ownerName: "Google Chrome", runningOwners: [chrome])
        let texts = reasons.map(\.text)
        #expect(texts.contains("Belongs to Google Chrome (com.google.Chrome)"))
        #expect(texts.contains("Not modified in the last 5 days"))
        #expect(texts.contains { $0.hasPrefix("Not a protected folder") })
        #expect(reasons.last == Reason(.warning, "Google Chrome is open: you'll be asked to quit it first"))
    }
}

@Suite struct EvidenceTests {
    @Test func devPurgeSaysWhichMarkerProvedIt() async throws {
        let home = try FakeHome()
        try home.file("Developer/web/package.json", bytes: 10)
        try home.file("Developer/web/node_modules/a/index.js")
        let groups = await ProjectArtifactScanner(roots: [home.url.appendingPathComponent("Developer")],
                                                  policy: SafetyPolicy(home: home.url)).scan()
        #expect(groups.first?.items.first?.evidence == "Found next to package.json, so it belongs to a JavaScript project")
        #expect(groups.first?.lastActivity != nil)
    }

    @Test func newestBackupPerDeviceIsKept() throws {
        let home = try FakeHome()
        func backup(_ name: String, device: String, id: String, daysAgo: Double) throws -> ScanItem {
            let dir = try home.dir("Backup/\(name)")
            let plist: [String: Any] = ["Device Name": device, "Target Identifier": id,
                                        "Last Backup Date": Date().addingTimeInterval(-daysAgo * 86_400)]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: dir.appendingPathComponent("Info.plist"))
            return DiskUsage.item(for: dir)!
        }
        let items = [try backup("a", device: "iPhone", id: "1", daysAgo: 1),
                     try backup("b", device: "iPhone", id: "1", daysAgo: 90),
                     try backup("c", device: "iPad", id: "2", daysAgo: 30)]
        let kept = DeviceBackups.label(items, keepNewest: true)
        #expect(kept.map(\.url.lastPathComponent) == ["b"])
        #expect(kept.first?.note?.hasPrefix("iPhone · ") == true)
        #expect(DeviceBackups.label(items, keepNewest: false).count == 3)
    }
}

@Suite struct RenameMigrationTests {
    @Test func movesSettingsFromPreviousName() throws {
        let home = try FakeHome()
        try home.file("Library/Application Support/Limpo/settings.json", bytes: 2)
        LustroSettings.migrateFromPreviousName(home: home.url)
        #expect(FileManager.default.fileExists(atPath: home.url.appendingPathComponent("Library/Application Support/Lustro/settings.json").path))
        #expect(!FileManager.default.fileExists(atPath: home.url.appendingPathComponent("Library/Application Support/Limpo").path))
    }
}
