import Foundation

/// The user's custom dictionary, stored in ~/Documents/Monty Data/Dictionary.txt.
///
/// Each line is `Word` or `Word = wrong1, wrong2`. The words are given to the model as
/// a hint, and the wrong spellings are replaced afterwards, because a small model does
/// not always follow the hint.
enum Vocabulary {
    struct Entry {
        let word: String
        let wrong: [String]
    }

    static let maxWordsPerEntry = 5

    static var fileURL: URL { MontyFolder.dictionary }

    /// Creates the file from the bundled default the first time.
    static func ensureFileExists() {
        let url = fileURL
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let bundled = Bundle.main.url(forResource: "vocab-default", withExtension: "txt") {
            try? FileManager.default.copyItem(at: bundled, to: url)
        } else {
            try? "# One word per line, or: Word = wrong1, wrong2\n".write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Read on every dictation, so edits apply without restarting the app.
    static func load() -> [Entry] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            let wrong = parts.count > 1
                ? parts[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                : []
            // Entries are names and terms. A long line is pasted text, not an entry, and
            // passing it to the model makes it repeat that text instead of listening.
            guard !parts[0].isEmpty, parts[0].split(separator: " ").count <= maxWordsPerEntry else { return nil }
            return Entry(word: parts[0], wrong: wrong)
        }
    }

    /// The entries worth mentioning to the model for this transcript. Listing names that are
    /// not there invites the model to add them (Catalan speech came back with "Wispr Flow" in
    /// it), so an entry is only listed when the transcript has a word starting like one of its
    /// words. In Urdu or Hindi script the spelling cannot be compared, and names are what the
    /// dictionary is mostly for there, so everything is listed.
    static func relevant(_ entries: [Entry], to transcript: String) -> [Entry] {
        if transcript.unicodeScalars.contains(where: { (0x0600...0x06FF).contains($0.value) || (0x0900...0x097F).contains($0.value) }) {
            return entries
        }
        let words = Set(transcript.lowercased().split { !$0.isLetter }.filter { $0.count >= 3 }.map { String($0.prefix(3)) })
        return entries.filter { entry in
            ([entry.word] + entry.wrong).contains { phrase in
                phrase.lowercased().split { !$0.isLetter }.contains { $0.count >= 3 && words.contains(String($0.prefix(3))) }
            }
        }
    }

    static func hint(_ entries: [Entry]) -> String {
        guard !entries.isEmpty else { return "" }
        return " The user has these names and terms: " + entries.map(\.word).joined(separator: ", ")
            + ". If the transcript contains a word that sounds like one of them, in any script, "
            + "write it spelled exactly like that. Never add one of them that is not in the transcript."
    }

    static func applyReplacements(_ text: String, _ entries: [Entry]) -> String {
        var result = text
        for entry in entries {
            for wrong in entry.wrong.sorted(by: { $0.count > $1.count }) {  // longer phrases first
                let pattern = "(?<!\\w)" + NSRegularExpression.escapedPattern(for: wrong) + "(?!\\w)"
                guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
                result = regex.stringByReplacingMatches(
                    in: result, range: NSRange(result.startIndex..., in: result),
                    withTemplate: NSRegularExpression.escapedTemplate(for: entry.word)
                )
            }
        }
        return result
    }
}
