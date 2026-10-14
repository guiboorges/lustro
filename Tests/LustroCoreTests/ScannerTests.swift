import Foundation
import Testing
@testable import LustroCore

@Suite struct JunkScannerTests {
    func catalog(_ json: String) throws -> RuleCatalog {
        try JSONDecoder().decode(RuleCatalog.self, from: Data(json.utf8))
    }

    @Test func bundledCatalogLoads() throws {
        let catalog = try RuleCatalog.bundled()
        #expect(catalog.categories.count > 10)
        #expect(Set(catalog.categories.map(\.id)).count == catalog.categories.count, "category IDs must be unique")
    }

    @Test func specificCategoriesWinAndRecentItemsStay() async throws {
        let home = try FakeHome()
        try home.file("Library/Caches/claude-cli-nodejs/fresh.log")          // recent: must stay
        try home.file("Library/Caches/com.example/blob")                     // generic cache
        try home.file("Library/Caches/com.apple.nsurlsessiond/download.tmp") // excluded

        let rules = try catalog("""
        {"version":1,"categories":[
          {"id":"claude","section":"AI","title":"Claude","detail":"","risk":"safe","autoSelect":true,"minAgeHours":24,
           "targets":[{"path":"~/Library/Caches/claude-cli-nodejs/*"}]},
          {"id":"caches","section":"System","title":"Caches","detail":"","risk":"safe","autoSelect":true,
           "targets":[{"path":"~/Library/Caches/*","exclude":["com.apple.nsurlsessiond"]}]}
        ]}
        """)
        let groups = await JunkScanner(catalog: rules, policy: SafetyPolicy(home: home.url)).scan()
        let paths = groups.flatMap(\.items).map(\.url.lastPathComponent)
        #expect(paths == ["com.example"])
    }

    @Test func fullDiskAccessCategoriesNeedPermission() throws {
        let rules = try catalog("""
        {"version":1,"categories":[
          {"id":"a","section":"S","title":"A","detail":"","risk":"safe","autoSelect":true,"requiresFullDiskAccess":true,"targets":[]},
          {"id":"b","section":"S","title":"B","detail":"","risk":"safe","autoSelect":true,"targets":[]}
        ]}
        """)
        #expect(JunkScanner(catalog: rules).activeCategories.map(\.id) == ["b"])
        #expect(JunkScanner(catalog: rules, hasFullDiskAccess: true).activeCategories.map(\.id) == ["a", "b"])
    }

    @Test func cautionGroupsAreNeverAutoSelected() {
        let group = ScanGroup(id: "x", title: "", detail: "", section: "", risk: .caution, autoSelect: true, items: [])
        #expect(group.autoSelect == false)
    }
}

@Suite struct ProjectArtifactTests {
    @Test func findsArtifactsOnlyWithMarkers() async throws {
        let home = try FakeHome()
        try home.file("Developer/web/package.json", bytes: 10)
        try home.file("Developer/web/node_modules/left-pad/index.js")
        try home.file("Developer/web/dist/app.js")
        // `build` without any build-system marker is someone's real folder, not an artifact.
        try home.file("Developer/notes/build/plan.md")
        try home.file("Developer/rusty/Cargo.toml", bytes: 10)
        try home.file("Developer/rusty/target/debug/rusty")

        let scanner = ProjectArtifactScanner(roots: [home.url.appendingPathComponent("Developer")],
                                             policy: SafetyPolicy(home: home.url))
        let found = Set(await scanner.scan().flatMap(\.items).map {
            $0.url.path.replacingOccurrences(of: home.url.path + "/Developer/", with: "")
        })
        #expect(found == ["web/node_modules", "web/dist", "rusty/target"])
    }

    @Test func doesNotDescendIntoArtifacts() async throws {
        let home = try FakeHome()
        try home.file("Developer/app/package.json", bytes: 10)
        try home.file("Developer/app/node_modules/pkg/package.json", bytes: 10)
        try home.file("Developer/app/node_modules/pkg/node_modules/inner/index.js")
        let scanner = ProjectArtifactScanner(roots: [home.url.appendingPathComponent("Developer")],
                                             policy: SafetyPolicy(home: home.url))
        let items = await scanner.scan().flatMap(\.items)
        #expect(items.map(\.url.lastPathComponent) == ["node_modules"])
    }
}

@Suite struct SpaceIndexTests {
    @Test func sizesRollUp() throws {
        let home = try FakeHome()
        try home.file("a/b/c/big.bin", bytes: 1_000_000)
        try home.file("a/small.bin", bytes: 10)
        let index = SpaceIndex(root: home.url)
        index.build()
        let top = index.children(of: home.url)
        #expect(top.first?.name == "a")
        #expect((top.first?.size ?? 0) >= 1_000_000)
        #expect(index.totalSize == top.reduce(0) { $0 + $1.size })
    }
}

@Suite struct UninstallerTests {
    @Test func matchesLeftoversExactly() throws {
        let home = try FakeHome()
        try home.file("Library/Preferences/com.acme.Widget.plist", bytes: 10)
        try home.file("Library/Caches/com.acme.Widget/cache.db")
        try home.file("Library/Application Support/Widget/state.json")
        try home.file("Library/Containers/com.acme.Widget.Extension/Data/x")
        try home.file("Library/Preferences/com.acme.WidgetPro.plist", bytes: 10) // different app
        try home.file("Library/Caches/com.acme/shared")                         // vendor folder, not the app

        let leftovers = Uninstaller(home: home.url, searchRoots: [])
            .leftovers(bundleID: "com.acme.Widget", name: "Widget")
            .map { $0.url.path.replacingOccurrences(of: home.url.path + "/Library/", with: "") }
        #expect(Set(leftovers) == ["Preferences/com.acme.Widget.plist", "Caches/com.acme.Widget",
                                   "Application Support/Widget", "Containers/com.acme.Widget.Extension"])
    }

    @Test func appleAppsAreProtected() {
        #expect(Uninstaller.isProtectedBundle("com.apple.Safari"))
        #expect(!Uninstaller.isProtectedBundle("com.acme.Widget"))
    }
}

@Suite struct PathPatternTests {
    @Test func globMatching() {
        #expect(PathPattern.matches("cmake-build-debug", "cmake-build-*"))
        #expect(PathPattern.matches("requirements-dev.txt", "requirements*.txt"))
        #expect(!PathPattern.matches("node_modules2", "node_modules"))
    }
}
