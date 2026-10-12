import Foundation

/// One dictation, for the recent list and the stats in the Monty window.
struct DictationRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    let text: String
    /// Short label of the output language, e.g. EN, UR, ES.
    let language: String
    let seconds: Double
    let date: Date
}

/// The latest dictations and running totals, in ~/Documents/Monty Data/History.json.
enum History {
    private static let keep = 50

    private struct File: Codable {
        var records: [DictationRecord] = []
        var totalDictations = 0
        var totalWords = 0
        var totalSeconds = 0.0
    }

    private static let lock = NSLock()

    private static func read() -> File {
        guard let data = try? Data(contentsOf: MontyFolder.history),
              let file = try? decoder.decode(File.self, from: data)
        else { return File() }
        return file
    }

    private static func write(_ file: File) {
        MontyFolder.create()
        if let data = try? encoder.encode(file) { try? data.write(to: MontyFolder.history, options: .atomic) }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func all() -> [DictationRecord] { lock.withLock { read().records } }

    static func add(text: String, language: String, seconds: Double) {
        lock.withLock {
            var file = read()
            file.records = Array(([DictationRecord(text: text, language: language, seconds: seconds, date: Date())] + file.records).prefix(keep))
            file.totalDictations += 1
            file.totalWords += text.split(whereSeparator: \.isWhitespace).count
            file.totalSeconds += seconds
            write(file)
        }
    }

    struct Stats {
        var today = 0
        var total = 0
        var words = 0
        var averageSeconds: Double?
    }

    static func stats() -> Stats {
        let file = lock.withLock { read() }
        let today = file.records.filter { Calendar.current.isDateInToday($0.date) }.count
        return Stats(today: today, total: file.totalDictations, words: file.totalWords,
                     averageSeconds: file.totalDictations > 0 ? file.totalSeconds / Double(file.totalDictations) : nil)
    }

    /// Earlier versions kept the history inside the app settings; move it to History.json.
    static func moveFromSettings() {
        let d = UserDefaults.standard
        guard let data = d.data(forKey: "history") else { return }
        lock.withLock {
            var file = read()
            if file.records.isEmpty, let old = try? JSONDecoder().decode([DictationRecord].self, from: data) {
                file.records = old
            }
            file.totalDictations += d.integer(forKey: "totalDictations")
            file.totalWords += d.integer(forKey: "totalWords")
            file.totalSeconds += d.double(forKey: "totalSeconds")
            write(file)
        }
        for key in ["history", "totalDictations", "totalWords", "totalSeconds"] { d.removeObject(forKey: key) }
    }
}
