import Foundation

/// Everything Monty keeps, in one folder the user can find:
///
///     ~/Documents/Monty Data/
///         Meeting Notes/    one Markdown file per meeting
///         History.json      recent dictations and the totals shown in the window
///         Dictionary.txt    the custom dictionary
///         Logs/             debug log and the latest recording
///
/// Two things stay where macOS expects them: settings (UserDefaults) and the Gemma
/// model, which Ollama keeps for every app that uses it.
enum MontyFolder {
    static var root: URL {
        // Not just "Monty": on the case-insensitive Mac disk that is the same folder as a
        // ~/Documents/monty source checkout, and the data ended up inside the git repo.
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Monty Data")
    }
    static var notes: URL { root.appendingPathComponent("Meeting Notes") }
    static var history: URL { root.appendingPathComponent("History.json") }
    static var dictionary: URL { root.appendingPathComponent("Dictionary.txt") }
    static var logs: URL { root.appendingPathComponent("Logs") }

    static func create() {
        for folder in [root, notes, logs] {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    /// Moves data from where earlier versions kept it. Runs at every launch and only
    /// moves what is still in an old place, so it is safe to repeat.
    static func moveOldData() {
        create()
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Monty")
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]

        // Folders are merged file by file (the new folder may already exist); a file whose
        // name is taken keeps both, the old one with "(old)" added.
        func move(_ from: URL, to: URL) {
            var isFolder: ObjCBool = false
            guard fm.fileExists(atPath: from.path, isDirectory: &isFolder) else { return }
            if isFolder.boolValue {
                try? fm.createDirectory(at: to, withIntermediateDirectories: true)
                for item in (try? fm.contentsOfDirectory(at: from, includingPropertiesForKeys: nil)) ?? [] where item.lastPathComponent != ".DS_Store" {
                    move(item, to: to.appendingPathComponent(item.lastPathComponent))
                }
                if let left = try? fm.contentsOfDirectory(atPath: from.path), left.filter({ $0 != ".DS_Store" }).isEmpty {
                    try? fm.removeItem(at: from)
                }
            } else if fm.fileExists(atPath: to.path) {
                let base = to.deletingPathExtension().lastPathComponent
                let ext = to.pathExtension
                let renamed = to.deletingLastPathComponent().appendingPathComponent(ext.isEmpty ? "\(base) (old)" : "\(base) (old).\(ext)")
                if !fm.fileExists(atPath: renamed.path) { try? fm.moveItem(at: from, to: renamed) }
            } else {
                try? fm.moveItem(at: from, to: to)
            }
        }
        move(support.appendingPathComponent("vocab.txt"), to: dictionary)
        move(support.appendingPathComponent("vocab.txt.bak"), to: logs.appendingPathComponent("Dictionary backup.txt"))
        move(support.appendingPathComponent("debug.log"), to: logs.appendingPathComponent("debug.log"))
        move(support.appendingPathComponent("last-recording.wav"), to: logs.appendingPathComponent("last-recording.wav"))
        if let left = try? fm.contentsOfDirectory(atPath: support.path), left.filter({ $0 != ".DS_Store" }).isEmpty {
            try? fm.removeItem(at: support)
        }

        // Meeting notes used to have their own folder in Documents.
        let oldNotes = documents.appendingPathComponent("Monty Notes")
        if let files = try? fm.contentsOfDirectory(at: oldNotes, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "md" {
                move(file, to: notes.appendingPathComponent(file.lastPathComponent))
            }
            if let left = try? fm.contentsOfDirectory(atPath: oldNotes.path), left.filter({ $0 != ".DS_Store" }).isEmpty {
                try? fm.removeItem(at: oldNotes)
            }
        }

        // One build used ~/Documents/Monty, which can be a source checkout; take the data back out.
        let sameNameFolder = documents.appendingPathComponent("Monty")
        for name in ["Dictionary.txt", "History.json", "Logs", "Meeting Notes"] {
            move(sameNameFolder.appendingPathComponent(name), to: root.appendingPathComponent(name))
        }

        History.moveFromSettings()
    }
}
