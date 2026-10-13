import Foundation

/// A kind of regenerable build or dependency folder found inside software projects.
public struct ArtifactRule: Sendable {
    /// Folder name pattern, e.g. `node_modules` or `cmake-build-*`.
    public let name: String
    /// At least one sibling of the artifact must match one of these patterns.
    /// An empty list means the artifact's own contents must match `contains` instead.
    public let siblingMarkers: [String]
    /// Alternative proof: the artifact contains an entry matching one of these patterns.
    public let contains: [String]
    public let ecosystem: String

    public init(_ name: String, markers: [String], contains: [String] = [], ecosystem: String) {
        self.name = name
        self.siblingMarkers = markers
        self.contains = contains
        self.ecosystem = ecosystem
    }

    static let js = ["package.json"]
    static let python = ["pyproject.toml", "setup.py", "setup.cfg", "requirements*.txt", "Pipfile", "poetry.lock", "uv.lock", "tox.ini"]

    /// Conservative defaults: generic names like `build` or `bin` require ecosystem-specific proof.
    public static let defaults: [ArtifactRule] = [
        .init("node_modules", markers: js, ecosystem: "JavaScript"),
        .init(".next", markers: js, ecosystem: "Next.js"),
        .init(".nuxt", markers: js, ecosystem: "Nuxt"),
        .init(".output", markers: js, ecosystem: "Nuxt/Nitro"),
        .init(".svelte-kit", markers: js, ecosystem: "SvelteKit"),
        .init(".astro", markers: js, ecosystem: "Astro"),
        .init(".angular", markers: ["angular.json"], ecosystem: "Angular"),
        .init(".turbo", markers: js, ecosystem: "Turborepo"),
        .init(".parcel-cache", markers: js, ecosystem: "Parcel"),
        .init(".vite", markers: js, ecosystem: "Vite"),
        .init(".swc", markers: js, ecosystem: "SWC"),
        .init(".docusaurus", markers: js, ecosystem: "Docusaurus"),
        .init(".expo", markers: js, ecosystem: "Expo"),
        .init("storybook-static", markers: js, ecosystem: "Storybook"),
        .init("dist", markers: js + ["pyproject.toml", "setup.py"], ecosystem: "Build output"),
        .init("coverage", markers: js, ecosystem: "Test coverage"),
        .init("target", markers: ["Cargo.toml", "pom.xml", "build.sbt"], ecosystem: "Rust/Maven/sbt"),
        .init("build", markers: ["build.gradle", "build.gradle.kts", "CMakeLists.txt", "pubspec.yaml", "setup.py", "meson.build"] + js, ecosystem: "Build output"),
        .init(".gradle", markers: ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"], ecosystem: "Gradle"),
        .init(".kotlin", markers: ["build.gradle.kts", "settings.gradle.kts"], ecosystem: "Kotlin"),
        .init(".build", markers: ["Package.swift"], ecosystem: "Swift"),
        .init("DerivedData", markers: ["*.xcodeproj", "*.xcworkspace"], ecosystem: "Xcode"),
        .init("Pods", markers: ["Podfile"], ecosystem: "CocoaPods"),
        .init(".venv", markers: python, contains: ["pyvenv.cfg"], ecosystem: "Python"),
        .init("venv", markers: python, contains: ["pyvenv.cfg"], ecosystem: "Python"),
        .init("__pycache__", markers: [], contains: ["*.pyc"], ecosystem: "Python"),
        .init(".pytest_cache", markers: [], contains: ["CACHEDIR.TAG"], ecosystem: "Python"),
        .init(".mypy_cache", markers: [], contains: ["CACHEDIR.TAG"], ecosystem: "Python"),
        .init(".ruff_cache", markers: [], contains: ["CACHEDIR.TAG"], ecosystem: "Python"),
        .init(".tox", markers: ["tox.ini", "pyproject.toml", "setup.cfg"], ecosystem: "Python"),
        .init(".nox", markers: ["noxfile.py"], ecosystem: "Python"),
        .init(".dart_tool", markers: ["pubspec.yaml"], ecosystem: "Dart/Flutter"),
        .init("zig-out", markers: ["build.zig"], ecosystem: "Zig"),
        .init(".zig-cache", markers: ["build.zig"], ecosystem: "Zig"),
        .init("zig-cache", markers: ["build.zig"], ecosystem: "Zig"),
        .init("elm-stuff", markers: ["elm.json"], ecosystem: "Elm"),
        .init(".stack-work", markers: ["stack.yaml"], ecosystem: "Haskell"),
        .init("dist-newstyle", markers: ["*.cabal", "cabal.project"], ecosystem: "Haskell"),
        .init("_build", markers: ["mix.exs", "dune-project", "rebar.config"], ecosystem: "Elixir/OCaml/Erlang"),
        .init("cmake-build-*", markers: ["CMakeLists.txt"], ecosystem: "CMake"),
        .init("bin", markers: ["*.csproj", "*.fsproj", "*.vbproj"], ecosystem: ".NET"),
        .init("obj", markers: ["*.csproj", "*.fsproj", "*.vbproj"], ecosystem: ".NET"),
    ]
}

/// A project folder together with the artifacts found in it.
public struct ProjectArtifacts: Sendable {
    public let project: URL
    public let lastActivity: Date?
    public let artifacts: [ScanItem]
}

/// Walks project folders looking for regenerable artifacts.
///
/// Safety rules: an artifact is only reported when a project marker proves what it is,
/// symlinks are never followed, and the walk never enters an artifact, a bundle,
/// or a hidden folder (except to recognise it as an artifact).
public struct ProjectArtifactScanner: Sendable {
    public let roots: [URL]
    public let rules: [ArtifactRule]
    public let maxDepth: Int
    public let policy: SafetyPolicy
    /// Projects untouched for at least this many days start selected.
    public let inactiveDaysForAutoSelect: Int
    public let now: Date

    public static let defaultRootNames = ["Developer", "Projects", "Code", "code", "dev", "src", "GitHub",
                                          "Workspace", "workspace", "Repos", "repos", "Development", "www",
                                          "Documents", "Desktop"]

    public static func defaultRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        var seen = Set<String>()
        return defaultRootNames
            .map { home.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .filter { seen.insert($0.resolvingSymlinksInPath().path.lowercased()).inserted }
    }

    public init(roots: [URL], rules: [ArtifactRule] = ArtifactRule.defaults, maxDepth: Int = 8,
                policy: SafetyPolicy = SafetyPolicy(), inactiveDaysForAutoSelect: Int = 30, now: Date = Date()) {
        self.roots = roots
        self.rules = rules
        self.maxDepth = maxDepth
        self.policy = policy
        self.inactiveDaysForAutoSelect = inactiveDaysForAutoSelect
        self.now = now
    }

    static let neverEnter: Set<String> = [".git", ".hg", ".svn", "Library", "Applications", ".Trash",
                                          "Photos Library.photoslibrary", "Music", "Movies", "Pictures"]

    public func scan(progress: ProgressHandler? = nil) async -> [ScanGroup] {
        let projects = findProjects(progress: progress)
        let cutoff = now.addingTimeInterval(-Double(inactiveDaysForAutoSelect) * 86_400)
        return projects.map { project in
            let inactive = (project.lastActivity ?? .distantPast) < cutoff
            let ecosystems = Set(project.artifacts.compactMap(\.note)).sorted().joined(separator: ", ")
            return ScanGroup(
                id: project.project.path,
                title: project.project.lastPathComponent,
                detail: project.project.path.replacingOccurrences(of: policy.home.path, with: "~"),
                section: ecosystems.isEmpty ? "Projects" : ecosystems,
                risk: .safe,
                autoSelect: inactive,
                items: project.artifacts.sorted { $0.size > $1.size }
            )
        }
        .sorted { $0.totalSize > $1.totalSize }
    }

    public func findProjects(progress: ProgressHandler? = nil) -> [ProjectArtifacts] {
        var found: [String: [ScanItem]] = [:]
        var queue: [(URL, Int)] = roots.map { ($0.standardizedFileURL, 0) }
        var visited = Set<String>()
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]

        while !queue.isEmpty {
            if Task.isCancelled { break }
            let (dir, depth) = queue.removeFirst()
            guard visited.insert(dir.resolvingSymlinksInPath().path).inserted else { continue }
            progress?(ScanProgress(message: dir.path.replacingOccurrences(of: policy.home.path, with: "~")))

            guard let children = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: []) else { continue }
            let siblingNames = children.map(\.lastPathComponent)

            for child in children {
                guard let v = try? child.resourceValues(forKeys: Set(keys)),
                      v.isDirectory == true, v.isSymbolicLink != true else { continue }
                let name = child.lastPathComponent

                if let rule = matchingRule(name: name, artifact: child, siblings: siblingNames) {
                    if policy.isAllowed(child), let item = DiskUsage.item(for: child, note: rule.ecosystem), item.size > 0 {
                        found[dir.path, default: []].append(item)
                    }
                    continue // never descend into an artifact
                }
                if name.hasPrefix(".") || v.isPackage == true || Self.neverEnter.contains(name) { continue }
                if depth + 1 <= maxDepth { queue.append((child, depth + 1)) }
            }
        }

        return found.map { path, artifacts in
            let project = URL(fileURLWithPath: path)
            return ProjectArtifacts(project: project, lastActivity: lastActivity(of: project, excluding: artifacts), artifacts: artifacts)
        }
    }

    func matchingRule(name: String, artifact: URL, siblings: [String]) -> ArtifactRule? {
        for rule in rules where PathPattern.matches(name, rule.name) {
            let hasMarker = rule.siblingMarkers.contains { marker in siblings.contains { PathPattern.matches($0, marker) } }
            if hasMarker { return rule }
            if !rule.contains.isEmpty {
                let inside = (try? FileManager.default.contentsOfDirectory(atPath: artifact.path)) ?? []
                if rule.contains.contains(where: { pattern in inside.contains { PathPattern.matches($0, pattern) } }) {
                    return rule
                }
            }
        }
        // Any folder tagged with a CACHEDIR.TAG declares itself a cache (https://bford.info/cachedir/).
        let tag = artifact.appendingPathComponent("CACHEDIR.TAG")
        if let head = try? FileHandle(forReadingFrom: tag).read(upToCount: 43),
           String(decoding: head, as: UTF8.self).hasPrefix("Signature: 8a477f597d28d172789f06886806bc55") {
            return ArtifactRule(name, markers: [], ecosystem: "Cache (CACHEDIR.TAG)")
        }
        return nil
    }

    /// Latest modification among the project's top-level entries, ignoring the artifacts themselves.
    func lastActivity(of project: URL, excluding artifacts: [ScanItem]) -> Date? {
        let skip = Set(artifacts.map(\.url.lastPathComponent))
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: project, includingPropertiesForKeys: [.contentModificationDateKey], options: [])) ?? []
        return entries
            .filter { !skip.contains($0.lastPathComponent) }
            .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            .max()
    }
}
