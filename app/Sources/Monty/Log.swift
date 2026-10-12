import Foundation

/// Plain-text log at ~/Documents/Monty Data/Logs/debug.log, for finding out
/// afterwards what happened during a dictation. Kept small: cleared when it passes 200 KB.
enum Log {
    private static let queue = DispatchQueue(label: "Monty.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static var fileURL: URL {
        MontyFolder.logs.appendingPathComponent("debug.log")
    }

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            let url = fileURL
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            if size > 200_000 { try? FileManager.default.removeItem(at: url) }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
