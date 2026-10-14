import Foundation

/// Processes that belong together: an AI agent session, a command running in a terminal, or an orphan.
public struct ProcessGroup: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// An AI coding agent, e.g. "Claude Code".
        case agent(String)
        /// A command started from a terminal shell.
        case terminal
        /// A developer process whose parent has gone away (its terminal or agent session ended).
        case orphan
        /// A server or tool an app started for you, e.g. a preview server opened by the Claude app.
        case launchedBy(String)
    }

    public var id: Int32 { root.pid }
    public let kind: Kind
    public let title: String
    public let root: ProcessEntry
    /// The root and everything it started.
    public let members: [ProcessEntry]
    public let ports: [ListeningPort]
    /// The app that started it, directly or through helpers (e.g. "Claude" for its embedded Claude Code).
    public let startedBy: String?

    public var cpuPercent: Double { members.reduce(0) { $0 + $1.cpuPercent } }
    public var memory: Int64 { members.reduce(0) { $0 + $1.memory } }
    public var folder: String? { root.cwd }
    public var isAgent: Bool { if case .agent = kind { true } else { false } }
    /// Agents, then terminal commands, then what apps started.
    var sortRank: Int {
        switch kind {
        case .agent: 0
        case .terminal: 1
        case .launchedBy: 2
        case .orphan: 3
        }
    }

    /// Busy right now, or running a command it started in the last two minutes (agents wait on the network a lot).
    public var isWorking: Bool {
        cpuPercent >= 3 || members.dropFirst().contains { child in
            (child.runningTime ?? .infinity) < 120 && !DevActivity.displayCommand(child).lowercased().contains("mcp")
        }
    }

    /// Descendants worth listing under the group: not shells, busiest first.
    public var notableChildren: [ProcessEntry] {
        members.dropFirst()
            .filter { !DevActivity.shells.contains($0.command) || $0.arguments.contains("-c") }
            .sorted { ($0.cpuPercent, $0.memory) > ($1.cpuPercent, $1.memory) }
    }
}

/// A listening port with the process and group behind it.
public struct PortRow: Identifiable, Sendable, Equatable {
    public var id: String { port.id }
    public let port: ListeningPort
    public let process: ProcessEntry
    public let group: ProcessGroup?
}

public struct DevActivityReport: Sendable, Equatable {
    /// Agent sessions and terminal commands, busiest first.
    public let sessions: [ProcessGroup]
    public let orphans: [ProcessGroup]
    public let ports: [PortRow]

    public static let empty = DevActivityReport(sessions: [], orphans: [], ports: [])
}

/// Turns the raw process table into "what did I leave running?". Pure, so the rules are testable.
public enum DevActivity {
    /// Prompt helpers that live inside every shell; not something you "left running".
    static let shellHelpers = ["gitstatusd", "starship", "atuin", "direnv", "mcfly", "zoxide", "zsh-autosuggest"]
    static let shells: Set<String> = ["zsh", "bash", "sh", "fish", "login", "tmux", "screen", "nu", "dash", "ksh", "tcsh", "csh", "xonsh", "elvish"]
    static let interpreters: Set<String> = ["node", "bun", "deno", "ruby", "php", "perl"]
    static let packageRunners: Set<String> = ["npm", "npx", "pnpm", "yarn", "bunx", "pnpx"]
    static let runtimes: Set<String> = [
        "node", "npm", "npx", "pnpm", "yarn", "bun", "bunx", "deno", "ruby", "rails", "puma", "java", "gradle", "mvn", "php",
        "go", "cargo", "rustc", "dotnet", "esbuild", "vite", "next-server", "webpack", "tsc", "tsx", "ts-node", "nodemon",
        "jest", "vitest", "playwright", "uvicorn", "gunicorn", "flask", "celery", "jupyter", "jupyter-lab", "streamlit",
        "hugo", "caddy", "http-server", "serve", "watchman", "turbo", "nx", "astro", "remix", "wrangler", "firebase",
    ]

    /// Known AI coding agents, by command name.
    static let agentCommands: [String: String] = [
        "claude": "Claude Code", "codex": "Codex", "gemini": "Gemini CLI", "aider": "Aider", "cursor-agent": "Cursor Agent",
        "opencode": "OpenCode", "goose": "Goose", "amp": "Amp", "copilot": "Copilot CLI", "qwen": "Qwen Code", "crush": "Crush",
        "droid": "Droid", "kiro": "Kiro CLI", "cline": "Cline",
    ]
    /// Agents installed as npm packages run as `node …/<package>/…`.
    static let agentPackages: [String: String] = [
        "/@anthropic-ai/claude-code/": "Claude Code", "/@openai/codex/": "Codex", "/@google/gemini-cli/": "Gemini CLI",
        "/opencode-ai/": "OpenCode", "/@sourcegraph/amp/": "Amp", "/@github/copilot/": "Copilot CLI", "/@qwen-code/": "Qwen Code",
    ]

    public static func agentName(_ entry: ProcessEntry) -> String? {
        // By command name only outside apps: the Claude desktop app's own executable is also called "Claude".
        if entry.appPath == nil, let name = agentCommands[entry.command.lowercased()] { return name }
        // Claude Code installs versioned binaries (`~/.local/share/claude/versions/2.1.296`); the desktop app embeds one too.
        if entry.path.contains("/claude/versions/") || entry.path.contains("/claude-code/") { return "Claude Code" }
        if interpreters.contains(entry.command), entry.arguments.count > 1 {
            for (package, name) in agentPackages where entry.arguments[1].contains(package) { return name }
        }
        return nil
    }

    public static func isRuntime(_ entry: ProcessEntry) -> Bool {
        let command = entry.command.lowercased()
        return runtimes.contains(command) || command.hasPrefix("python") || command.hasPrefix("node")
    }

    /// A readable, redacted command line: `node …/.bin/vite preview` → `vite preview`, `npm exec x` → `x`, home → `~`.
    public static func displayCommand(_ entry: ProcessEntry, home: String = NSHomeDirectory()) -> String {
        var parts = entry.arguments.isEmpty ? [entry.name] : entry.arguments
        parts[0] = entry.command
        if interpreters.contains(parts[0]) || parts[0].hasPrefix("python"), parts.count > 1, !parts[1].hasPrefix("-") {
            parts.removeFirst()
            parts[0] = (parts[0] as NSString).lastPathComponent
        }
        if packageRunners.contains(parts[0]), parts.count > 2, ["exec", "dlx", "x"].contains(parts[1]) {
            parts.removeFirst(2)
        }
        return CommandRedactor.redact(parts)
            .map { $0.replacingOccurrences(of: home, with: "~") }
            .map { $0.count > 48 ? $0.prefix(45) + "…" : $0 }
            .map { $0.contains(" ") ? "\"\($0)\"" : $0 }
            .joined(separator: " ")
    }

    /// Groups the process table. `launchPrograms` are executables started by launch agents; those aren't orphans.
    public static func analyze(processes: [ProcessEntry], ports: [ListeningPort], launchPrograms: Set<String> = []) -> DevActivityReport {
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var childrenOf: [Int32: [ProcessEntry]] = [:]
        for entry in processes { childrenOf[entry.ppid, default: []].append(entry) }
        let portsByPID = Dictionary(grouping: ports, by: \.pid)

        func descendants(of root: ProcessEntry, excluding claimed: Set<Int32>) -> [ProcessEntry] {
            var result = [root]
            var queue = [root.pid]
            while let pid = queue.popLast() {
                for child in childrenOf[pid] ?? [] where !claimed.contains(child.pid) {
                    result.append(child)
                    queue.append(child.pid)
                }
            }
            return result
        }
        func hasAgentAncestor(_ entry: ProcessEntry) -> Bool {
            var pid = entry.ppid
            var hops = 0
            while let parent = byPID[pid], hops < 64 {
                if agentName(parent) != nil { return true }
                pid = parent.ppid
                hops += 1
            }
            return false
        }
        func launcherApp(of entry: ProcessEntry) -> String? {
            var pid = entry.ppid
            var hops = 0
            while let parent = byPID[pid], hops < 64 {
                if let app = parent.appPath { return ProcessMonitor.displayName(ofApp: app) }
                pid = parent.ppid
                hops += 1
            }
            return nil
        }
        func makeGroup(_ kind: ProcessGroup.Kind, _ title: String, _ members: [ProcessEntry]) -> ProcessGroup {
            ProcessGroup(kind: kind, title: title, root: members[0], members: members,
                         ports: members.flatMap { portsByPID[$0.pid] ?? [] }, startedBy: launcherApp(of: members[0]))
        }

        var claimed = Set<Int32>()
        var sessions: [ProcessGroup] = []
        var orphans: [ProcessGroup] = []

        // Orphans first, so an agent whose terminal closed still counts as left behind.
        for entry in processes where entry.ppid == 1 && !entry.isSystem && entry.appPath == nil && entry.tty == nil {
            let launched = launchPrograms.contains(entry.path) || entry.arguments.first.map(launchPrograms.contains) == true
            let members = descendants(of: entry, excluding: claimed)
            let listens = members.contains { portsByPID[$0.pid] != nil }
            guard !launched, isRuntime(entry) || agentName(entry) != nil || listens else { continue }
            claimed.formUnion(members.map(\.pid))
            orphans.append(makeGroup(.orphan, agentName(entry) ?? displayCommand(entry), members))
        }
        for entry in processes where !claimed.contains(entry.pid) {
            guard let name = agentName(entry), !hasAgentAncestor(entry) else { continue }
            let members = descendants(of: entry, excluding: claimed)
            claimed.formUnion(members.map(\.pid))
            sessions.append(makeGroup(.agent(name), name, members))
        }
        for entry in processes where !claimed.contains(entry.pid) && entry.tty != nil && !entry.isSystem && entry.appPath == nil {
            guard !shells.contains(entry.command), !shellHelpers.contains(where: entry.command.hasPrefix),
                  let parent = byPID[entry.ppid], shells.contains(parent.command) else { continue }
            let members = descendants(of: entry, excluding: claimed)
            claimed.formUnion(members.map(\.pid))
            sessions.append(makeGroup(.terminal, displayCommand(entry), members))
        }
        // Command-line servers and tools started by an app. Only the ones that matter: listening or busy.
        for entry in processes where !claimed.contains(entry.pid) && !entry.isSystem && entry.appPath == nil {
            guard let parent = byPID[entry.ppid], let app = parent.appPath else { continue }
            let members = descendants(of: entry, excluding: claimed)
            let group = makeGroup(.launchedBy(ProcessMonitor.displayName(ofApp: app)), displayCommand(entry), members)
            guard !group.ports.isEmpty || group.cpuPercent >= 5 || group.memory >= 200_000_000 else { continue }
            claimed.formUnion(members.map(\.pid))
            sessions.append(group)
        }

        let groupOf = Dictionary((sessions + orphans).flatMap { group in group.members.map { ($0.pid, group) } },
                                 uniquingKeysWith: { first, _ in first })
        let portRows = ports.compactMap { port -> PortRow? in
            guard let process = byPID[port.pid] else { return nil }
            // Apps open plenty of private localhost ports (editor extension hosts…); only network-exposed ones matter.
            if process.appPath != nil && groupOf[port.pid] == nil && !port.exposed { return nil }
            return PortRow(port: port, process: process, group: groupOf[port.pid])
        }
        .sorted { ($0.port.exposed ? 0 : 1, $0.port.port) < ($1.port.exposed ? 0 : 1, $1.port.port) }

        return DevActivityReport(
            sessions: sessions.sorted { ($0.sortRank, -$0.cpuPercent) < ($1.sortRank, -$1.cpuPercent) },
            orphans: orphans.sorted { (($0.ports.isEmpty ? 1 : 0), -($0.root.runningTime ?? 0)) < (($1.ports.isEmpty ? 1 : 0), -($1.root.runningTime ?? 0)) },
            ports: portRows)
    }
}

/// Hides secrets in command lines before they're shown: tokens, passwords, keys, credentials in URLs.
public enum CommandRedactor {
    public static let mask = "•••"
    static let secretWords = ["token", "password", "passwd", "secret", "apikey", "api-key", "api_key", "auth", "credential",
                              "private-key", "access-key", "client-secret", "bearer", "cookie", "session"]
    static let tokenPatterns: [NSRegularExpression] = [
        #"sk-[A-Za-z0-9_\-]{16,}"#, #"gh[pousr]_[A-Za-z0-9]{20,}"#, #"github_pat_[A-Za-z0-9_]{20,}"#, #"xox[abposr]-[A-Za-z0-9\-]{10,}"#,
        #"AKIA[0-9A-Z]{16}"#, #"AIza[0-9A-Za-z_\-]{30,}"#, #"eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#,
        #"glpat-[A-Za-z0-9_\-]{16,}"#, #"npm_[A-Za-z0-9]{30,}"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }
    static let urlCredentials = try? NSRegularExpression(pattern: #"(://[^/:@\s]+):[^/@\s]+@"#)

    static func isSecretName(_ name: String) -> Bool {
        let lower = name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return secretWords.contains { lower.contains($0) } || lower == "key" || lower.hasSuffix("-key") || lower.hasSuffix("_key")
    }

    public static func redact(_ arguments: [String]) -> [String] {
        var result: [String] = []
        var maskNext = false
        for argument in arguments {
            if maskNext {
                result.append(mask)
                maskNext = false
                continue
            }
            var text = argument
            if text.hasPrefix("-"), let equals = text.firstIndex(of: "=") {
                if isSecretName(String(text[..<equals])) { text = text[...equals] + mask }
            } else if text.hasPrefix("-") {
                maskNext = isSecretName(text)
            } else if let equals = text.firstIndex(of: "="), text[..<equals].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }),
                      isSecretName(String(text[..<equals])) {
                text = text[...equals] + mask   // ENV_VAR=value
            } else if let colon = text.firstIndex(of: ":"), isSecretName(String(text[..<colon])) || text.lowercased().hasPrefix("authorization:") {
                text = text[...colon] + " " + mask   // HTTP header
            }
            if let urlCredentials {
                text = urlCredentials.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1:\(mask)@")
            }
            for pattern in tokenPatterns {
                text = pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: mask)
            }
            result.append(text)
        }
        return result
    }
}

/// Docker Desktop, OrbStack, Colima and friends: the VM is often the biggest invisible consumer.
public struct ContainerRuntime: Sendable, Equatable {
    public let name: String
    public let appPath: String?
    public let cpuPercent: Double
    public let memory: Int64
    public let startDate: Date?
}

public struct ContainerStat: Identifiable, Sendable, Equatable {
    public var id: String { name }
    public let name: String
    public let cpuPercent: Double
    public let memory: String
}

public enum Containers {
    static let apps: [(marker: String, name: String)] = [
        ("/Docker.app/", "Docker Desktop"), ("/OrbStack.app/", "OrbStack"), ("/Rancher Desktop.app/", "Rancher Desktop"),
        ("/Podman Desktop.app/", "Podman Desktop"),
    ]

    /// The container VM and its helpers, summed. The VM itself runs as Apple's Virtualization service.
    public static func runtime(in processes: [ProcessEntry]) -> ContainerRuntime? {
        var name: String?
        var appPath: String?
        var members: [ProcessEntry] = []
        for entry in processes {
            if let match = apps.first(where: { entry.path.contains($0.marker) }) {
                name = name ?? match.name
                appPath = appPath ?? entry.appPath
                members.append(entry)
            } else if ["colima", "limactl"].contains(entry.command) || entry.command.hasPrefix("qemu-system") {
                name = name ?? "Colima"
                members.append(entry)
            } else if entry.name.hasPrefix("com.apple.Virtualization.VirtualMachine") {
                members.append(entry)
            }
        }
        guard let name else { return nil }
        return ContainerRuntime(name: name, appPath: appPath, cpuPercent: members.reduce(0) { $0 + $1.cpuPercent },
                                memory: members.reduce(0) { $0 + $1.memory },
                                startDate: members.compactMap(\.startDate).min())
    }

    /// The Docker Engine socket of the running runtime. Lustro reads container stats from it directly
    /// rather than running a `docker` program: those live in folders other programs can write to, and a
    /// program started by Lustro would run with the permissions granted to Lustro.
    public static func dockerSocket(home: String = NSHomeDirectory()) -> String? {
        ["\(home)/.docker/run/docker.sock", "\(home)/.orbstack/run/docker.sock", "\(home)/.colima/default/docker.sock",
         "\(home)/.rd/docker.sock", "/var/run/docker.sock"]
            .first { path in
                var info = stat()
                return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFSOCK
            }
    }

    /// Per-container CPU and memory from the Docker Engine API over the local socket (no network).
    public static func stats(socket: String) -> [ContainerStat] {
        guard let body = UnixHTTP.get("/containers/json", socket: socket, timeout: 3),
              let list = try? JSONSerialization.jsonObject(with: body) as? [[String: Any]] else { return [] }
        let containers: [(id: String, name: String)] = list.prefix(40).compactMap { entry in
            guard let id = entry["Id"] as? String, !id.isEmpty, id.allSatisfy(\.isHexDigit) else { return nil }
            let name = (entry["Names"] as? [String])?.first.map { String($0.drop { $0 == "/" }) } ?? String(id.prefix(12))
            return (id, name)
        }
        let results = Results(count: containers.count)
        DispatchQueue.concurrentPerform(iterations: containers.count) { index in
            let container = containers[index]
            // Not one-shot: the engine samples for a second so it can report CPU use.
            if let data = UnixHTTP.get("/containers/\(container.id)/stats?stream=false", socket: socket, timeout: 4) {
                results.set(index, parseStats(data, name: container.name))
            }
        }
        return results.values.compactMap { $0 }.sorted { $0.cpuPercent > $1.cpuPercent }
    }

    /// One container's `/containers/{id}/stats` response, as `docker stats` would show it.
    public static func parseStats(_ data: Data, name: String) -> ContainerStat? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cpu = json["cpu_stats"] as? [String: Any], let pre = json["precpu_stats"] as? [String: Any] else { return nil }
        func number(_ dict: [String: Any]?, _ key: String) -> Double { (dict?[key] as? NSNumber)?.doubleValue ?? 0 }
        let usage = cpu["cpu_usage"] as? [String: Any], preUsage = pre["cpu_usage"] as? [String: Any]
        let cpuDelta = number(usage, "total_usage") - number(preUsage, "total_usage")
        let systemDelta = number(cpu, "system_cpu_usage") - number(pre, "system_cpu_usage")
        let cpus = max(number(cpu, "online_cpus"), Double((usage?["percpu_usage"] as? [Any])?.count ?? 1))
        let percent = cpuDelta > 0 && systemDelta > 0 ? cpuDelta / systemDelta * cpus * 100 : 0

        let memory = json["memory_stats"] as? [String: Any]
        let detail = memory?["stats"] as? [String: Any]
        let cache = (detail?["inactive_file"] as? NSNumber ?? detail?["total_inactive_file"] as? NSNumber ?? detail?["cache"] as? NSNumber)?.doubleValue ?? 0
        let used = max(0, number(memory, "usage") - cache)
        return ContainerStat(name: name, cpuPercent: (percent * 100).rounded() / 100, memory: formatMemory(used))
    }

    /// Binary units, like `docker stats`: 210.4MiB, 1.53GiB.
    static func formatMemory(_ bytes: Double) -> String {
        switch bytes {
        case 1_073_741_824...: String(format: "%.2fGiB", bytes / 1_073_741_824)
        case 1_048_576...: String(format: "%.1fMiB", bytes / 1_048_576)
        default: String(format: "%.0fKiB", bytes / 1024)
        }
    }

    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [ContainerStat?]
        init(count: Int) { storage = Array(repeating: nil, count: count) }
        func set(_ index: Int, _ value: ContainerStat?) { lock.withLock { storage[index] = value } }
        var values: [ContainerStat?] { lock.withLock { storage } }
    }
}

/// A minimal HTTP/1.0 GET over a Unix domain socket, enough for the Docker Engine API.
enum UnixHTTP {
    static let maxResponse = 4 << 20

    static func get(_ path: String, socket socketPath: String, timeout: Int) -> Data? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var limit = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return nil }

        let request = Array("GET \(path) HTTP/1.0\r\nHost: docker\r\n\r\n".utf8)
        guard request.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == request.count else { return nil }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while response.count <= maxResponse {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            response.append(buffer, count: count)
        }
        guard response.count <= maxResponse,
              let split = response.range(of: Data("\r\n\r\n".utf8)),
              let status = String(data: response[..<split.lowerBound], encoding: .utf8)?.split(separator: " ").dropFirst().first,
              status == "200" else { return nil }
        return response[split.upperBound...]
    }
}

