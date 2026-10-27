import AppKit
import SwiftUI
import Carbon.HIToolbox

// Developer check without the keyboard or microphone:
//   Monty --dictate-file sample.wav <language id>
let args = CommandLine.arguments
Migration.fromMyWispr()
MontyFolder.moveOldData()
if args.count == 4, args[1] == "--dictate-file" {
    // The language id from Languages.swift, e.g. english, roman, es, ar.
    guard let mode = OutputLanguage.with(id: args[3]) else { print("Unknown language: \(args[3])"); exit(2) }
    Vocabulary.ensureFileExists()
    Task {
        do {
            let wav = try Data(contentsOf: URL(fileURLWithPath: args[2]))
            let start = Date()
            let seconds = Double(wav.count - 44) / 2 / AudioRecorder.sampleRate
            let text = try await Ollama().dictate(wav: wav, seconds: seconds, mode: mode)
            print(String(format: "[%.1fs] %@", Date().timeIntervalSince(start), text))
            exit(0)
        } catch {
            print("Error: \(error.localizedDescription)")
            exit(1)
        }
    }
    RunLoop.main.run()
}

// Developer check of the microphone path, cold and warm:
//   Monty --record-test
if args.count == 2, args[1] == "--record-test" {
    let recorder = AudioRecorder()
    var start = Date()
    recorder.onFirstAudio = { print(String(format: "  first audio after %.0f ms", Date().timeIntervalSince(start) * 1000)) }
    func run(_ label: String) {
        start = Date()
        try! recorder.start()
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        let r = recorder.stop()
        print(String(format: "%@: recorded %.2fs, peak %.2f", label, r.seconds, r.peakLevel))
    }
    run("cold")
    run("cold again")
    recorder.keepWarm = true
    RunLoop.main.run(until: Date().addingTimeInterval(1))
    run("warm (includes the half second before start)")
    recorder.keepWarm = false
    exit(0)
}

// Developer check of the notch panel: shows it open for a few seconds.
//   Monty --preview-island [seconds] [hover|recording|handsfree|processing|done|copied|failed|wink]
if args.count >= 2, args[1] == "--preview-island" {
    let seconds = args.count > 2 ? Double(args[2]) ?? 6 : 6
    NSApplication.shared.setActivationPolicy(.accessory)
    let indicator = NotchIndicator()
    indicator.ensurePanel()
    indicator.model.lastText = "Hello, today I am building a new website on my laptop, its name is Wispr Flow."
    indicator.model.micName = "USB Audio Device"
    // Each state stays up long enough to look at (no linger timers here). The panel
    // takes a moment to appear, so the state starts after it, and its animation plays in full.
    RunLoop.main.run(until: Date().addingTimeInterval(0.8))
    indicator.model.phaseStart = Date()
    switch args.count > 3 ? args[3] : "hover" {
    case "recording":
        indicator.model.levels = [0.2, 0.5, 0.8, 0.4, 0.9, 0.6, 0.3, 0.7, 0.8]
        indicator.model.phase = .recording(.english)
    case "handsfree":
        indicator.model.levels = [0.3, 0.6, 0.4, 0.8, 0.5, 0.7, 0.2, 0.6, 0.4]
        indicator.model.handsFree = true
        indicator.model.phase = .recording(.romanUrdu)
    case "processing": indicator.model.phase = .processing
    case "done":
        indicator.model.responseSeconds = 1.4
        indicator.model.phase = .done
    case "copied": indicator.model.phase = .copied
    case "failed": indicator.model.phase = .failed
    case "wink": indicator.model.phase = .modeChanged(.romanUrdu)
    case "meeting-prompt":
        indicator.model.meetingName = "Zoom"
        indicator.setMeeting(.prompt)
    case "meeting-recording":
        indicator.model.meetingName = "Google Meet"
        indicator.setMeeting(.recording)
        indicator.model.meetingStart = Date().addingTimeInterval(-754)
        indicator.model.meetingLevel = 0.6
    case "meeting-hover":
        indicator.model.meetingName = "Google Meet"
        indicator.setMeeting(.recording)
        indicator.model.meetingStart = Date().addingTimeInterval(-754)
        indicator.model.lastText = "Hello, today I am building a new website on my laptop, its name is Wispr Flow."
        indicator.model.hovering = true
    default:
        indicator.model.hovering = true
        indicator.show(.hidden)
    }
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    exit(0)
}

// Developer check of the Fn gestures with simulated key events:
//   Monty --gesture-test
if args.count == 2, args[1] == "--gesture-test" {
    let monitor = HotkeyMonitor()
    var events: [String] = []
    monitor.onStart = { events.append("start") }
    monitor.onStop = { events.append("stop") }
    monitor.onCancel = { events.append("cancel") }
    monitor.onHandsFree = { events.append("handsFree") }
    monitor.onToggleMode = { events.append("toggle") }
    var held = false
    monitor.isFnPhysicallyHeld = { held }
    let base = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    var clock = 0.0  // simulated seconds since base

    func fn(_ down: Bool) {
        held = down
        let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Function), keyDown: down)!
        e.type = .flagsChanged
        e.flags = down ? .maskSecondaryFn : []
        e.timestamp = base + UInt64(clock * 1e9)
        _ = monitor.simulate(.flagsChanged, e)
    }
    func shift(_ down: Bool) {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Shift), keyDown: down)!
        e.type = .flagsChanged
        var flags: CGEventFlags = held ? .maskSecondaryFn : []
        if down { flags.insert(.maskShift) }
        e.flags = flags
        _ = monitor.simulate(.flagsChanged, e)
    }
    func fnWithShift(_ down: Bool) {
        held = down
        let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Function), keyDown: down)!
        e.type = .flagsChanged
        e.flags = down ? [.maskSecondaryFn, .maskShift] : .maskShift
        e.timestamp = base + UInt64(clock * 1e9)
        _ = monitor.simulate(.flagsChanged, e)
    }
    func key(_ code: Int) -> Bool {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: true)!
        return monitor.simulate(.keyDown, e)
    }
    func wait(_ s: Double) {
        clock += s
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))  // let queued callbacks run
    }
    func check(_ name: String, _ expected: [String], _ steps: () -> Void) {
        events = []
        clock += 5  // well apart from the previous case
        steps()
        wait(0)
        print("\(events == expected ? "PASS" : "FAIL") \(name): \(events)\(events == expected ? "" : "  expected \(expected)")")
    }

    check("hold 1s", ["start", "stop"]) { fn(true); wait(1); fn(false) }
    check("single tap", ["start", "cancel"]) { fn(true); wait(0.1); fn(false) }
    check("double tap, Fn again", ["start", "cancel", "start", "handsFree", "stop"]) {
        fn(true); wait(0.1); fn(false); wait(0.2); fn(true); wait(0.1); fn(false)
        wait(3); fn(true); wait(0.1); fn(false)
    }
    check("double tap, Esc", ["start", "cancel", "start", "handsFree", "cancel"]) {
        fn(true); wait(0.1); fn(false); wait(0.2); fn(true); wait(0.1); fn(false)
        wait(2); _ = key(kVK_Escape)
    }
    check("typing during hands-free keeps listening", ["start", "cancel", "start", "handsFree"]) {
        fn(true); wait(0.1); fn(false); wait(0.2); fn(true); wait(0.1); fn(false)
        wait(1); _ = key(kVK_ANSI_A)
    }
    check("(end the previous hands-free)", ["stop"]) { fn(true); wait(0.1); fn(false) }
    check("tap then hold", ["start", "cancel", "start", "stop"]) {
        fn(true); wait(0.1); fn(false); wait(0.2); fn(true); wait(1); fn(false)
    }
    check("two slow taps", ["start", "cancel", "start", "cancel"]) {
        fn(true); wait(0.1); fn(false); wait(0.7); fn(true); wait(0.1); fn(false)
    }
    check("Fn + arrow cancels", ["start", "cancel"]) { fn(true); wait(0.3); _ = key(kVK_LeftArrow); wait(0.2); fn(false) }
    check("Fn then Shift switches language", ["start", "cancel", "toggle"]) {
        fn(true); wait(0.2); shift(true); wait(0.1); shift(false); wait(0.1); fn(false)
    }
    check("Shift then Fn switches language", ["toggle"]) {
        shift(true); wait(0.1); fnWithShift(true); wait(0.1); fnWithShift(false); wait(0.1); shift(false)
    }
    check("quick Fn + Shift is not half of a double-tap", ["start", "cancel", "toggle", "start", "cancel"]) {
        fn(true); wait(0.05); shift(true); shift(false); wait(0.05); fn(false); wait(0.2); fn(true); wait(0.1); fn(false)
    }
    check("Shift while typing in hands-free does nothing", ["start", "cancel", "start", "handsFree"]) {
        fn(true); wait(0.1); fn(false); wait(0.2); fn(true); wait(0.1); fn(false)
        wait(1); shift(true); shift(false)
    }
    check("(end the previous hands-free)", ["stop"]) { fn(true); wait(0.1); fn(false) }
    check("release missed, watchdog stops", ["start", "stop"]) {
        // The watchdog reads the real clock, so this case runs in real time.
        clock = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - base) / 1e9
        fn(true)
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        held = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }
    exit(0)
}

// Developer check of Monty's animations: renders each mood over time into one sheet.
//   Monty --monty-sheet out.png
if args.count == 3, args[1] == "--monty-sheet" {
    let moods: [(String, MontyMood, CGFloat)] = [
        ("listening", .listening, 0.7), ("nibbling", .nibbling, 0), ("party", .party, 0),
        ("happy", .happy, 0), ("confused", .confused, 0), ("wink", .wink, 0), ("awake", .awake, 0),
    ]
    let times = stride(from: 0.0, through: 1.4, by: 0.1).map { $0 }
    let sheet = VStack(alignment: .leading, spacing: 6) {
        ForEach(Array(moods.enumerated()), id: \.offset) { _, entry in
            HStack(spacing: 6) {
                Text(entry.0).font(.system(size: 13, weight: .bold)).foregroundStyle(.white).frame(width: 80, alignment: .leading)
                ForEach(times, id: \.self) { t in
                    MontyView(mood: entry.1, size: 64, time: t,
                              level: entry.2 > 0 ? CGFloat(0.5 + 0.5 * sin(t * 9)) : 0)
                        .frame(width: 90, height: 90)
                        .background(Color.black)
                }
            }
        }
    }
    .padding(10)
    .background(Color(white: 0.15))
    guard let image = MontyIcons.render(sheet, scale: 1), let tiff = image.tiffRepresentation,
          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
        print("render failed"); exit(1)
    }
    try! png.write(to: URL(fileURLWithPath: args[2]))
    print("wrote \(args[2])")
    exit(0)
}

// Developer: writes the app icon sizes, for iconutil.
//   Monty --render-iconset out.iconset
if args.count == 3, args[1] == "--render-iconset" {
    try! MontyIcons.writeIconset(to: URL(fileURLWithPath: args[2]))
    print("wrote \(args[2])")
    exit(0)
}

// Developer: opens the settings window on one section and prints its window number,
// so exactly that window can be captured with `screencapture -l`.
//   Monty --show-settings <General|Microphone|Model|Dictionary|About> <seconds>
if args.count == 4, args[1] == "--show-settings", let section = SettingsModel.Section(rawValue: args[2]) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let controller = SettingsWindowController()
    controller.model.mics = [.init(uid: nil, name: "System Default"), .init(uid: "usb", name: "USB Audio Device")]
    controller.model.section = section
    controller.show()
    print("window \(NSApp.windows.first { $0.title == "Monty" }?.windowNumber ?? 0)")
    fflush(stdout)
    RunLoop.main.run(until: Date().addingTimeInterval(Double(args[3]) ?? 3))
    exit(0)
}

// Developer check of the system audio tap: records what the Mac plays for a few seconds.
//   Monty --tap-test <seconds> out.wav
if args.count == 4, args[1] == "--tap-test" {
    let tap = SystemAudioTap()
    var samples: [Int16] = []
    let lock = NSLock()
    tap.onSamples = { chunk in lock.withLock { samples += chunk } }
    do { try tap.start(processes: []) } catch { print("Error: \(error.localizedDescription)"); exit(1) }
    RunLoop.main.run(until: Date().addingTimeInterval(Double(args[2]) ?? 4))
    tap.stop()
    let recorded = lock.withLock { samples }
    try! AudioRecorder.wav(recorded).write(to: URL(fileURLWithPath: args[3]))
    let peak = recorded.map { abs(Int($0)) }.max() ?? 0
    print(String(format: "recorded %.1fs, peak %d", Double(recorded.count) / AudioRecorder.sampleRate, peak))
    exit(0)
}

// Developer check of meeting notes: records the Mac's sound and the microphone, then
// prints the transcript and the notes. No note is saved; the recording is, and its path
// is printed, to check it.
//   Monty --meeting-test <seconds> <language id>
if args.count == 4, args[1] == "--meeting-test", let language = OutputLanguage.with(id: args[3]) {
    let recorder = MeetingRecorder(meeting: .init(name: "Test call", bundlePrefix: ""), language: language, ollama: Ollama(), saveAudio: true)
    Task { @MainActor in
        do { try recorder.start(micUID: nil) } catch { print("Error: \(error.localizedDescription)"); exit(1) }
        try? await Task.sleep(for: .seconds(Double(args[2]) ?? 40))
        let segments = await recorder.finish()
        print("== recording: \(recorder.audioURL?.path ?? "none")")
        print("== transcript (others audio: \(recorder.hasOthersAudio))\n" + MeetingRecorder.transcriptText(segments))
        let start = Date()
        let notes = (try? await Ollama().meetingNotes(transcript: MeetingRecorder.transcriptText(segments), language: language, app: "Test call")) ?? "(notes failed)"
        print(String(format: "== notes (%.1fs)\n", Date().timeIntervalSince(start)) + notes)
        exit(0)
    }
    RunLoop.main.run()
}

// Developer: prints the bundle ids of the processes using a microphone right now.
//   Monty --mic-users
if args.count == 2, args[1] == "--mic-users" {
    print(MeetingDetector.bundlesUsingMicrophone())
    exit(0)
}

// Developer check of meeting detection with made-up polls (each poll is 3 seconds).
//   Monty --detector-test
if args.count == 2, args[1] == "--detector-test" {
    let detector = MeetingDetector()
    var events: [String] = []
    detector.onStart = { events.append("start \($0.key)") }
    detector.onEnd = { events.append("end") }
    let meetA = MeetingDetector.Meeting(name: "Google Meet", bundlePrefix: "com.google.Chrome", key: "abc-defg-hij")
    let meetB = MeetingDetector.Meeting(name: "Google Meet", bundlePrefix: "com.google.Chrome", key: "xyz-wxyz-xyz")
    var now: MeetingDetector.Meeting?
    detector.finder = { now }
    var stillOn = false
    detector.stillOn = { _ in stillOn }
    func polls(_ n: Int, _ meeting: MeetingDetector.Meeting?) { now = meeting; for _ in 0..<n { detector.poll() } }
    func check(_ name: String, _ expected: [String], _ steps: () -> Void) {
        events = []
        steps()
        print("\(events == expected ? "PASS" : "FAIL") \(name): \(events)\(events == expected ? "" : "  expected \(expected)")")
    }
    check("a meeting opens", ["start abc-defg-hij"]) { polls(1, nil); polls(3, meetA) }
    check("tab closed, reopened 6 s later: same meeting, no new question", []) { polls(2, nil); polls(3, meetA) }
    check("tab closed for 9 s, reopened: asks again", ["end", "start abc-defg-hij"]) { polls(3, nil); polls(3, meetA) }
    check("another meeting code: asks for that one", ["end", "start xyz-wxyz-xyz"]) { polls(1, meetB) }
    detector.isRecording = true
    check("while recording, a 15 s gap does not end it", []) { polls(5, nil); polls(1, meetB) }
    stillOn = true
    check("while recording, another tab in front or muted for a minute does not end it", []) { polls(20, nil); polls(1, meetB) }
    stillOn = false
    check("while recording, 21 s without the meeting ends it", ["end"]) { polls(7, nil) }
    detector.isRecording = false
    check("a 3 s blip is not a meeting", []) { polls(1, meetA); polls(2, nil) }
    exit(0)
}

// Developer: renders the README demo frames (no screen capture).
//   Monty --render-demo <folder>
if args.count == 3, args[1] == "--render-demo" {
    MainActor.assumeIsolated { try! NotchDemo.renderFrames(to: URL(fileURLWithPath: args[2])) }
    print("rendered \(Int(NotchDemo.duration * NotchDemo.fps)) frames")
    exit(0)
}

// One Monty at a time: a second copy would add a second menu bar icon and a second
// keyboard listener, and both would type every dictation.
if let id = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0 != .current }) {
    Log.write("another Monty is already running; this copy quits")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // menu bar only
app.run()
