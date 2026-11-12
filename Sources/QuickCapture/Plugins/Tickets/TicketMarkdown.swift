import Foundation

/// A ticket as a Markdown file that reads well in any editor (Obsidian included) and loads back exactly:
///
///     ---
///     id: 12
///     title: "Why does attention need separate K and V?"
///     status: waiting_human
///     kind: question
///     tags: ["transformers"]
///     …
///     ---
///     # Why does attention need separate K and V?
///
///     ### Me · 2026-11-10 14:01
///     <!-- msg {"role":"human","at":"2026-11-10T14:01:00-05:00"} -->
///     the message, as written
///
/// Everything but the conversation lives in the front matter (each value is JSON, which is also valid YAML).
/// The `<!-- msg … -->` line starts a message; the heading above it is only for reading.
enum TicketMarkdown {
    private static let order = ["id", "title", "summary", "status", "kind", "project", "related_projects", "tags", "created", "updated",
                                "start", "due", "due_time", "takeaways", "log", "merged_from", "merged_into", "history"]
    private static let marker = "<!-- msg "

    static func encode(_ ticket: Ticket, attachmentsPath: String) -> String {
        let data = (try? JSONEncoder().encode(ticket)) ?? Data()
        let fields = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
        var out = "---\n"
        for key in order {
            guard let value = fields[key], !(value is NSNull) else { continue }
            if let array = value as? [Any], array.isEmpty, key != "tags" { continue }
            out += "\(key): \(scalar(value))\n"
        }
        out += "---\n# \(ticket.title)\n"
        if !ticket.summary.isEmpty { out += "\n> \(ticket.summary.replacingOccurrences(of: "\n", with: " "))\n" }
        if !ticket.takeaways.isEmpty {
            out += "\n**Takeaways**\n" + ticket.takeaways.map { "- \($0.replacingOccurrences(of: "\n", with: " "))\n" }.joined()
        }
        for message in ticket.messages {
            out += "\n" + heading(message) + "\n" + marker + meta(message) + " -->\n" + message.text + "\n"
            out += attachmentLines(message, path: attachmentsPath)
        }
        return out
    }

    static func decode(_ text: String) -> Ticket? {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n"), let close = normalized.range(of: "\n---\n") else { return nil }
        var fields: [String: Any] = [:]
        for line in normalized[normalized.index(normalized.startIndex, offsetBy: 4)..<close.lowerBound].split(separator: "\n") {
            guard let colon = line.range(of: ":") else { continue }
            let key = line[..<colon.lowerBound].trimmingCharacters(in: .whitespaces)
            let raw = line[colon.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else { continue }
            fields[key] = (try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: .fragmentsAllowed)) ?? raw
        }
        // Dates and ids written plain parse as themselves; anything edited by hand into another type is dropped below.
        for key in ["title", "summary", "status", "kind", "project", "created", "updated", "start", "due", "due_time"] {
            if let value = fields[key], !(value is String) { fields[key] = "\(value)" }
        }

        var messages: [[String: Any]] = []
        let body = String(normalized[close.upperBound...])
        let chunks = body.components(separatedBy: "\n" + marker)
        for (index, chunk) in chunks.enumerated().dropFirst() {
            guard let end = chunk.range(of: " -->\n") ?? chunk.range(of: " -->") else { continue }
            guard var message = (try? JSONSerialization.jsonObject(with: Data(chunk[..<end.lowerBound].utf8))) as? [String: Any] else { continue }
            var content = String(chunk[end.upperBound...])
            // The next message's heading is the last line of this chunk.
            if index < chunks.count - 1, let cut = content.range(of: "\n### ", options: .backwards) {
                content = String(content[..<cut.lowerBound])
            }
            let attachments = message["attachments"] as? [String] ?? []
            if !attachments.isEmpty, let cut = content.range(of: "\n\n" + attachmentPrefix(attachments[0]), options: .backwards) {
                content = String(content[..<cut.lowerBound])
            }
            message["text"] = content.trimmingCharacters(in: .newlines)
            messages.append(message)
        }
        fields["messages"] = messages
        guard JSONSerialization.isValidJSONObject(fields), let data = try? JSONSerialization.data(withJSONObject: fields) else { return nil }
        return try? JSONDecoder().decode(Ticket.self, from: data)
    }

    private static func heading(_ message: TicketMessage) -> String {
        let who: String
        switch message.role {
        case "human": who = "Me"
        case "agent": who = "Agent" + (message.agent.map { " (\($0))" } ?? "")
        default: who = "Note"
        }
        let time = message.at.prefix(16).replacingOccurrences(of: "T", with: " ")
        return "### \(who) · \(time)" + (message.from.map { " · from #\($0)" } ?? "")
    }

    private static func meta(_ message: TicketMessage) -> String {
        var m = message
        m.text = ""
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(m), var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return "{}" }
        object["text"] = nil
        if (object["attachments"] as? [Any])?.isEmpty == true { object["attachments"] = nil }
        let json = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        // Keep the comment intact whatever a tool log contains.
        return json.replacingOccurrences(of: ">", with: "\\u003e")
    }

    private static func attachmentPrefix(_ name: String) -> String {
        isImage(name) ? "![" : "["
    }

    private static func attachmentLines(_ message: TicketMessage, path: String) -> String {
        guard !message.attachments.isEmpty else { return "" }
        return "\n" + message.attachments.map { name in
            let target = "\(path)/\(name)".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
            return isImage(name) ? "![\(name)](\(target))\n" : "[\(name)](\(target))\n"
        }.joined()
    }

    static func isImage(_ name: String) -> Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"].contains((name as NSString).pathExtension.lowercased())
    }

    /// JSON for one front-matter value; simple words and dates are written without quotes.
    private static func scalar(_ value: Any) -> String {
        if let s = value as? String {
            let plain = s.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_:+.\-]*$"#, options: .regularExpression) != nil
            let parsesAsJSON = (try? JSONSerialization.jsonObject(with: Data(s.utf8), options: .fragmentsAllowed)) != nil
            if plain && !parsesAsJSON { return s }
        }
        let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }
}
