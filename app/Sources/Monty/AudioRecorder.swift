import AVFoundation

/// Records from the chosen microphone, or the one selected in System Settings > Sound >
/// Input when none is chosen, and returns the audio as a 16 kHz mono WAV file, the
/// format speech models expect.
///
/// A microphone takes about a quarter second to start, so the first word can be lost.
/// Two answers: `onFirstAudio` fires once sound really comes in (the cue to speak), and
/// with `keepWarm` the microphone stays on and the last half second before the key
/// press is kept, so nothing is lost at all.
final class AudioRecorder {
    static let sampleRate = 16_000.0
    private static let preRollSamples = Int(sampleRate / 2)

    /// Loudness from 0 to 1, many times a second while recording, on the main thread.
    var onLevel: ((Float) -> Void)?
    /// The first audio of a recording has arrived, on the main thread.
    var onFirstAudio: (() -> Void)?

    /// Core Audio UID of the microphone to use; nil means the system default.
    var deviceUID: String? {
        didSet { if keepWarm, deviceUID != oldValue { restartWarmEngine() } }
    }

    /// Keeps the microphone running between recordings. macOS shows the orange
    /// microphone dot the whole time this is on.
    var keepWarm = false {
        didSet {
            guard keepWarm != oldValue else { return }
            if keepWarm { restartWarmEngine() } else if !capturing { stopEngine() }
        }
    }

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var configObserver: NSObjectProtocol?
    private let lock = NSLock()
    // Guarded by `lock`:
    private var samples: [Int16] = []
    private var preRoll: [Int16] = []
    private var capturing = false
    private var waitingForFirstAudio = false

    private let target = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true
    )!

    func start() throws {
        lock.withLock {
            samples = keepWarm ? preRoll : []
            capturing = true
            waitingForFirstAudio = true
        }
        if engine == nil {
            do {
                try startEngine()
            } catch {
                lock.withLock { capturing = false }
                throw error
            }
        }
    }

    /// Takes the audio recorded so far and keeps recording, for meetings that are
    /// transcribed in stretches.
    func drain() -> [Int16] {
        lock.withLock {
            let chunk = samples
            samples.removeAll(keepingCapacity: true)
            return chunk
        }
    }

    struct Recording {
        let wav: Data
        let seconds: Double
        /// Loudest 100 ms stretch, from 0 to 1. Near zero means nobody spoke.
        let peakLevel: Float
    }

    func stop() -> Recording {
        let recorded: [Int16] = lock.withLock {
            capturing = false
            preRoll.removeAll(keepingCapacity: true)
            return samples
        }
        if !keepWarm { stopEngine() }

        let window = Int(Self.sampleRate / 10)
        var peak: Float = 0
        var i = 0
        while i < recorded.count {
            let end = min(i + window, recorded.count)
            peak = max(peak, Self.level(recorded[i..<end]))
            i = end
        }
        return Recording(wav: Self.wav(recorded), seconds: Double(recorded.count) / Self.sampleRate, peakLevel: peak)
    }

    // MARK: Engine

    private func startEngine() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let uid = deviceUID {
            if var id = AudioDevices.device(uid: uid)?.id, let unit = input.audioUnit {
                AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                     &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            } else {
                Log.write("chosen microphone is not connected, using the system default")
            }
        }
        let format = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: format, to: target)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine

        // Unplugging a headset or changing the input stops the engine; start it again.
        // Starting the engine itself also posts this notice while it keeps running, so
        // only restart when the engine really stopped. Restarting on every notice loops
        // forever and records nothing.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self, weak engine] _ in
            guard let self, let engine, engine === self.engine, !engine.isRunning else { return }
            guard self.keepWarm || self.lock.withLock({ self.capturing }) else { return }
            Log.write("microphone stopped after an audio configuration change, restarting it")
            self.restartWarmEngine()
        }
    }

    private func stopEngine() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    private func restartWarmEngine() {
        stopEngine()
        do {
            try startEngine()
        } catch {
            Log.write("could not start the microphone: \(error.localizedDescription)")
        }
    }

    // MARK: Audio

    /// RMS loudness mapped from -50 dB...0 dB to 0...1.
    static func level(_ chunk: ArraySlice<Int16>) -> Float {
        guard !chunk.isEmpty else { return 0 }
        var sum: Float = 0
        for s in chunk {
            let v = Float(s) / Float(Int16.max)
            sum += v * v
        }
        let rms = (sum / Float(chunk.count)).squareRoot()
        let db = 20 * log10(max(rms, 1e-9))
        return min(max((db + 50) / 50, 0), 1)
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = Self.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = out.int16ChannelData else { return }
        let chunk = UnsafeBufferPointer(start: data[0], count: Int(out.frameLength))

        let (isCapturing, isFirst): (Bool, Bool) = lock.withLock {
            if capturing {
                samples.append(contentsOf: chunk)
                let first = waitingForFirstAudio
                waitingForFirstAudio = false
                return (true, first)
            }
            // Not recording: keep only the most recent half second, in memory.
            preRoll.append(contentsOf: chunk)
            if preRoll.count > Self.preRollSamples { preRoll.removeFirst(preRoll.count - Self.preRollSamples) }
            return (false, false)
        }
        guard isCapturing else { return }
        if isFirst, let onFirstAudio { DispatchQueue.main.async { onFirstAudio() } }
        if let onLevel {
            let level = Self.level(ArraySlice(chunk))
            DispatchQueue.main.async { onLevel(level) }
        }
    }

    static func wav(_ samples: [Int16]) -> Data {
        let dataSize = UInt32(samples.count * 2)
        var d = Data()
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); put(36 + dataSize)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); put(UInt32(16))
        put(UInt16(1))                     // PCM
        put(UInt16(1))                     // mono
        put(UInt32(sampleRate))            // sample rate
        put(UInt32(sampleRate * 2))        // bytes per second
        put(UInt16(2))                     // bytes per frame
        put(UInt16(16))                    // bits per sample
        d.append(contentsOf: Array("data".utf8)); put(dataSize)
        samples.withUnsafeBytes { d.append(contentsOf: $0) }  // Apple silicon is little-endian, like WAV
        return d
    }
}
