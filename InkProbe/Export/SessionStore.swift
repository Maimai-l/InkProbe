import Foundation

/// 会话列表中的一项。
struct SessionSummary {
    let url: URL
    let folderName: String
    let name: String
    let createdAt: String
    let sequences: Int?
    let strokes: Int?
    /// meta.json 最后写入，缺少 meta.json 说明保存未完成。
    let isComplete: Bool

    var detailText: String {
        guard isComplete else {
            return "\(folderName) · 未完成（缺少 meta.json）"
        }
        let sequenceText = sequences.map(String.init) ?? "?"
        let strokeText = strokes.map(String.init) ?? "?"
        return "\(createdAt) · 序列 \(sequenceText) · 笔划 \(strokeText) · \(folderName)"
    }
}

/// Documents/sessions 目录的管理。
enum SessionStore {
    static var documentsDirectory: URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var sessionsDirectory: URL {
        return documentsDirectory.appendingPathComponent("sessions", isDirectory: true)
    }

    /// 用户输入的会话名称，留空时为 `untitled`。
    static func displayName(from raw: String?) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "untitled" : trimmed
    }

    static func sanitizedFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
            .union(.newlines)
            .union(.controlCharacters)
        var cleaned = name.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        if cleaned.hasPrefix(".") {
            cleaned = "_" + cleaned.dropFirst()
        }
        return cleaned.isEmpty ? "untitled" : cleaned
    }

    /// 创建 `<yyyyMMdd-HHmmss>_<name>` 文件夹；重名时追加 `-2`、`-3`……
    static func makeSessionFolder(createdAt: Date, name: String) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        let base = "\(DateFormats.folderTimestamp.string(from: createdAt))_\(sanitizedFileName(name))"
        var candidate = sessionsDirectory.appendingPathComponent(base, isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = sessionsDirectory.appendingPathComponent("\(base)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        try fileManager.createDirectory(at: candidate, withIntermediateDirectories: true)
        return candidate
    }

    static func listSessions() -> [SessionSummary] {
        let fileManager = FileManager.default
        guard let items = try? fileManager.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var result: [SessionSummary] = []
        for url in items {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { continue }

            var name = url.lastPathComponent
            var createdAt = ""
            var sequences: Int?
            var strokes: Int?
            var isComplete = false
            let metaURL = url.appendingPathComponent("meta.json", isDirectory: false)
            if let data = try? Data(contentsOf: metaURL),
               let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                isComplete = true
                name = object["sessionName"] as? String ?? name
                createdAt = object["createdAt"] as? String ?? ""
                if let counts = object["counts"] as? [String: Any] {
                    sequences = (counts["sequences"] as? NSNumber)?.intValue
                    strokes = (counts["finalStrokes"] as? NSNumber)?.intValue
                }
            }
            result.append(SessionSummary(
                url: url,
                folderName: url.lastPathComponent,
                name: name,
                createdAt: createdAt,
                sequences: sequences,
                strokes: strokes,
                isComplete: isComplete
            ))
        }
        // 文件夹名以时间戳开头，倒序即最新的在前。
        return result.sorted { $0.folderName > $1.folderName }
    }

    static func deleteSession(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

enum DateFormats {
    /// `2026-09-23T10:15:00+08:00`
    static let iso8601Seconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    /// `20260923-101500`
    static let folderTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

enum DeviceInfo {
    /// `utsname.machine`，例如 `iPad13,4`。
    static var machine: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw -> String in
            let bytes = raw.prefix(while: { $0 != 0 })
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}
