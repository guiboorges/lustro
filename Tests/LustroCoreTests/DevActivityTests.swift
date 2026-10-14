import Foundation
import Testing
@testable import LustroCore

@Suite struct DevActivityTests {
    let home = "/Users/me"

    func entry(_ pid: Int32, parent: Int32, tty: String? = nil, path: String, args: [String] = [], cwd: String? = nil,
               cpu: Double = 0, memory: Int64 = 10_000_000, system: Bool = false, startedAgo: TimeInterval = 600) -> ProcessEntry {
        ProcessEntry(pid: pid, ppid: parent, tty: tty, name: (path as NSString).lastPathComponent, path: path, arguments: args,
                     cwd: cwd, startDate: Date().addingTimeInterval(-startedAgo), cpuPercent: cpu, memory: memory, isSystem: system)
    }

    /// Snapshot shaped like the Mac this was built on: three Claude Code sessions, an MCP server, a dev server
    /// in a terminal, and a `vite preview` left behind after its session ended.
    var table: [ProcessEntry] {
        [
            entry(100, parent: 99, tty: "ttys003", path: "/bin/zsh", args: ["-zsh"], system: true),
            entry(101, parent: 100, tty: "ttys003", path: "\(home)/.local/share/claude/versions/2.1.296", args: ["claude"],
                  cwd: "\(home)/Projects/REA", cpu: 8),
            entry(102, parent: 101, path: "/opt/homebrew/bin/npm", args: ["npm", "exec", "rea-agents@6.4.0", "mcp"]),
            entry(103, parent: 102, path: "/opt/homebrew/bin/node", args: ["node", "\(home)/.npm/_npx/x/node_modules/.bin/rea", "mcp"]),
            entry(104, parent: 101, path: "/bin/bash", args: ["/bin/bash", "-c", "swift test"], cpu: 34),
            // A sub-agent started by the session belongs to it, not to a new group.
            entry(105, parent: 101, path: "\(home)/.local/share/claude/versions/2.1.296", args: ["claude", "-p"]),

            entry(200, parent: 199, tty: "ttys005", path: "/bin/zsh", args: ["-zsh"], system: true),
            entry(201, parent: 200, tty: "ttys005", path: "/opt/homebrew/bin/node", args: ["npm", "run", "dev"], cwd: "\(home)/Projects/site", cpu: 1),
            entry(202, parent: 201, tty: "ttys005", path: "/opt/homebrew/bin/node",
                  args: ["node", "\(home)/Projects/site/node_modules/.bin/vite", "--port", "5173"], cpu: 12),

            entry(300, parent: 1, path: "/opt/homebrew/bin/node", args: ["npm", "exec", "vite", "preview", "--port", "4173"],
                  cwd: "/private/tmp/scratch/site", startedAgo: 13 * 3600),
            entry(301, parent: 300, path: "/opt/homebrew/bin/node", args: ["node", "/private/tmp/scratch/site/node_modules/.bin/vite", "preview"]),

            // Not orphans: an app, a launch agent's program, a system daemon, a non-runtime tool.
            entry(400, parent: 1, path: "/Applications/Code.app/Contents/MacOS/Code"),
            entry(401, parent: 1, path: "\(home)/Library/Application Support/Updater/updater-agent"),
            entry(402, parent: 1, path: "/usr/libexec/trustd", system: true),
            entry(403, parent: 1, path: "/opt/homebrew/bin/ssh-agent"),
            entry(404, parent: 1, path: "/opt/homebrew/bin/node", args: ["node", "/opt/homebrew/lib/node_modules/brew-service/index.js"]),
            entry(405, parent: 400, path: "/Applications/Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper"),
            entry(406, parent: 200, tty: "ttys005", path: "\(home)/.cache/gitstatus/gitstatusd-darwin-arm64", args: ["gitstatusd-darwin-arm64", "-G"]),

            // The Claude desktop app is not an agent session itself; the preview server it started is listed under it.
            entry(500, parent: 1, path: "/Applications/Claude.app/Contents/MacOS/Claude"),
            entry(501, parent: 500, path: "/Applications/Claude.app/Contents/Helpers/disclaimer"),
            entry(502, parent: 501, path: "\(home)/.local/bin/node", args: ["node", "-e", "const h=require('http'); h.createServer().listen(4791)"]),
            entry(503, parent: 500, path: "\(home)/.local/bin/node", args: ["node", "idle-helper.js"]),
            // npm rewrites its title, so its whole command line arrives as one argument (normalised by ProcessTable).
            entry(600, parent: 1, path: "/opt/homebrew/bin/node", args: ProcessTable.normalized(["npm exec serve dist   ", "", " "]), startedAgo: 7200),
            entry(601, parent: 600, path: "/opt/homebrew/bin/node", args: ["node", "/x/node_modules/.bin/serve", "dist"]),
        ]
    }

    var ports: [ListeningPort] {
        [ListeningPort(pid: 301, port: 4173, exposed: true), ListeningPort(pid: 202, port: 5173, exposed: false),
         ListeningPort(pid: 103, port: 4790, exposed: false), ListeningPort(pid: 405, port: 50762, exposed: false),
         ListeningPort(pid: 502, port: 4791, exposed: false), ListeningPort(pid: 601, port: 3000, exposed: false)]
    }

    var report: DevActivityReport {
        DevActivity.analyze(processes: table, ports: ports, launchPrograms: ["\(home)/Library/Application Support/Updater/updater-agent"])
    }

    @Test func groupsAgentSessionsWithEverythingTheyStarted() throws {
        let agent = try #require(report.sessions.first)
        #expect(agent.kind == .agent("Claude Code"))
        #expect(Set(agent.members.map(\.pid)) == [101, 102, 103, 104, 105])
        #expect(agent.cpuPercent == 42)
        #expect(agent.folder == "\(home)/Projects/REA")
        #expect(agent.root.tty == "ttys003")
        #expect(agent.ports.map(\.port) == [4790])
        #expect(agent.isWorking)
        #expect(agent.startedBy == nil)
        #expect(agent.notableChildren.first?.pid == 104)   // busiest child first; bash isn't hidden as a shell when it runs a command
    }

    @Test func terminalCommands() throws {
        let terminal = try #require(report.sessions.first { $0.kind == .terminal })
        #expect(terminal.title == "npm run dev")
        #expect(Set(terminal.members.map(\.pid)) == [201, 202])
        #expect(report.sessions.filter { $0.kind == .terminal }.count == 1)   // the shell and its prompt helper aren't groups
    }

    @Test func orphansAreDeveloperProcessesWhoseParentIsGone() throws {
        #expect(report.orphans.count == 3)
        let vite = try #require(report.orphans.first)
        #expect(vite.title == "vite preview --port 4173")
        #expect(vite.ports.first?.exposed == true)
        #expect(Set(vite.members.map(\.pid)) == [300, 301])
        // The node process without a launch agent entry is reported too; apps, system daemons and ssh-agent aren't.
        #expect(report.orphans.map(\.root.pid).sorted() == [300, 404, 600])
        #expect(report.orphans.first { $0.root.pid == 600 }?.title == "serve dist")
    }

    @Test func serversStartedByApps() throws {
        #expect(!report.sessions.contains { $0.root.pid == 500 })
        let preview = try #require(report.sessions.first { $0.root.pid == 502 })
        #expect(preview.kind == .launchedBy("Claude"))
        #expect(preview.startedBy == "Claude")
        #expect(preview.title.hasPrefix("node -e \"const h=require('http');"))
        #expect(preview.title.hasSuffix("…\""))
        #expect(!report.sessions.contains { $0.root.pid == 503 })   // idle, no port: not worth a row
    }

    @Test func launchAgentProgramsAreNotOrphans() {
        let withAgent = DevActivity.analyze(processes: table, ports: ports, launchPrograms: ["/opt/homebrew/bin/node"])
        #expect(withAgent.orphans.isEmpty)
    }

    @Test func portsNetworkFirstAndAppNoiseHidden() {
        #expect(report.ports.map(\.port.port) == [4173, 3000, 4790, 4791, 5173])
        #expect(report.ports.first?.group?.kind == .orphan)
    }

    @Test func displayCommands() {
        let vite = entry(1, parent: 0, path: "/opt/homebrew/bin/node", args: ["node", "/x/node_modules/.bin/vite", "preview", "--port", "4173"])
        #expect(DevActivity.displayCommand(vite, home: home) == "vite preview --port 4173")
        let npx = entry(1, parent: 0, path: "/opt/homebrew/bin/npm", args: ["npm", "exec", "rea-agents@6.4.0", "mcp"])
        #expect(DevActivity.displayCommand(npx, home: home) == "rea-agents@6.4.0 mcp")
        let python = entry(1, parent: 0, path: "/usr/bin/python3", args: ["/usr/bin/python3", "-m", "http.server", "8000"])
        #expect(DevActivity.displayCommand(python, home: home) == "python3 -m http.server 8000")
        let script = entry(1, parent: 0, path: "/bin/bash", args: ["/bin/bash", "\(home)/bin/deploy.sh", "--token", "abc123"])
        #expect(DevActivity.displayCommand(script, home: home) == "bash ~/bin/deploy.sh --token •••")
    }

    @Test func agentDetection() {
        #expect(DevActivity.agentName(entry(1, parent: 0, path: "/opt/homebrew/bin/codex", args: ["codex"])) == "Codex")
        #expect(DevActivity.agentName(entry(1, parent: 0, path: "/opt/homebrew/bin/node",
                                            args: ["node", "/opt/homebrew/lib/node_modules/@google/gemini-cli/dist/index.js"])) == "Gemini CLI")
        #expect(DevActivity.agentName(entry(1, parent: 0, path: "\(home)/Library/Application Support/Claude/claude-code/2.1.295/x/claude.app/Contents/MacOS/claude")) == "Claude Code")
        #expect(DevActivity.agentName(entry(1, parent: 0, path: "/opt/homebrew/bin/node", args: ["node", "server.js"])) == nil)
    }
}

@Suite struct CommandRedactorTests {
    func redact(_ text: String) -> String { CommandRedactor.redact(text.components(separatedBy: " ")).joined(separator: " ") }

    @Test func flagsAndAssignments() {
        #expect(redact("deploy --token abc --port 8080") == "deploy --token ••• --port 8080")
        #expect(redact("cli --api-key=XYZ --verbose") == "cli --api-key=••• --verbose")
        #expect(redact("env GITHUB_TOKEN=ghx OTHER=1 node app.js") == "env GITHUB_TOKEN=••• OTHER=1 node app.js")
        #expect(redact("psql --password hunter2") == "psql --password •••")
        #expect(redact("ssh -i key.pem host") == "ssh -i key.pem host")
        #expect(redact("--keep-alive yes") == "--keep-alive yes")
    }

    @Test func tokensAndURLs() {
        #expect(redact("curl https://bob:s3cret@example.com/x") == "curl https://bob:•••@example.com/x")
        #expect(redact("run sk-ant-api03-abcdefghijklmnopqrstu") == "run •••")
        #expect(redact("git push https://ghp_abcdefghijklmnopqrstuvwxyz123456@github.com") == "git push https://•••@github.com")
        #expect(CommandRedactor.redact(["curl", "-H", "Authorization: Bearer abc"]) == ["curl", "-H", "Authorization: •••"])
    }
}

@Suite struct ContainerTests {
    @Test func parsesDockerEngineStats() throws {
        let json = """
        {"cpu_stats":{"cpu_usage":{"total_usage":3000000000},"system_cpu_usage":20000000000,"online_cpus":4},
         "precpu_stats":{"cpu_usage":{"total_usage":2000000000},"system_cpu_usage":10000000000},
         "memory_stats":{"usage":230686720,"stats":{"inactive_file":10485760}}}
        """
        let stat = try #require(Containers.parseStats(Data(json.utf8), name: "api"))
        #expect(stat.name == "api")
        #expect(stat.cpuPercent == 40)
        #expect(stat.memory == "210.0MiB")
        #expect(Containers.parseStats(Data("not json".utf8), name: "x") == nil)
    }

    @Test func detectsRuntimeAndVM() {
        let processes = [
            ProcessEntry(pid: 1, ppid: 1, tty: nil, name: "com.docker.backend", path: "/Applications/Docker.app/Contents/MacOS/com.docker.backend",
                         arguments: [], cwd: nil, startDate: nil, cpuPercent: 2, memory: 100, isSystem: false),
            ProcessEntry(pid: 2, ppid: 1, tty: nil, name: "com.apple.Virtualization.VirtualMachine",
                         path: "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine",
                         arguments: [], cwd: nil, startDate: nil, cpuPercent: 16, memory: 2000, isSystem: true),
        ]
        let runtime = Containers.runtime(in: processes)
        #expect(runtime?.name == "Docker Desktop")
        #expect(runtime?.cpuPercent == 18)
        #expect(runtime?.appPath == "/Applications/Docker.app")
        #expect(Containers.runtime(in: [processes[1]]) == nil)
    }
}

@Suite struct ProcessTableTests {
    @Test func parsesProcArgs() {
        var buffer: [UInt8] = []
        withUnsafeBytes(of: Int32(3)) { buffer += $0 }
        buffer += Array("/bin/echo".utf8) + [0, 0, 0]
        buffer += Array("echo".utf8) + [0] + Array("hello world".utf8) + [0] + Array("x".utf8) + [0]
        buffer += Array("PATH=/bin".utf8) + [0]   // environment follows argv and is ignored
        #expect(ProcessTable.parseProcArgs(buffer) == ["echo", "hello world", "x"])
    }

    @Test func liveTableHasFamilyAndArguments() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["20"]
        try child.run()
        defer { child.terminate() }
        let table = ProcessTable()
        let started = Date()
        let (processes, _) = table.sample()
        let elapsed = Date().timeIntervalSince(started)
        let sleeper = try #require(processes.first { $0.pid == child.processIdentifier })
        #expect(sleeper.ppid == getpid())
        #expect(!sleeper.isSystem)   // a tool you run is yours, not part of macOS
        #expect(sleeper.arguments == ["/bin/sleep", "20"])
        #expect(ProcessTable.isRunning(sleeper))
        #expect(ProcessTable.signal(SIGTERM, [sleeper]) == 1)
        child.waitUntilExit()
        #expect(!ProcessTable.isRunning(sleeper))
        #expect(elapsed < 2)
        #expect(!processes.contains { $0.pid == getpid() })
    }
}
