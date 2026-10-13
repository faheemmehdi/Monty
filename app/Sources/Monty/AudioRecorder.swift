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

    private var unit: AudioUnit?
    private var deviceID = AudioDeviceID(kAudioObjectUnknown)
    private var renderBuffer: AVAudioPCMBuffer?
    private var converter: AVAudioConverter?
    private var deviceListener: AudioObjectPropertyListenerBlock?
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
        if unit == nil {
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

    // The microphone runs on a bare HAL audio unit pointed straight at the chosen device.
    // AVAudioEngine first opens the system default input, even when another microphone is
    // chosen, and with some USB headsets its format query spins forever on the main
    // thread: Monty froze on the next fn press until it was restarted.

    private struct Failure: LocalizedError {
        let errorDescription: String?
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else {
            throw Failure(errorDescription: "Could not \(step) (error \(status)).")
        }
    }

    private func startEngine() throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw Failure(errorDescription: "Could not find the microphone audio unit.")
        }
        var created: AudioUnit?
        try check(AudioComponentInstanceNew(component, &created), "open the microphone")
        guard let unit = created else { throw Failure(errorDescription: "Could not open the microphone.") }
        do {
            try configure(unit)
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }
        self.unit = unit
        watchDevices()
    }

    private func configure(_ unit: AudioUnit) throws {
        let uint32Size = UInt32(MemoryLayout<UInt32>.size)
        // Bus 1 is the input side of a HAL unit; bus 0 (playback) stays off.
        var on: UInt32 = 1, off: UInt32 = 0
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, uint32Size), "turn on recording")
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, uint32Size), "turn off playback")

        var device = inputDevice()
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                       &device, UInt32(MemoryLayout<AudioDeviceID>.size)), "select the microphone")
        deviceID = device

        // The microphone's own format, then the same rate and channels as float samples
        // for the converter, which mixes down to mono and resamples to 16 kHz.
        var hardware = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &size), "read the microphone format")
        guard hardware.mSampleRate > 0, hardware.mChannelsPerFrame > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: hardware.mSampleRate, channels: hardware.mChannelsPerFrame),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192)
        else { throw Failure(errorDescription: "The microphone reported no usable format.") }
        var client = format.streamDescription.pointee
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client, size), "set the recording format")
        var maxFrames = buffer.frameCapacity
        AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, uint32Size)
        renderBuffer = buffer
        converter = AVAudioConverter(from: format, to: target)

        var callback = AURenderCallbackStruct(inputProc: { refCon, flags, time, bus, frames, _ in
            Unmanaged<AudioRecorder>.fromOpaque(refCon).takeUnretainedValue().render(flags, time, bus, frames)
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                                       &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "connect the microphone")
        try check(AudioUnitInitialize(unit), "prepare the microphone")
        try check(AudioOutputUnitStart(unit), "start the microphone")
    }

    /// The chosen microphone when it is connected, otherwise the system default input.
    private func inputDevice() -> AudioDeviceID {
        if let uid = deviceUID {
            if let id = AudioDevices.device(uid: uid)?.id { return id }
            Log.write("chosen microphone is not connected, using the system default")
        }
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }

    /// Called on the audio thread for every slice of microphone audio.
    private func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ time: UnsafePointer<AudioTimeStamp>,
                        _ bus: UInt32, _ frames: UInt32) -> OSStatus {
        guard let unit, let buffer = renderBuffer, frames <= buffer.frameCapacity else { return noErr }
        buffer.frameLength = frames
        let status = AudioUnitRender(unit, flags, time, bus, frames, buffer.mutableAudioBufferList)
        if status == noErr { append(buffer) }
        return status
    }

    // Unplugging a headset, or changing the system input while it is the one in use,
    // leaves the unit with nothing to record: start it again on whatever is there now.
    private func watchDevices() {
        let restart: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.unit != nil else { return }
            guard self.keepWarm || self.lock.withLock({ self.capturing }) else { return }
            if self.inputDevice() == self.deviceID, self.deviceIsAlive() { return }
            Log.write("microphone changed or disconnected, restarting it")
            self.restartWarmEngine()
        }
        var defaultInput = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var devices = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultInput, .main, restart)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devices, .main, restart)
        deviceListener = restart
    }

    private func deviceIsAlive() -> Bool {
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        return AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &alive) == noErr && alive != 0
    }

    private func stopEngine() {
        if let deviceListener {
            var defaultInput = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                          mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var devices = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                     mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultInput, .main, deviceListener)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devices, .main, deviceListener)
        }
        deviceListener = nil
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        unit = nil
        renderBuffer = nil
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
