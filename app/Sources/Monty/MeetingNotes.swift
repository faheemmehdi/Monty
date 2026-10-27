import AVFoundation

/// Records a meeting and turns it into notes.
///
/// Two streams are kept apart: the microphone (You) and the meeting app's own sound
/// (Others). Every 30 seconds each stream's new audio is transcribed, so when the meeting
/// ends only the notes are left to write. When asked, both streams are also mixed into one
/// audio file, kept next to the notes.
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
    /// Samples of the Others stream since the start, silence filled in included.
    private var othersTotal = 0
    private var chunkStart = 0.0
    private var timer: Timer?
    private var segments: [Segment] = []
    private var work: Task<Void, Never>?
    private static let chunkSeconds = 30.0
    /// The meeting's sound while it is recorded, both sides mixed; nil when it could not be
    /// written. `NotesStore` gives it the note's name once the notes are saved.
    private(set) var audioURL: URL?
    private var audioFile: AVAudioFile?

    private let saveAudio: Bool

    init(meeting: MeetingDetector.Meeting, language: OutputLanguage, ollama: Ollama, saveAudio: Bool) {
        self.meeting = meeting
        self.language = language
        self.ollama = ollama
        self.saveAudio = saveAudio
    }

    func start(micUID: String?) throws {
        mic.deviceUID = micUID
        mic.onLevel = { [weak self] level in self?.onLevel?(level) }
        try mic.start()
        tap.onSamples = { [weak self] chunk in
            guard let self else { return }
            let arrivedAt = self.elapsed
            self.othersLock.withLock {
                self.fillOthersSilence(upTo: arrivedAt - Double(chunk.count) / AudioRecorder.sampleRate)
                self.othersSamples += chunk
                self.othersTotal += chunk.count
            }
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
        if saveAudio { openAudioFile() }
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
        audioFile = nil  // closes the file
        await work?.value
        return Self.removingEcho(segments).sorted { $0.offset < $1.offset }
    }

    private func cut() {
        let offset = chunkStart
        chunkStart = elapsed
        let mine = mic.drain()
        let theirs = othersLock.withLock { () -> [Int16] in
            fillOthersSilence(upTo: chunkStart)
            let chunk = othersSamples
            othersSamples.removeAll(keepingCapacity: true)
            return chunk
        }
        appendAudio(mine, theirs)
        // Stretches are transcribed one after another, in order.
        let previous = work
        work = Task { [weak self] in
            await previous?.value
            await self?.transcribe(theirs, speaker: "Others", offset: offset)
            await self?.transcribe(mine, speaker: "You", offset: offset)
        }
    }

    /// macOS sends the meeting app's sound only while some sound plays, so its silences
    /// would vanish and everything after them would move earlier than the microphone.
    /// Silence is filled in up to `time` (seconds from the start), keeping the two in step.
    /// Call with `othersLock` held.
    private func fillOthersSilence(upTo time: Double) {
        let expected = Int(time * AudioRecorder.sampleRate)
        let missing = expected - othersTotal
        guard missing > Int(AudioRecorder.sampleRate / 10) else { return }  // under 0.1 s is jitter
        othersSamples += [Int16](repeating: 0, count: missing)
        othersTotal = expected
    }

    /// AAC at 16 kHz, the rate both streams arrive in, in stereo: the microphone (You) on
    /// the left, the meeting app (Others) on the right, so a line of the transcript can be
    /// played for its own speaker. About 30 MB for an hour.
    private func openAudioFile() {
        let url = NotesStore.folder.appendingPathComponent(".recording \(Int(startedAt.timeIntervalSince1970)).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: AudioRecorder.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 64_000,
        ]
        do {
            try FileManager.default.createDirectory(at: NotesStore.folder, withIntermediateDirectories: true)
            audioFile = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
            audioURL = url
        } catch {
            Log.write("meeting: audio is not saved (\(error.localizedDescription))")
        }
    }

    /// Adds one stretch of both streams, one per channel. The shorter one is padded with
    /// silence, so the two stay in step.
    private func appendAudio(_ mine: [Int16], _ theirs: [Int16]) {
        guard let audioFile else { return }
        let count = max(mine.count, theirs.count)
        guard count > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: AVAudioFrameCount(count)),
              let channel = buffer.int16ChannelData?[0]
        else { return }
        for i in 0..<count {  // interleaved: left, right, left, right, ...
            channel[2 * i] = i < mine.count ? mine[i] : 0
            channel[2 * i + 1] = i < theirs.count ? theirs[i] : 0
        }
        buffer.frameLength = AVAudioFrameCount(count)
        do {
            try audioFile.write(from: buffer)
        } catch {
            Log.write("meeting: audio stopped saving (\(error.localizedDescription))")
            self.audioFile = nil
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
    /// The meeting's recording, if it was kept.
    var audio: URL? { NotesStore.audio(for: id) }
}

enum NotesStore {
    static var folder: URL { MontyFolder.notes }

    /// Moves a note, and its recording, to the Trash, so a note deleted by mistake can still
    /// be put back.
    static func moveToTrash(_ note: MeetingNote) throws {
        try FileManager.default.trashItem(at: note.id, resultingItemURL: nil)
        if let audio = note.audio { try? FileManager.default.trashItem(at: audio, resultingItemURL: nil) }
    }

    /// The recording of a note: a file with the note's name and .m4a, when there is one.
    static func audio(for note: URL) -> URL? {
        let url = note.deletingPathExtension().appendingPathExtension("m4a")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Gives a meeting's recording the name of its note.
    static func attachAudio(_ recording: URL?, to note: URL) {
        guard let recording else { return }
        do {
            try FileManager.default.moveItem(at: recording, to: note.deletingPathExtension().appendingPathExtension("m4a"))
        } catch {
            Log.write("meeting: could not attach the recording (\(error.localizedDescription))")
        }
    }

    /// Keeps a recording whose notes could not be written, under a plain name in the notes folder.
    static func keepAudio(_ recording: URL?, meeting: MeetingDetector.Meeting, startedAt: Date) {
        guard let recording else { return }
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm"
        let url = folder.appendingPathComponent("\(stamp.string(from: startedAt)) – \(meeting.name) – Recording.m4a")
        try? FileManager.default.moveItem(at: recording, to: url)
    }

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
