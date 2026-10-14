import Foundation

/// Labels iPhone/iPad backups with their device and date, and optionally hides
/// the newest backup of each device so a current backup is never offered for removal.
enum DeviceBackups {
    struct Info {
        let device: String
        let deviceID: String
        let date: Date?
    }

    static func info(for backup: URL) -> Info? {
        let plist = backup.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        let id = (dict["Target Identifier"] as? String) ?? (dict["Unique Identifier"] as? String) ?? backup.lastPathComponent
        return Info(device: (dict["Device Name"] as? String) ?? "Unknown device", deviceID: id, date: dict["Last Backup Date"] as? Date)
    }

    static func label(_ items: [ScanItem], keepNewest: Bool) -> [ScanItem] {
        let infos = Dictionary(uniqueKeysWithValues: items.map { ($0.id, info(for: $0.url)) })
        var newest: [String: (id: String, date: Date)] = [:]
        for item in items {
            guard let info = infos[item.id] ?? nil, let date = info.date else { continue }
            if date > (newest[info.deviceID]?.date ?? .distantPast) { newest[info.deviceID] = (item.id, date) }
        }
        let keep = Set(newest.values.map(\.id))
        return items.compactMap { item in
            if keepNewest && keep.contains(item.id) { return nil }
            guard let info = infos[item.id] ?? nil else { return item }
            let when = info.date.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "unknown date"
            return item.with(note: "\(info.device) · \(when)",
                             evidence: keepNewest ? "An older backup of \(info.device); the newest one is kept" : nil)
        }
    }
}
