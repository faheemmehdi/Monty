import AudioToolbox
import CoreAudio
import Foundation

/// Records what other apps play (the other people in a meeting), through a Core Audio
/// process tap (macOS 14.2+). No virtual audio driver is needed. The first time, macOS
/// asks the user to allow "System Audio Recording" for Monty.
///
/// Audio comes out as 16 kHz mono Int16 samples, the same as the microphone recorder.
final class SystemAudioTap {
    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    /// Called on a background queue with each new chunk of samples.
    var onSamples: (([Int16]) -> Void)?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "Monty.systemAudio", qos: .userInitiated)
    private var sourceRate = 48_000.0
    private var sourceChannels = 2
    private var resampleRemainder = 0.0

    /// Taps the given processes (Core Audio process object ids), or every app except
    /// Monty when `processes` is empty.
    func start(processes: [AudioObjectID]) throws {
        let description: CATapDescription
        if processes.isEmpty {
            let me = Self.processObject(for: getpid()).map { [$0] } ?? []
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: me)
        } else {
            description = CATapDescription(stereoMixdownOfProcesses: processes)
        }
        description.uuid = UUID()
        description.muteBehavior = .unmuted   // the user still hears the meeting
        description.isPrivate = true
        description.name = "Monty meeting notes"

        try check(AudioHardwareCreateProcessTap(description, &tapID), "create the audio tap")

        // The tap's own format, usually 48 kHz float stereo.
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format), "read the tap format")
        sourceRate = format.mSampleRate
        sourceChannels = Int(max(1, format.mChannelsPerFrame))

        // A private aggregate device that carries the tap, so it can be read like a microphone.
        guard let outputUID = Self.defaultOutputUID() else { throw Failure(errorDescription: "No audio output device.") }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Monty Meeting Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "create the aggregate device")

        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, _, _, _ in
            self?.consume(input)
        }, "start reading audio")
        try check(AudioDeviceStart(aggregateID, procID), "start the aggregate device")
        Log.write("system audio tap started (\(Int(sourceRate)) Hz, \(sourceChannels) ch, \(processes.isEmpty ? "all apps" : "\(processes.count) apps"))")
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        procID = nil
    }

    deinit { stop() }

    /// Float stereo at the source rate in, 16 kHz mono Int16 out (averaging, then picking samples).
    private func consume(_ input: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let buffer = buffers.first, let data = buffer.mData else { return }
        let floats = data.assumingMemoryBound(to: Float.self)
        let channels = Int(max(1, buffer.mNumberChannels))
        let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
        let step = sourceRate / AudioRecorder.sampleRate
        var out: [Int16] = []
        out.reserveCapacity(Int(Double(frames) / step) + 1)
        var position = resampleRemainder
        while Int(position) < frames {
            let frame = Int(position)
            var sum: Float = 0
            for c in 0..<channels { sum += floats[frame * channels + c] }
            let mono = max(-1, min(1, sum / Float(channels)))
            out.append(Int16(mono * Float(Int16.max)))
            position += step
        }
        resampleRemainder = position - Double(frames)
        if !out.isEmpty { onSamples?(out) }
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw Failure(errorDescription: "Could not \(what) (error \(status)).") }
    }

    // MARK: Lookups

    static func processObject(for pid: pid_t) -> AudioObjectID? {
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    private static func defaultOutputUID() -> String? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }
}
