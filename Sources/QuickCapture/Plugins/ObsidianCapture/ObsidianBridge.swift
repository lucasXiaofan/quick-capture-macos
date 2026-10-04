import AppKit

/// Talks to the running Obsidian app through its official CLI (`obsidian eval`),
/// running Resources/obsidian_capture/bridge.js inside the vault's window.
struct ObsidianBridge {
    let config: ObsidianSettings

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "md.obsidian").isEmpty
    }

    static let script: String? = Paths.resource("bridge.js", plugin: ObsidianCapturePlugin.pluginID)
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    /// The configured CLI, or the one inside Obsidian.app wherever it is installed.
    static func executable(configured: String) -> String? {
        let fm = FileManager.default
        if fm.isExecutableFile(atPath: configured) { return configured }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "md.obsidian") else { return nil }
        let path = app.appendingPathComponent("Contents/MacOS/obsidian").path
        return fm.isExecutableFile(atPath: path) ? path : nil
    }

    /// Obsidian's CLI occasionally exits without printing the result even though the code ran
    /// (seen when a capture was saved but reported as failed). Every bridge action is safe to
    /// repeat — a repeated `save` with the same id doesn't write again — so lost replies are retried.
    static let attempts = 3

    func call(_ action: String, _ params: [String: Any] = [:]) async throws -> Any? {
        guard let vault = config.vaultURL else { throw AppError("Choose your Obsidian vault first.") }
        guard let body = ObsidianBridge.script else { throw AppError("bridge.js is missing from the app bundle.") }
        guard let obsidian = ObsidianBridge.executable(configured: config.obsidian) else {
            throw AppError("Obsidian was not found at \(config.obsidian).")
        }
        var p = params
        p["action"] = action
        p["vault"] = vault.path
        let json = String(data: try JSONSerialization.data(withJSONObject: p), encoding: .utf8)!
        let code = "(() => {const p=" + json + "; const value=(() => {" + body
            + "})(); return \"QC:\"+btoa(unescape(encodeURIComponent(JSON.stringify(value))));})()"
        for attempt in 1...Self.attempts {
            if attempt > 1 { try await Task.sleep(nanoseconds: UInt64(attempt - 1) * 300_000_000) }
            let result = try await Shell.run(obsidian, ["vault=" + vault.lastPathComponent, "eval", "code=" + code],
                                             timeout: 12)
            let out = result.stdout + result.stderr
            if let range = out.range(of: #"QC:[A-Za-z0-9+/=]+"#, options: .regularExpression),
               let data = Data(base64Encoded: String(out[range].dropFirst(3))) {
                if attempt > 1 { BridgeLog.write("\(action): reply received on attempt \(attempt)") }
                return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            }
            if out.contains("Vault not found") {
                throw AppError("Obsidian doesn't have the vault “\(vault.lastPathComponent)” open.")
            }
            if let err = out.split(separator: "\n").last(where: { $0.contains("Error") }) {
                throw AppError("Obsidian CLI error: \(err)")
            }
            BridgeLog.write("\(action): no reply on attempt \(attempt) (exit \(result.status)); output: "
                            + String(out.suffix(400)).replacingOccurrences(of: "\n", with: " ⏎ "))
        }
        throw AppError("Obsidian CLI isn't responding. In Obsidian, enable Settings → General → "
                       + "Command line interface, and keep the vault open.")
    }
}

/// Records lost CLI replies (never capture text) so intermittent problems leave evidence:
/// ~/Library/Application Support/Quick Capture/obsidian_capture/bridge.log
enum BridgeLog {
    static var url: URL { Paths.data(for: ObsidianCapturePlugin.pluginID).appendingPathComponent("bridge.log") }

    static func write(_ line: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(stamp) \(line)\n".utf8)
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 256_000 {
            try? fm.removeItem(at: url)  // Keep it small; only recent events matter.
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}

/// Moment.js-style date formats (used by Obsidian's Daily Notes and templates).
enum MomentFormat {
    private static let tokens: [(String, String)] = [
        ("YYYY", "yyyy"), ("YY", "yy"), ("MMMM", "MMMM"), ("MMM", "MMM"), ("MM", "MM"), ("M", "M"),
        ("DD", "dd"), ("D", "d"), ("dddd", "EEEE"), ("ddd", "EEE"), ("HH", "HH"), ("H", "H"),
        ("hh", "hh"), ("h", "h"), ("mm", "mm"), ("m", "m"), ("ss", "ss"), ("s", "s"), ("A", "a"), ("a", "a"),
        ("ww", "ww"), ("w", "w"), ("Do", "d"),
    ].sorted { $0.0.count > $1.0.count }

    static func format(_ date: Date, _ moment: String) -> String {
        var pattern = "", literal = ""
        var rest = Substring(moment)
        func flush() {
            if !literal.isEmpty { pattern += "'" + literal.replacingOccurrences(of: "'", with: "''") + "'"; literal = "" }
        }
        while !rest.isEmpty {
            if rest.first == "[", let close = rest.firstIndex(of: "]") {
                literal += rest[rest.index(after: rest.startIndex)..<close]
                rest = rest[rest.index(after: close)...]
            } else if let (m, f) = tokens.first(where: { rest.hasPrefix($0.0) }) {
                flush(); pattern += f; rest = rest.dropFirst(m.count)
            } else {
                literal.append(rest.removeFirst())
            }
        }
        flush()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

/// Where things go inside the vault.
struct VaultLayout {
    let config: ObsidianSettings
    let vault: URL
    let now: Date

    var diaryPath: String {
        let name = MomentFormat.format(now, config.diaryFormat.isEmpty ? "YYYY-MM-DD" : config.diaryFormat) + ".md"
        return VaultLayout.clean(config.diaryFolder.isEmpty ? name : config.diaryFolder + "/" + name)
    }

    var diaryTitle: String { ((diaryPath as NSString).lastPathComponent as NSString).deletingPathExtension }

    /// Normalizes a vault-relative path and rejects anything escaping the vault.
    static func clean(_ path: String) -> String {
        var parts: [String] = []
        for part in path.split(separator: "/") where part != "." && !part.isEmpty {
            if part == ".." { _ = parts.popLast() } else { parts.append(String(part)) }
        }
        return parts.joined(separator: "/")
    }

    func renderedTemplate() throws -> String {
        guard !config.template.isEmpty else { return "# \(diaryTitle)\n" }
        let url = vault.appendingPathComponent(VaultLayout.clean(config.template))
        guard var text = try? String(contentsOf: url, encoding: .utf8) else {
            throw AppError("Diary template not found: \(config.template). Fix it in Settings → Obsidian Capture.")
        }
        let regex = try NSRegularExpression(pattern: #"\{\{\s*(date|time|title)\s*(?::([^}]*))?\}\}"#)
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            let kind = String(text[Range(match.range(at: 1), in: text)!])
            let fmt = Range(match.range(at: 2), in: text).map { String(text[$0]).trimmingCharacters(in: .whitespaces) }
            let value: String
            switch kind {
            case "title": value = diaryTitle
            case "time": value = MomentFormat.format(now, fmt ?? "HH:mm")
            default: value = MomentFormat.format(now, fmt ?? config.diaryFormat)
            }
            text.replaceSubrange(Range(match.range, in: text)!, with: value)
        }
        return text
    }

    /// Folder for a new attachment, honoring Obsidian's "Default location for new attachments".
    func attachmentFolder(forNote notePath: String) -> String {
        var setting = "/"
        if let data = try? Data(contentsOf: vault.appendingPathComponent(".obsidian/app.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let value = json["attachmentFolderPath"] as? String { setting = value }
        let noteFolder = (notePath as NSString).deletingLastPathComponent
        if setting == "./" || setting == "." { return noteFolder }
        if setting.hasPrefix("./") { return VaultLayout.clean(noteFolder + "/" + setting.dropFirst(2)) }
        return VaultLayout.clean(setting)
    }

    /// Moves a screenshot into the vault and returns its embed.
    func storeScreenshot(_ file: URL, forNote notePath: String) throws -> String {
        let folder = attachmentFolder(forNote: notePath)
        let dir = folder.isEmpty ? vault : vault.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = MomentFormat.format(now, "YYYYMMDD-HHmmss")
        var name = "capture-\(stamp).png"
        var n = 2
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) {
            name = "capture-\(stamp)-\(n).png"; n += 1
        }
        try FileManager.default.moveItem(at: file, to: dir.appendingPathComponent(name))
        return "![[\(name)]]"
    }

    /// Used only when Obsidian is closed or its CLI is unavailable: append to the diary file on disk.
    func appendToDiaryOnDisk(_ text: String) throws {
        let url = vault.appendingPathComponent(diaryPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let base = existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? try renderedTemplate() : existing
        try (base + text).write(to: url, atomically: true, encoding: .utf8)
    }
}
