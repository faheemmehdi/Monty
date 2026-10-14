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
        // Optional, so a History.json written before these existed still opens.
        /// Dictations on `countedDay`. "Today" used to be counted in `records`, which keeps
        /// only the latest 50, so it stopped at 50.
        var countedDay: Date?
        var dayCount: Int?
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
            let now = Date()
            if let day = file.countedDay, Calendar.current.isDate(day, inSameDayAs: now) {
                file.dayCount = (file.dayCount ?? 0) + 1
            } else if file.countedDay == nil {
                // First run with the day counter: start from what the kept records show.
                file.dayCount = file.records.filter { Calendar.current.isDate($0.date, inSameDayAs: now) }.count + 1
            } else {
                file.dayCount = 1
            }
            file.countedDay = now
            file.records = Array(([DictationRecord(text: text, language: language, seconds: seconds, date: now)] + file.records).prefix(keep))
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
        let today: Int
        if let day = file.countedDay, let count = file.dayCount {
            today = Calendar.current.isDateInToday(day) ? count : 0
        } else {
            today = file.records.filter { Calendar.current.isDateInToday($0.date) }.count
        }
        // Speed of the recent dictations: the all-time average still carried the slow
        // first days and hardly moved.
        let recent = file.records.map(\.seconds)
        return Stats(today: today, total: file.totalDictations, words: file.totalWords,
                     averageSeconds: recent.isEmpty ? nil : recent.reduce(0, +) / Double(recent.count))
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
