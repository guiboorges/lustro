import Foundation

/// Plain-language explanation for a busy process, and what quitting it does.
public struct ProcessAdvice: Sendable, Equatable {
    /// "Firefox GPU Helper is using 6.5 cores"
    public let headline: String
    /// Why it's probably busy and the gentlest fix.
    public let detail: String
    /// What the process is and what happens when it quits (for the confirmation sheet).
    public let quitEffect: String
    /// A page that shows which tab is responsible, opened in `appPath` (e.g. Firefox's about:processes).
    public let findURL: URL?
}

/// Decides which processes are "runaway" and explains them. Kept free of UI so the rules are testable.
public enum ProcessAdvisor {
    /// 150 = one and a half cores.
    public static let runawayCPU = 150.0
    /// Consecutive samples above `runawayCPU` before a process is flagged (about 15 seconds at 5 s per sample).
    public static let sustainedSamples = 3

    /// Counts consecutive samples above the threshold for each process; others drop out.
    public static func updateStreaks(_ streaks: [Int32: Int], with samples: [ProcessSample]) -> [Int32: Int] {
        var next: [Int32: Int] = [:]
        for sample in samples where sample.cpuPercent >= runawayCPU {
            next[sample.pid] = (streaks[sample.pid] ?? 0) + 1
        }
        return next
    }

    /// Busy for a sustained stretch, or busy now after averaging more than a core for over an hour
    /// (so a process that was already stuck before Lustro opened is flagged straight away).
    public static func isRunaway(_ sample: ProcessSample, streak: Int) -> Bool {
        guard !sample.isSystem, sample.cpuPercent >= runawayCPU else { return false }
        if streak >= sustainedSamples { return true }
        return sample.averageCPUPercent >= 100 && (sample.runningTime ?? 0) >= 3600
    }

    static let browsers = ["Firefox", "Google Chrome", "Safari", "Microsoft Edge", "Brave Browser", "Arc", "Opera",
                           "Vivaldi", "Chromium", "Firefox Developer Edition", "Firefox Nightly", "Zen", "Orion"]

    public static func advice(for sample: ProcessSample) -> ProcessAdvice {
        let cores = sample.cpuPercent / 100
        let coresText = cores < 9.95 ? cores.formatted(.number.precision(.fractionLength(1))) : "\(Int(cores.rounded()))"
        let headline = String(localized: "\(sample.name) is using \(coresText) cores")
        let app = sample.appName
        let appBundleName = sample.appPath.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
        let isBrowser = appBundleName.map { browsers.contains($0) } ?? false
        let isFirefox = appBundleName?.hasPrefix("Firefox") ?? false

        var parts: [String] = []
        if let running = sample.runningTime, running >= 3600 {
            let time = formatHours(running)
            parts.append(sample.averageCPUPercent >= 100 ? String(localized: "Running for \(time), busy most of that time.")
                         : String(localized: "Running for \(time)."))
        }
        let detail: String
        let quitEffect: String
        let isGPU = sample.name.localizedCaseInsensitiveContains("GPU")
        switch (app, sample.isAppMain) {
        case (let app?, false) where isBrowser:
            detail = String(localized: "Usually one stuck tab with video, WebGL or animations.") + " " + (isFirefox
                ? String(localized: "Closing it in about:processes keeps \(app) open.")
                : appBundleName == "Safari" ? String(localized: "Closing the busy tab usually fixes it.")
                : String(localized: "Window ▸ Task Manager in \(app) shows which tab it is."))
            quitEffect = isGPU
                ? String(localized: "It's the part of \(app) that draws pages on screen. \(app) starts a fresh one straight away: your tabs stay open, and the window may flicker for a moment.")
                : String(localized: "It's a helper that runs tabs or extensions for \(app). The tabs it was running show an error until you reload them; \(app) itself stays open.")
        case (let app?, false):
            detail = String(localized: "Part of \(app). An extension or open project is usually behind it, and reloading the window often fixes it.")
            quitEffect = isGPU
                ? String(localized: "It's the part of \(app) that draws on screen. \(app) starts a fresh one straight away: your windows stay open, and may flicker for a moment.")
                : String(localized: "It's a helper process of \(app). \(app) usually starts a new one when it needs it; whatever it was running may need reloading.")
        case (let app?, true):
            detail = String(localized: "If \(app) isn't doing heavy work right now, quitting and reopening it usually fixes it.")
            quitEffect = String(localized: "This quits \(app) itself. It gets the chance to ask about unsaved work first.")
        case (nil, _):
            detail = String(localized: "A command-line process. If you didn't start something heavy, it may be stuck.")
            quitEffect = String(localized: "Quitting stops it. If it was started from Terminal, that command ends.")
        }
        parts.append(detail)
        return ProcessAdvice(headline: headline, detail: parts.joined(separator: " "), quitEffect: quitEffect,
                             findURL: isFirefox && !sample.isAppMain ? URL(string: "about:processes") : nil)
    }

    /// "39 hours", "2 days", "45 minutes".
    public static func formatHours(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds / 3600)
        if hours >= 72 { return String(localized: "\(hours / 24) days") }
        if hours == 1 { return String(localized: "1 hour") }
        if hours > 1 { return String(localized: "\(hours) hours") }
        let minutes = max(Int(seconds / 60), 1)
        return minutes == 1 ? String(localized: "1 minute") : String(localized: "\(minutes) minutes")
    }
}
