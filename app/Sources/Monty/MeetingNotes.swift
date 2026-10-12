import Foundation

/// Records a meeting and turns it into notes.
///
/// Two streams are kept apart: the microphone (You) and the meeting app's own sound
/// (Others). Every 30 seconds each stream's new audio is transcribed, so when the meeting
/// ends only the notes are left to write.
final class MeetingRecorder {
    struct Segment {
        /// Seconds from the start of the meeting.
        let offset: Double
        let speaker: String
        let text: String
    }

    let meeting: MeetingDetector.Meeting
    let language: OutputLanguage
    let startedAt = Date()
    /// Voice level of the microphone, for Monty's ears in the notch.
    var onLevel: ((Float) -> Void)?
    private(set) var hasOthersAudio = false

    private let ollama: Ollama
    private let mic = AudioRecorder()
    private let tap = SystemAudioTap()
    private let othersLock = NSLock()
    private var othersSamples: [Int16] = []
    private var chunkStart = 0.0
    private var timer: Timer?
    private var segments: [Segment] = []
    private var work: Task<Void, Never>?
    private static let chunkSeconds = 30.0

    init(meeting: MeetingDetector.Meeting, language: OutputLanguage, ollama: Ollama) {
        self.meeting = meeting
        self.language = language
        self.ollama = ollama
    }

    func start(micUID: String?) throws {
        mic.deviceUID = micUID
        mic.onLevel = { [weak self] level in self?.onLevel?(level) }
        try mic.start()
        tap.onSamples = { [weak self] chunk in
            guard let self else { return }
            self.othersLock.withLock { self.othersSamples += chunk }
        }
        do {
            // Every app's sound except Monty's: a meeting app can start new audio processes
            // mid-call (browsers do), which a tap on its current processes would miss.
            try tap.start(processes: [])
            hasOthersAudio = true
        } catch {
            // Without "System Audio Recording" the notes still cover what the microphone hears.
            Log.write("meeting: no system audio, microphone only (\(error.localizedDescription))")
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.chunkSeconds, repeats: true) { [weak self] _ in self?.cut() }
        Log.write("meeting notes started: \(meeting.name), \(language.label)")
    }

    var elapsed: Double { Date().timeIntervalSince(startedAt) }

    /// Stops recording and returns the transcript once every stretch is transcribed.
    func finish() async -> [Segment] {
        timer?.invalidate()
        cut()
        _ = mic.stop()
        tap.stop()
        await work?.value
        return Self.removingEcho(segments).sorted { $0.offset < $1.offset }
    }

    private func cut() {
        let offset = chunkStart
        chunkStart = elapsed
        let mine = mic.drain()
        let theirs = othersLock.withLock { () -> [Int16] in
            let chunk = othersSamples
            othersSamples.removeAll(keepingCapacity: true)
            return chunk
        }
        // Stretches are transcribed one after another, in order.
        let previous = work
        work = Task { [weak self] in
            await previous?.value
            await self?.transcribe(theirs, speaker: "Others", offset: offset)
            await self?.transcribe(mine, speaker: "You", offset: offset)
        }
    }

    private func transcribe(_ samples: [Int16], speaker: String, offset: Double) async {
        guard Self.hasSpeech(samples) else { return }
        do {
            let heard = try await ollama.transcribe(wav: AudioRecorder.wav(samples))
            guard !heard.isEmpty else { return }
            // The transcript is kept in the notes language too (Urdu speech is often heard in
            // Hindi script); "As Spoken" keeps the words as they were heard.
            let text = language == .asSpoken ? heard : try await ollama.rewrite(heard, to: language)
            await MainActor.run { segments.append(Segment(offset: offset, speaker: speaker, text: text)) }
        } catch {
            Log.write("meeting: transcription failed: \(error.localizedDescription)")
        }
    }

    private static func hasSpeech(_ samples: [Int16]) -> Bool {
        let window = Int(AudioRecorder.sampleRate / 10)
        var i = 0
        while i < samples.count {
            let end = min(i + window, samples.count)
            if AudioRecorder.level(samples[i..<end]) >= 0.2 { return true }
            i = end
        }
        return false
    }

    /// On speakers instead of headphones the microphone also hears the other people.
    /// A "You" stretch that mostly repeats an "Others" stretch from the same time is that echo.
    private static func removingEcho(_ segments: [Segment]) -> [Segment] {
        let others = segments.filter { $0.speaker == "Others" }
        return segments.filter { segment in
            guard segment.speaker == "You" else { return true }
            let mine = words(segment.text)
            return !others.contains { other in
                abs(other.offset - segment.offset) <= chunkSeconds + 1
                    && overlap(mine, words(other.text)) > 0.6
            }
        }
    }

    private static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    private static func overlap(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(a.count)
    }

    static func transcriptText(_ segments: [Segment]) -> String {
        segments.map { "[\(clock($0.offset))] \($0.speaker): \($0.text)" }.joined(separator: "\n")
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// A saved meeting: a Markdown file in ~/Documents/Monty Data/Meeting Notes.
struct MeetingNote: Identifiable, Equatable {
    let id: URL
    let title: String
    let app: String
    let date: Date
    let duration: Double
    let language: String
    /// The notes and transcript, without the header block.
    let body: String
}

enum NotesStore {
    static var folder: URL { MontyFolder.notes }

    private static let iso = ISO8601DateFormatter()

    /// Writes the notes, then the full transcript, under a small header block the app reads back.
    static func save(notes: String, segments: [MeetingRecorder.Segment], meeting: MeetingDetector.Meeting,
                     language: OutputLanguage, startedAt: Date, duration: Double,
                     transcriptHeading: String = "Transcript") throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let title = notes.split(separator: "\n").first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)) } ?? "\(meeting.name) meeting"
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm"
        let safeTitle = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: " ").prefix(60)
        var url = folder.appendingPathComponent("\(stamp.string(from: startedAt)) – \(meeting.name) – \(safeTitle).md")
        if FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(stamp.string(from: startedAt)) – \(meeting.name) – \(safeTitle) \(Int(Date().timeIntervalSince1970)).md")
        }
        let text = """
        ---
        app: \(meeting.name)
        date: \(iso.string(from: startedAt))
        duration: \(Int(duration))
        language: \(language.label)
        ---

        \(notes.trimmingCharacters(in: .whitespacesAndNewlines))

        ## \(transcriptHeading)

        \(MeetingRecorder.transcriptText(segments))

        """
        try text.write(to: url, atomically: true, encoding: .utf8)
        Log.write("meeting notes saved: \(url.lastPathComponent)")
        return url
    }

    static func all() -> [MeetingNote] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "md" }.compactMap(read).sorted { $0.date > $1.date }
    }

    static func read(_ url: URL) -> MeetingNote? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var header: [String: String] = [:]
        var body = text
        if text.hasPrefix("---\n"), let end = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex) {
            for line in text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound].split(separator: "\n") {
                let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2 { header[parts[0]] = parts[1] }
            }
            body = String(text[end.upperBound...])
        }
        let title = body.split(separator: "\n").first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)) } ?? url.deletingPathExtension().lastPathComponent
        let date = header["date"].flatMap(iso.date(from:))
            ?? ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.creationDate] as? Date) ?? Date()
        return MeetingNote(id: url, title: title, app: header["app"] ?? "Meeting", date: date,
                           duration: Double(header["duration"] ?? "") ?? 0, language: header["language"] ?? "", body: body)
    }
}
