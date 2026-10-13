import Foundation
import Testing
@testable import LimpoCore

@Suite struct AppOwnershipTests {
    let home = URL(fileURLWithPath: "/Users/test")
    let chrome = RunningApp(bundleID: "com.google.Chrome", name: "Google Chrome", pid: 1)
    let firefox = RunningApp(bundleID: "org.mozilla.firefox", name: "Firefox", pid: 2)
    let code = RunningApp(bundleID: "com.microsoft.VSCode", name: "Code", pid: 3)
    var running: [RunningApp] { [chrome, firefox, code] }

    func owners(_ relative: String, explicit: [String] = []) -> [String] {
        AppOwnership(home: home)
            .runningOwners(of: home.appendingPathComponent(relative), explicitOwners: explicit, running: running)
            .map(\.name)
    }

    @Test func bundleIDFolders() {
        #expect(owners("Library/Caches/com.google.Chrome") == ["Google Chrome"])
        #expect(owners("Library/Caches/com.microsoft.VSCode.ShipIt") == ["Code"])         // helper of the app
        #expect(owners("Library/Containers/com.google.Chrome.helper/Data/Library/Caches/x") == ["Google Chrome"])
        #expect(owners("Library/Group Containers/EQHXZ8M8AV.com.google.Chrome/x") == ["Google Chrome"])
    }

    @Test func nameFolders() {
        #expect(owners("Library/Caches/Firefox/Profiles") == ["Firefox"])
        #expect(owners("Library/Caches/Google") == ["Google Chrome"])
    }

    @Test func unrelatedFoldersDoNotMatch() {
        #expect(owners("Library/Caches/com.spotify.client").isEmpty)
        #expect(owners("Library/Caches/com").isEmpty)
        #expect(owners(".npm/_cacache").isEmpty)
    }

    @Test func explicitOwnersFromRules() {
        #expect(owners("Library/Application Support/Code/Cache", explicit: ["com.microsoft.VSCode"]) == ["Code"])
    }
}
