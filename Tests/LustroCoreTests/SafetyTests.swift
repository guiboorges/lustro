import Foundation
import Testing
@testable import LustroCore

/// A throwaway home folder so tests never touch the real one.
final class FakeHome {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lustro-tests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func file(_ relative: String, bytes: Int = 4096) throws -> URL {
        let target = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: target)
        return target
    }

    @discardableResult
    func dir(_ relative: String) throws -> URL {
        let target = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }
}

@Suite struct SafetyPolicyTests {
    @Test func allowsCacheContents() throws {
        let home = try FakeHome()
        let cache = try home.file("Library/Caches/com.example.app/data.bin")
        let policy = SafetyPolicy(home: home.url)
        #expect(policy.isAllowed(cache))
        #expect(policy.isAllowed(cache.deletingLastPathComponent()))
    }

    @Test func refusesProtectedFolders() throws {
        let home = try FakeHome()
        for rel in ["Library", "Library/Caches", "Documents", "Desktop", "Library/Application Support", ".Trash"] {
            let url = try home.dir(rel)
            #expect(!SafetyPolicy(home: home.url).isAllowed(url), "should refuse \(rel)")
        }
        #expect(!SafetyPolicy(home: home.url).isAllowed(home.url))
    }

    @Test func refusesDeniedLocationsAtAnyDepth() throws {
        let home = try FakeHome()
        let policy = SafetyPolicy(home: home.url)
        for rel in ["Library/Keychains/login.keychain-db", ".ssh/id_ed25519", "Library/Mail/V10/x.emlx",
                    "Library/Mobile Documents/com~apple~CloudDocs/file.txt"] {
            let url = try home.file(rel)
            #expect(throws: SafetyViolation.self) { try policy.validate(url) }
        }
    }

    @Test func refusesSystemAndOutsideHome() {
        let policy = SafetyPolicy(home: URL(fileURLWithPath: NSHomeDirectory()))
        for path in ["/", "/System/Library/Caches", "/usr/bin/true", "/Applications", "/Library/Caches", "/etc/hosts"] {
            #expect(!policy.isAllowed(URL(fileURLWithPath: path)), "should refuse \(path)")
        }
    }

    @Test func refusesPathsThroughSymlinkedParents() throws {
        let home = try FakeHome()
        let outside = try FakeHome()
        let precious = try outside.file("precious/data.txt")
        let link = home.url.appendingPathComponent("Library/Caches/sneaky")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: precious.deletingLastPathComponent())

        let policy = SafetyPolicy(home: home.url)
        // The link itself may go (removing a link never touches its target)...
        #expect(policy.isAllowed(link))
        // ...but nothing reached *through* it.
        #expect(!policy.isAllowed(link.appendingPathComponent("data.txt")))
    }

    @Test func honoursIgnoreList() throws {
        let home = try FakeHome()
        let keep = try home.file("Library/Caches/com.keep.me/a")
        let policy = SafetyPolicy(home: home.url, ignoredPaths: [keep.deletingLastPathComponent()])
        #expect(!policy.isAllowed(keep))
        #expect(!policy.isAllowed(keep.deletingLastPathComponent()))
    }

    @Test func refusesMissingFiles() throws {
        let home = try FakeHome()
        let gone = home.url.appendingPathComponent("Library/Caches/nothing-here")
        #expect(throws: SafetyViolation.missing(gone.path)) { try SafetyPolicy(home: home.url).validate(gone) }
    }

    @Test func refusesDotDotEscapes() throws {
        let home = try FakeHome()
        try home.dir("Library/Caches")
        let sneaky = URL(fileURLWithPath: home.url.path + "/Library/Caches/../../Documents")
        try home.dir("Documents")
        #expect(!SafetyPolicy(home: home.url).isAllowed(sneaky))
    }
}

@Suite struct RemoverTests {
    @Test func trashesByDefaultAndRevalidates() async throws {
        let home = try FakeHome()
        let ok = try home.file("Library/Caches/com.example/a.bin")
        let protected = try home.dir("Documents")
        let policy = SafetyPolicy(home: home.url)
        let items = [DiskUsage.item(for: ok.deletingLastPathComponent())!,
                     ScanItem(url: protected, size: 1, isDirectory: true)]

        let report = await Remover(policy: policy, mode: .permanent).remove(items)
        #expect(report.removed.count == 1)
        #expect(report.failures.count == 1)
        #expect(!FileManager.default.fileExists(atPath: ok.path))
        #expect(FileManager.default.fileExists(atPath: protected.path))
    }

    @Test func dryRunTouchesNothing() async throws {
        let home = try FakeHome()
        let file = try home.file("Library/Logs/app.log")
        let report = await Remover(policy: SafetyPolicy(home: home.url), mode: .permanent, dryRun: true)
            .remove([DiskUsage.item(for: file)!])
        #expect(report.removed.count == 1)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
}
