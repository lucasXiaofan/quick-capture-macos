import Foundation

/// Import the existing workspace project pages once, without mistaking Markdown checklists for live tickets.
/// A stage heading is `## 1. Title — Nov 10–12` or `## 2. Title — Nov 20–Dec 1`.
enum TicketWorkspaceImport {
    struct Stage {
        var title: String
        var start: String
        var due: String
        var text: String
    }

    static func sourceTickets(_ text: String) -> [Int] {
        let re = try! NSRegularExpression(pattern: #"tickets/(\d+)\.md"#)
        let ns = text as NSString
        return Array(Set(re.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .compactMap { Int(ns.substring(with: $0.range(at: 1))) })).sorted()
    }

    static func stages(_ text: String) -> [Stage] {
        guard let yearRange = text.range(of: #"\b\d{4}-\d{2}-\d{2}\b"#, options: .regularExpression) else { return [] }
        let year = String(text[yearRange].prefix(4))
        let re = try! NSRegularExpression(pattern: #"(?m)^## \d+\. (.+?) — ([A-Za-z]+) (\d{1,2})[–-](?:([A-Za-z]+) )?(\d{1,2})\s*$"#)
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        func day(_ month: String, _ number: String) -> String? {
            let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
            guard let m = months.firstIndex(of: String(month.lowercased().prefix(3))), let d = Int(number) else { return nil }
            let result = String(format: "%@-%02d-%02d", year, m + 1, d)
            return TicketDates.isDay(result) ? result : nil
        }
        return matches.enumerated().compactMap { index, match in
            let month = ns.substring(with: match.range(at: 2))
            let endMonth = match.range(at: 4).location == NSNotFound ? month : ns.substring(with: match.range(at: 4))
            guard let start = day(month, ns.substring(with: match.range(at: 3))),
                  let due = day(endMonth, ns.substring(with: match.range(at: 5))), due >= start else { return nil }
            let from = NSMaxRange(match.range)
            var end = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
            // Do not attach project-wide blockers to the final stage.
            let tail = ns.substring(with: NSRange(location: from, length: end - from))
            if let stop = tail.range(of: "\n## ") { end = from + (tail[..<stop.lowerBound] as NSString).length }
            return Stage(title: ns.substring(with: match.range(at: 1)), start: start, due: due,
                         text: ns.substring(with: NSRange(location: from, length: end - from)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
