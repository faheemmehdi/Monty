import AppKit
import AVFoundation
import ApplicationServices
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum State {
        case idle, recording(OutputLanguage), processing
    }

    private let hotkeys = HotkeyMonitor()
    private let recorder = AudioRecorder()
    private var ollama = Ollama()
    private let indicator = NotchIndicator()
    private var statusItem: NSStatusItem!
    private let statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private var state = State.idle
    private var permissionTimer: Timer?
    private var slotItems: [NSMenuItem] = []
    private let languageMenus = [NSMenu(), NSMenu()]
    private let micMenu = NSMenu()
    private let warmMicItem = NSMenuItem(title: "Keep Microphone Ready", action: nil, keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Open at Login", action: nil, keyEquivalent: "")
    private let loadAtStartItem = NSMenuItem(title: "Load Gemma When Monty Starts", action: nil, keyEquivalent: "")
    private var memoryItems: [ModelMemory: NSMenuItem] = [:]
    private let settings = SettingsWindowController()
    private let meetings = MeetingDetector()
    private var meetingRecorder: MeetingRecorder?
    private var pendingMeeting: MeetingDetector.Meeting?
    private let meetingNotesItem = NSMenuItem(title: "Take Meeting Notes Now", action: nil, keyEquivalent: "")

    /// Ask on the notch whether to take notes when a meeting starts.
    private var askForNotes: Bool {
        get { UserDefaults.standard.object(forKey: "askForNotes") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "askForNotes"); settings.model.askForNotes = newValue }
    }

    private var notesLanguage: OutputLanguage {
        get { UserDefaults.standard.string(forKey: "notesLanguage").flatMap(OutputLanguage.with(id:)) ?? .english }
        set {
            UserDefaults.standard.set(newValue.id, forKey: "notesLanguage")
            indicator.model.notesLanguage = newValue
            settings.model.notesLanguage = newValue
        }
    }

    private var modelMemory: ModelMemory {
        get { ModelMemory(rawValue: UserDefaults.standard.string(forKey: "modelMemory") ?? "") ?? .thirtyMinutes }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "modelMemory")
            ollama.memory = newValue
            for (m, item) in memoryItems { item.state = m == newValue ? .on : .off }
            indicator.model.memory = newValue
            Task { [ollama] in await ollama.applyMemorySetting() }
            Log.write("keep Gemma in memory: \(newValue.label)")
        }
    }

    /// Off: after login Gemma takes no memory until the first dictation, which is then slower.
    private var loadAtStart: Bool {
        get { UserDefaults.standard.object(forKey: "loadModelAtStart") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "loadModelAtStart") }
    }
    private var dictationStart = Date()

    private var keepMicWarm: Bool {
        get { UserDefaults.standard.bool(forKey: "keepMicWarm") }
        set { UserDefaults.standard.set(newValue, forKey: "keepMicWarm") }
    }

    /// Core Audio UID of the chosen microphone; nil follows System Settings.
    private var micUID: String? {
        get { UserDefaults.standard.string(forKey: "microphoneUID") }
        set { UserDefaults.standard.set(newValue, forKey: "microphoneUID") }
    }

    // MARK: Languages

    /// The two languages Fn + Shift switches between. Slot 0 is A, slot 1 is B.
    private func slotLanguage(_ slot: Int) -> OutputLanguage {
        let id = UserDefaults.standard.string(forKey: slot == 0 ? "languageA" : "languageB")
        return id.flatMap(OutputLanguage.with(id:)) ?? (slot == 0 ? .english : .romanUrdu)
    }

    private func setSlot(_ slot: Int, to language: OutputLanguage) {
        UserDefaults.standard.set(language.id, forKey: slot == 0 ? "languageA" : "languageB")
        Log.write("language \(slot == 0 ? "A" : "B"): \(language.label)")
        refreshLanguages()
    }

    private var activeSlot: Int {
        get {
            if let slot = UserDefaults.standard.object(forKey: "activeSlot") as? Int { return slot }
            // Earlier versions saved the chosen mode instead: "roman" was the second one.
            return UserDefaults.standard.string(forKey: "outputMode") == "roman" ? 1 : 0
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "activeSlot")
            refreshLanguages()
        }
    }

    /// The language the next dictation is typed in.
    private var mode: OutputLanguage { slotLanguage(activeSlot) }

    private func refreshLanguages() {
        for (slot, item) in slotItems.enumerated() {
            item.title = "\(slot == 0 ? "A" : "B") · \(slotLanguage(slot).label)"
            item.state = slot == activeSlot ? .on : .off
        }
        indicator.model.slots = [slotLanguage(0), slotLanguage(1)]
        indicator.model.mode = mode
        settings.model.languageA = slotLanguage(0)
        settings.model.languageB = slotLanguage(1)
        settings.model.activeSlot = activeSlot
    }

    /// The list of every language, ticked where it is the one in `slot`.
    private func fillLanguageMenu(_ menu: NSMenu, slot: Int) {
        menu.removeAllItems()
        let current = slotLanguage(slot)
        for language in OutputLanguage.all {
            let item = NSMenuItem(title: language.menuTitle, action: #selector(chooseLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = "\(slot):\(language.id)"
            item.state = language == current ? .on : .off
            menu.addItem(item)
            if language == .asSpoken { menu.addItem(.separator()) }
        }
    }

    @objc private func chooseLanguage(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String,
              let colon = value.firstIndex(of: ":"), let slot = Int(value[..<colon]),
              let language = OutputLanguage.with(id: String(value[value.index(after: colon)...]))
        else { return }
        setSlot(slot, to: language)
    }

    @objc private func chooseSlot(_ sender: NSMenuItem) { activeSlot = sender.tag }

    /// From the notch panel: the language list pops up right at the mouse.
    private func pickLanguage(forSlot slot: Int) {
        let menu = NSMenu()
        fillLanguageMenu(menu, slot: slot)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Migration.fromMyWispr()
        MontyFolder.moveOldData()
        Vocabulary.ensureFileExists()
        ollama.memory = modelMemory
        setUpMenu()
        connectSettings()
        refreshLanguages()

        hotkeys.onStart = { [weak self] in
            guard let self else { return }
            self.startDictation(self.mode)
        }
        hotkeys.onStop = { [weak self] in self?.stopDictation() }
        hotkeys.onCancel = { [weak self] in self?.cancelDictation() }
        hotkeys.onHandsFree = { [weak self] in self?.lockHandsFree() }
        hotkeys.onToggleMode = { [weak self] in self?.toggleMode() }
        recorder.onLevel = { [weak self] level in self?.indicator.push(level: level) }
        // The cue to start speaking: only once sound really comes in from the microphone.
        recorder.onFirstAudio = { [weak self] in
            guard let self, case .recording = self.state else { return }
            NSSound(named: "Tink")?.play()
            Log.write(String(format: "first audio %.0f ms after fn", Date().timeIntervalSince(self.dictationStart) * 1000))
        }
        recorder.deviceUID = micUID

        // The island is ready before the first dictation, so hovering the notch works at once.
        indicator.ensurePanel()
        indicator.model.micName = micName
        indicator.onSelectMode = { [weak self] language in
            guard let self else { return }
            if let slot = [self.slotLanguage(0), self.slotLanguage(1)].firstIndex(of: language) { self.activeSlot = slot }
            Log.write("language from notch: \(language.label)")
        }
        indicator.model.onPickLanguage = { [weak self] slot in self?.pickLanguage(forSlot: slot) }
        indicator.model.onOpenSettings = { [weak self] in self?.openSettings() }
        indicator.model.notesLanguage = notesLanguage
        indicator.model.onStartNotes = { [weak self] audio in self?.startNotes(audio: audio) }
        indicator.model.onDismissMeeting = { [weak self] in self?.dismissMeeting() }
        indicator.model.onStopNotes = { [weak self] in self?.stopNotes() }
        indicator.model.onPickNotesLanguage = { [weak self] in self?.pickNotesLanguage() }
        meetings.onStart = { [weak self] meeting in self?.meetingStarted(meeting) }
        meetings.onEnd = { [weak self] in self?.meetingEnded() }
        meetings.start()
        // The same settings as the menu, for when the menu bar icon is hidden behind the notch.
        indicator.model.keepMicReady = keepMicWarm
        indicator.model.memory = modelMemory
        indicator.model.onToggleMicReady = { [weak self] in self?.toggleWarmMic() }
        indicator.model.onCycleMemory = { [weak self] in
            guard let self else { return }
            let all = ModelMemory.allCases
            self.modelMemory = all[(all.firstIndex(of: self.modelMemory)! + 1) % all.count]
        }
        indicator.model.onCycleMic = { [weak self] in self?.cycleMic() }

        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { if granted { self.recorder.keepWarm = self.keepMicWarm } }
        }
        waitForAccessibility()

        // Opened by hand (not at login, right after the Mac starts): show the window.
        if ProcessInfo.processInfo.systemUptime > 180 { openSettings() }

        guard loadAtStart else { return }
        Task { [ollama] in
            do {
                try await ollama.warmUp()
            } catch {
                await MainActor.run { self.setStatus(error.localizedDescription) }
            }
        }
    }

    // MARK: Permissions

    /// The keyboard shortcut needs Accessibility. Ask once, then keep checking until granted.
    private func waitForAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options), hotkeys.start() {
            setStatus("Ready")
            return
        }
        setStatus("Allow Monty in System Settings › Privacy & Security › Accessibility")
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self, AXIsProcessTrusted(), self.hotkeys.start() else { return }
            timer.invalidate()
            self.setStatus("Ready")
        }
    }

    // MARK: Dictation

    private func startDictation(_ mode: OutputLanguage) {
        guard case .idle = state else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            setStatus("Allow microphone in System Settings › Privacy & Security › Microphone")
            NSSound(named: "Basso")?.play()
            return
        }
        dictationStart = Date()
        do {
            try recorder.start()
        } catch {
            setStatus("Could not start the microphone: \(error.localizedDescription)")
            return
        }
        state = .recording(mode)
        indicator.show(.recording(mode))
        setIcon(.listening)
        setStatus("Listening → \(mode.label)")
    }

    private func stopDictation() {
        guard case .recording(let mode) = state else { return }
        let recording = recorder.stop()
        saveForDebugging(recording.wav)
        Log.write(String(format: "recorded %.1fs, peak level %.2f", recording.seconds, recording.peakLevel))
        guard recording.seconds >= 0.4 else {  // a tap, not a dictation
            finish(status: "Ready", phase: .hidden)
            return
        }
        // Without this, the model can invent a whole conversation out of silence.
        guard recording.peakLevel >= 0.2 else {
            finish(status: "Did not hear anything. Check the microphone in System Settings › Sound.", phase: .failed)
            return
        }
        state = .processing
        let processingStart = Date()
        NSSound(named: "Pop")?.play()
        indicator.show(.processing)
        setIcon(.nibbling)
        setStatus("Writing \(mode.label)…")

        Task {
            do {
                let text = try await ollama.dictate(wav: recording.wav, seconds: recording.seconds, mode: mode)
                await MainActor.run {
                    guard !text.isEmpty else {
                        self.finish(status: "Did not hear anything", phase: .failed)
                        return
                    }
                    self.indicator.model.lastText = text
                    let seconds = Date().timeIntervalSince(processingStart)
                    self.indicator.model.responseSeconds = seconds
                    History.add(text: text, language: mode.shortLabel, seconds: seconds)
                    self.settings.model.reloadHistory()
                    Log.write(String(format: "response in %.1fs", seconds))
                    switch FocusDetector.focusedElementAcceptsText() {
                    case .text:
                        TextInserter.insert(text)
                        self.finish(status: "Ready", phase: .done)
                    case .unknown:
                        // Pasted in case a text field has focus, and kept on the clipboard in
                        // case it did not land anywhere.
                        TextInserter.insert(text, keepOnClipboard: true)
                        self.finish(status: "Ready", phase: .done)
                    case .notText:
                        TextInserter.copy(text)
                        NSSound(named: "Glass")?.play()
                        self.finish(status: "Copied. Press ⌘V to paste.", phase: .copied)
                    }
                }
            } catch {
                await MainActor.run {
                    NSSound(named: "Basso")?.play()
                    self.finish(status: error.localizedDescription, phase: .failed)
                }
            }
        }
    }

    /// Fn + Shift: switches between language A and language B.
    private func toggleMode() {
        activeSlot = 1 - activeSlot
        NSSound(named: "Purr")?.play()
        Log.write("language switched to \(mode.label)")
        // A previous dictation still being written keeps the island; the next one uses the new language.
        if case .processing = state { return }
        if case .recording = state { _ = recorder.stop() }  // the press started a recording; drop it
        state = .idle
        indicator.model.handsFree = false
        indicator.show(.modeChanged(mode))
        setIcon(.awake)
        setStatus("Ready")
    }

    /// A double-tap: keep listening with no key held, until Fn is pressed again.
    private func lockHandsFree() {
        guard case .recording(let mode) = state else { return }
        NSSound(named: "Morse")?.play()
        indicator.model.handsFree = true
        setStatus("Hands-free → \(mode.label). Press Fn to finish, Esc to cancel.")
    }

    /// Fn was part of another shortcut, so throw the recording away.
    private func cancelDictation() {
        guard case .recording = state else { return }
        _ = recorder.stop()
        finish(status: "Ready", phase: .hidden)
    }

    private func finish(status: String, phase: NotchIndicator.Phase) {
        state = .idle
        indicator.model.handsFree = false
        indicator.show(phase)
        setIcon(.awake)
        setStatus(status)
    }

    /// Keeps the latest recording, so a wrong result can be checked against what was heard.
    private func saveForDebugging(_ wav: Data) {
        try? wav.write(to: MontyFolder.logs.appendingPathComponent("last-recording.wav"))
    }

    // MARK: Menu bar

    private func setUpMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Remembers where the user drags the icon (Command-drag), across launches.
        statusItem.autosaveName = "MontyMenuBarIcon"
        setIcon(.awake)

        let menu = NSMenu()
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(disabled: "Hold Fn and speak, release to type")
        menu.addItem(disabled: "Double-tap Fn for hands-free, Fn again to finish")
        menu.addItem(disabled: "Fn + Shift switches between your two languages")
        menu.addItem(.separator())
        menu.addItem(disabled: "Type what I say in:")
        for slot in 0..<2 {
            let item = NSMenuItem(title: "", action: #selector(chooseSlot(_:)), keyEquivalent: "")
            item.target = self
            item.tag = slot
            item.indentationLevel = 1
            slotItems.append(item)
            menu.addItem(item)
        }
        for slot in 0..<2 {
            let item = NSMenuItem(title: "Change Language \(slot == 0 ? "A" : "B")", action: nil, keyEquivalent: "")
            languageMenus[slot].delegate = self  // filled when opened
            item.submenu = languageMenus[slot]
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let micItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        micMenu.delegate = self  // rebuilt on every open, so newly plugged-in mics show up
        micItem.submenu = micMenu
        menu.addItem(micItem)
        warmMicItem.action = #selector(toggleWarmMic)
        warmMicItem.target = self
        warmMicItem.state = keepMicWarm ? .on : .off
        warmMicItem.toolTip = "Starts listening instantly, so no word is cut off. "
            + "macOS shows the orange microphone dot while this is on."
        menu.addItem(warmMicItem)
        menu.addItem(.separator())
        let memoryItem = NSMenuItem(title: "Keep Gemma in Memory", action: nil, keyEquivalent: "")
        let memoryMenu = NSMenu()
        for m in ModelMemory.allCases {
            let item = NSMenuItem(title: m.label, action: #selector(chooseMemory(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = m.rawValue
            item.state = m == modelMemory ? .on : .off
            memoryItems[m] = item
            memoryMenu.addItem(item)
        }
        memoryItem.submenu = memoryMenu
        memoryItem.toolTip = "Loaded, a dictation takes about 1 second. Unloaded, the first one takes "
            + "about 4.5 seconds. Gemma uses 2 to 4 GB of memory while loaded."
        menu.addItem(memoryItem)
        loadAtStartItem.action = #selector(toggleLoadAtStart)
        loadAtStartItem.target = self
        loadAtStartItem.state = loadAtStart ? .on : .off
        menu.addItem(loadAtStartItem)
        menu.addItem(.separator())
        loginItem.action = #selector(toggleLogin)
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Monty Folder", action: #selector(openMontyFolder), keyEquivalent: "").target = self
        meetingNotesItem.action = #selector(toggleMeetingNotes)
        meetingNotesItem.target = self
        menu.addItem(meetingNotesItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Edit Dictionary…", action: #selector(editDictionary), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Monty", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    private var menuBarIcons: [MontyMood: NSImage] = [:]

    /// Monty's face in the menu bar, matching what he is doing.
    private func setIcon(_ mood: MontyMood) {
        if menuBarIcons[mood] == nil { menuBarIcons[mood] = MontyIcons.menuBar(mood) }
        statusItem.button?.image = menuBarIcons[mood]
        statusItem.button?.image?.accessibilityDescription = "Monty"
    }

    private func setStatus(_ text: String) {
        settings.model.status = text
        Log.write("status: \(text)")
        indicator.model.status = text
        indicator.model.isHealthy = !["Allow", "Ollama", "Could not"].contains { text.hasPrefix($0) }
        statusLine.title = text
        statusItem.button?.toolTip = "Monty: \(text)"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if let slot = languageMenus.firstIndex(where: { $0 === menu }) {
            fillLanguageMenu(menu, slot: slot)
            return
        }
        guard menu === micMenu else { return }
        menu.removeAllItems()
        let devices = AudioDevices.inputs()
        let chosen = micUID.flatMap { uid in devices.contains { $0.uid == uid } ? uid : nil }

        let system = NSMenuItem(title: "System Default", action: #selector(chooseMic(_:)), keyEquivalent: "")
        system.target = self
        system.state = chosen == nil ? .on : .off
        menu.addItem(system)
        menu.addItem(.separator())
        for device in devices {
            let item = NSMenuItem(title: device.name, action: #selector(chooseMic(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.uid
            item.state = device.uid == chosen ? .on : .off
            menu.addItem(item)
        }
    }

    @objc private func chooseMic(_ sender: NSMenuItem) {
        micUID = sender.representedObject as? String
        recorder.deviceUID = micUID
        indicator.model.micName = micName
        settings.model.onRefreshMics?()
        Log.write("microphone: \(sender.title)")
    }

    private var micName: String {
        micUID.flatMap { AudioDevices.device(uid: $0)?.name } ?? "System Default"
    }

    /// From the notch panel: System Default, then each connected microphone, then around again.
    private func cycleMic() {
        let options: [String?] = [nil] + AudioDevices.inputs().map(\.uid)
        let current = options.firstIndex(of: micUID) ?? 0
        micUID = options[(current + 1) % options.count]
        recorder.deviceUID = micUID
        indicator.model.micName = micName
        settings.model.onRefreshMics?()
        Log.write("microphone from notch: \(micName)")
    }

    @objc private func toggleWarmMic() { setWarmMic(!keepMicWarm) }

    private func setWarmMic(_ on: Bool) {
        keepMicWarm = on
        settings.model.keepMicReady = on
        warmMicItem.state = keepMicWarm ? .on : .off
        recorder.keepWarm = keepMicWarm
        indicator.model.keepMicReady = keepMicWarm
        Log.write("keep microphone ready: \(keepMicWarm)")
    }

    @objc private func chooseMemory(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let m = ModelMemory(rawValue: raw) { modelMemory = m }
    }

    @objc private func toggleLoadAtStart() { setLoadAtStart(!loadAtStart) }

    private func setLoadAtStart(_ on: Bool) {
        loadAtStart = on
        settings.model.loadAtStart = on
        loadAtStartItem.state = loadAtStart ? .on : .off
        Log.write("load Gemma at start: \(loadAtStart)")
    }

    @objc private func toggleLogin() { setOpenAtLogin(SMAppService.mainApp.status != .enabled) }

    private func setOpenAtLogin(_ on: Bool) {
        let service = SMAppService.mainApp
        guard on != (service.status == .enabled) else { return }
        do {
            if !on {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            Log.write("open at login failed: \(error.localizedDescription)")
            setStatus("Could not change Open at Login: \(error.localizedDescription)")
        }
        // macOS may ask the user to approve it in System Settings › General › Login Items.
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        loginItem.state = service.status == .enabled ? .on : .off
        settings.model.openAtLogin = service.status == .enabled
        Log.write("open at login: \(service.status.rawValue)")
    }


    @objc private func editDictionary() {
        settings.model.section = .dictionary
        openSettings()
    }

    // MARK: Meeting notes

    private func meetingStarted(_ meeting: MeetingDetector.Meeting) {
        guard meetingRecorder == nil else { return }
        pendingMeeting = meeting
        indicator.model.meetingName = meeting.name
        indicator.model.meetingAvailable = true
        syncMeetingControls()
        guard askForNotes else { return }  // no question, but the hover panel still offers notes
        indicator.model.phaseStart = Date()
        indicator.setMeeting(.prompt)
        NSSound(named: "Glass")?.play()
        // Not answered in 30 seconds: hide the question, the meeting goes on without notes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.indicator.model.meetingState == .prompt else { return }
            self.dismissMeeting()
        }
    }

    /// The notes controls in the Monty window and the menu follow the notch.
    private func syncMeetingControls() {
        let m = settings.model
        m.meetingName = pendingMeeting?.name ?? meetingRecorder?.meeting.name ?? ""
        m.meetingAvailable = pendingMeeting != nil && meetingRecorder == nil
        m.meetingRecording = meetingRecorder != nil
        m.meetingStart = meetingRecorder?.startedAt ?? Date()
        meetingNotesItem.title = meetingRecorder != nil ? "Stop Meeting Notes" : "Take Meeting Notes Now"
    }

    @objc private func toggleMeetingNotes() {
        if meetingRecorder != nil { stopNotes() } else { startNotes() }
    }

    private func meetingEnded() {
        indicator.model.meetingAvailable = false
        defer { syncMeetingControls() }
        if meetingRecorder != nil {
            stopNotes()
        } else {
            pendingMeeting = nil
            if indicator.model.meetingState == .prompt { indicator.setMeeting(nil) }
        }
    }

    /// "Not now": hides the question; the meeting stays known, so the hover panel can
    /// still start notes.
    private func dismissMeeting() {
        indicator.setMeeting(nil)
    }

    /// Starts notes from this moment: for the meeting Monty noticed, or, when it noticed
    /// none, for whatever call is going on (every app's sound plus the microphone).
    /// Whether the last meeting notes kept the audio too; used when notes start without
    /// that question (the hover panel, the menu, the Monty window).
    private var meetingAudio: Bool {
        get { UserDefaults.standard.bool(forKey: "meetingAudio") }
        set { UserDefaults.standard.set(newValue, forKey: "meetingAudio") }
    }

    private func startNotes(audio: Bool? = nil) {
        guard meetingRecorder == nil else { return }
        if let audio { meetingAudio = audio }
        let meeting = pendingMeeting ?? MeetingDetector.Meeting(name: "Meeting", bundlePrefix: "", key: "manual")
        pendingMeeting = meeting
        indicator.model.meetingName = meeting.name
        defer { syncMeetingControls() }
        let recorder = MeetingRecorder(meeting: meeting, language: notesLanguage, ollama: ollama, saveAudio: meetingAudio)
        recorder.onLevel = { [weak self] level in self?.indicator.model.meetingLevel = CGFloat(level) }
        do {
            try recorder.start(micUID: micUID)
        } catch {
            setStatus("Could not start meeting notes: \(error.localizedDescription)")
            if meeting.key == "manual" { pendingMeeting = nil }  // there is no real meeting to offer later
            dismissMeeting()
            return
        }
        meetingRecorder = recorder
        meetings.isRecording = true
        indicator.model.meetingAvailable = false
        indicator.setMeeting(.recording)
        setStatus("Taking notes · \(meeting.name)")
    }

    private func stopNotes() {
        guard let recorder = meetingRecorder else { return }
        meetingRecorder = nil
        meetings.isRecording = false
        pendingMeeting = nil
        syncMeetingControls()
        indicator.setMeeting(.writing)
        setStatus("Writing meeting notes…")
        let duration = recorder.elapsed
        Task {
            let segments = await recorder.finish()
            guard !segments.isEmpty else {
                // Nobody spoke: there are no notes, and the recording is only silence.
                if let audio = recorder.audioURL { try? FileManager.default.removeItem(at: audio) }
                await MainActor.run {
                    self.indicator.setMeeting(nil)
                    self.indicator.show(.failed)
                    self.setStatus("No speech was heard in the meeting, so there are no notes.")
                }
                return
            }
            do {
                let transcript = MeetingRecorder.transcriptText(segments)
                let notes = try await self.ollama.meetingNotes(transcript: transcript, language: recorder.language, app: recorder.meeting.name)
                let transcriptHeading = await self.ollama.headings(in: recorder.language).last ?? "Transcript"
                let url = try NotesStore.save(notes: notes, segments: segments, meeting: recorder.meeting,
                                              language: recorder.language, startedAt: recorder.startedAt, duration: duration,
                                              transcriptHeading: transcriptHeading)
                NotesStore.attachAudio(recorder.audioURL, to: url)
                await MainActor.run {
                    self.indicator.model.phaseStart = Date()
                    self.indicator.setMeeting(.saved)
                    NSSound(named: "Hero")?.play()
                    self.setStatus("Ready")
                    self.settings.model.reloadNotes(select: url)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                        if self.indicator.model.meetingState == .saved { self.indicator.setMeeting(nil) }
                    }
                }
            } catch {
                NotesStore.keepAudio(recorder.audioURL, meeting: recorder.meeting, startedAt: recorder.startedAt)
                await MainActor.run {
                    self.indicator.setMeeting(nil)
                    self.indicator.show(.failed)
                    self.setStatus("Could not write the meeting notes: \(error.localizedDescription)")
                }
            }
        }
    }

    private func pickNotesLanguage() {
        let menu = NSMenu()
        for language in OutputLanguage.all {
            let item = NSMenuItem(title: language.label, action: #selector(chooseNotesLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = language.id
            item.state = language == notesLanguage ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func chooseNotesLanguage(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String, let language = OutputLanguage.with(id: id) { notesLanguage = language }
    }

    // MARK: Settings window

    @objc private func openSettings() { settings.show() }

    @objc private func openMontyFolder() {
        MontyFolder.create()
        NSWorkspace.shared.open(MontyFolder.root)
    }

    /// Opening Monty again from Applications, Launchpad or Spotlight shows its window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    private func connectSettings() {
        let m = settings.model
        m.memory = modelMemory
        m.loadAtStart = loadAtStart
        m.keepMicReady = keepMicWarm
        m.openAtLogin = SMAppService.mainApp.status == .enabled
        m.askForNotes = askForNotes
        m.notesLanguage = notesLanguage
        m.onSetAskForNotes = { [weak self] on in self?.askForNotes = on }
        m.onStartNotes = { [weak self] in self?.startNotes() }
        m.onStopNotes = { [weak self] in self?.stopNotes() }
        m.onSetNotesLanguage = { [weak self] language in self?.notesLanguage = language }
        m.onSetLanguage = { [weak self] slot, language in self?.setSlot(slot, to: language) }
        m.onSetActiveSlot = { [weak self] slot in self?.activeSlot = slot }
        m.onSetKeepMicReady = { [weak self] on in self?.setWarmMic(on) }
        m.onSetMemory = { [weak self] memory in self?.modelMemory = memory }
        m.onSetLoadAtStart = { [weak self] on in self?.setLoadAtStart(on) }
        m.onSetOpenAtLogin = { [weak self] on in self?.setOpenAtLogin(on) }
        m.onRefreshMics = { [weak self] in
            guard let self else { return }
            m.mics = [.init(uid: nil, name: "System Default")] + AudioDevices.inputs().map { .init(uid: $0.uid, name: $0.name) }
            m.micID = m.mics.first { $0.uid == self.micUID }?.id ?? "system-default"
        }
        m.onSetMic = { [weak self] uid in
            guard let self else { return }
            self.micUID = uid
            self.recorder.deviceUID = uid
            self.indicator.model.micName = self.micName
            Log.write("microphone from settings: \(self.micName)")
        }
    }
}

private extension NSMenu {
    func addItem(disabled title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        addItem(item)
    }
}
