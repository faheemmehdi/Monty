import AppKit
import SwiftUI

/// Everything the settings window shows and edits. The app delegate fills it in and is
/// told about every change through the `on...` closures, so the menu bar menu, the notch
/// panel and this window always agree.
final class SettingsModel: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case home = "Home", notes = "Notes", dictionary = "Dictionary", settings = "Settings", about = "About"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .home: return "house.fill"
            case .notes: return "note.text"
            case .settings: return "gearshape.fill"
            case .dictionary: return "character.book.closed.fill"
            case .about: return "info.circle.fill"
            }
        }
    }

    struct Mic: Hashable, Identifiable {
        let uid: String?  // nil is the system default
        let name: String
        var id: String { uid ?? "system-default" }
    }

    struct DictionaryRow: Identifiable, Equatable {
        let id = UUID()
        var word: String
        var wrong: String  // comma separated
    }

    @Published var section = Section.home
    @Published var history: [DictationRecord] = []
    @Published var stats = History.Stats()
    @Published var status = "Ready"
    @Published var languageA = OutputLanguage.english { didSet { if languageA != oldValue { onSetLanguage?(0, languageA) } } }
    @Published var languageB = OutputLanguage.romanUrdu { didSet { if languageB != oldValue { onSetLanguage?(1, languageB) } } }
    @Published var activeSlot = 0 { didSet { if activeSlot != oldValue { onSetActiveSlot?(activeSlot) } } }
    @Published var mics: [Mic] = []
    @Published var micID = "system-default" { didSet { if micID != oldValue { onSetMic?(mics.first { $0.id == micID }?.uid) } } }
    @Published var keepMicReady = false { didSet { if keepMicReady != oldValue { onSetKeepMicReady?(keepMicReady) } } }
    @Published var memory = ModelMemory.thirtyMinutes { didSet { if memory != oldValue { onSetMemory?(memory) } } }
    @Published var loadAtStart = true { didSet { if loadAtStart != oldValue { onSetLoadAtStart?(loadAtStart) } } }
    @Published var openAtLogin = false { didSet { if openAtLogin != oldValue { onSetOpenAtLogin?(openAtLogin) } } }
    @Published var dictionary: [DictionaryRow] = []
    @Published var dictionarySaved = true
    @Published var notes: [MeetingNote] = []
    @Published var selectedNote: MeetingNote?
    @Published var askForNotes = true { didSet { if askForNotes != oldValue { onSetAskForNotes?(askForNotes) } } }
    @Published var notesLanguage = OutputLanguage.english { didSet { if notesLanguage != oldValue { onSetNotesLanguage?(notesLanguage) } } }
    var onSetAskForNotes: ((Bool) -> Void)?
    var onStartNotes: (() -> Void)?
    var onStopNotes: (() -> Void)?
    @Published var meetingName = ""
    /// A meeting is on and notes are not being taken: they can still start from now.
    @Published var meetingAvailable = false
    @Published var meetingRecording = false
    @Published var meetingStart = Date()
    var onSetNotesLanguage: ((OutputLanguage) -> Void)?

    var onSetLanguage: ((Int, OutputLanguage) -> Void)?
    var onSetActiveSlot: ((Int) -> Void)?
    var onSetMic: ((String?) -> Void)?
    var onSetKeepMicReady: ((Bool) -> Void)?
    var onSetMemory: ((ModelMemory) -> Void)?
    var onSetLoadAtStart: ((Bool) -> Void)?
    var onSetOpenAtLogin: ((Bool) -> Void)?
    var onRefreshMics: (() -> Void)?

    /// Re-reads the notes folder; `select` opens a just-saved note.
    func reloadNotes(select url: URL? = nil) {
        notes = NotesStore.all()
        if let url, let note = notes.first(where: { $0.id == url }) {
            selectedNote = note
        } else if let current = selectedNote {
            selectedNote = notes.first { $0.id == current.id }
        }
    }

    func reloadHistory() {
        history = History.all()
        stats = History.stats()
    }

    // MARK: Dictionary file

    func loadDictionary() {
        dictionary = Vocabulary.load().map { DictionaryRow(word: $0.word, wrong: $0.wrong.joined(separator: ", ")) }
        dictionarySaved = true
    }

    /// Writes the rows back to Dictionary.txt, keeping the explanation at the top of the file.
    func saveDictionary() {
        let header = (try? String(contentsOf: Vocabulary.fileURL, encoding: .utf8))?
            .split(separator: "\n", omittingEmptySubsequences: false)
            .prefix { $0.hasPrefix("#") || $0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: "\n") ?? ""
        let lines = dictionary.compactMap { row -> String? in
            let word = row.word.trimmingCharacters(in: .whitespaces)
            guard !word.isEmpty else { return nil }
            let wrong = row.wrong.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return wrong.isEmpty ? word : "\(word) = \(wrong.joined(separator: ", "))"
        }
        let text = (header.isEmpty ? "" : header + (header.hasSuffix("\n") ? "" : "\n")) + lines.joined(separator: "\n") + "\n"
        try? text.write(to: Vocabulary.fileURL, atomically: true, encoding: .utf8)
        dictionarySaved = true
        Log.write("dictionary saved from settings: \(lines.count) entries")
    }
}

/// The Monty window: opens from Applications, Launchpad or Spotlight, or from the menu.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    let model = SettingsModel()
    private var window: NSWindow?

    func show() {
        model.loadDictionary()
        model.reloadHistory()
        model.reloadNotes()
        model.onRefreshMics?()
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1040, height: 680),
                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.title = "Monty"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.backgroundColor = NSColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1)
            window.appearance = NSAppearance(named: .darkAqua)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            window.center()
            window.delegate = self
            self.window = window
        }
        // A menu bar app has no Dock icon; show one while the window is open, so it can
        // be switched to with Command-Tab like any app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if !model.dictionarySaved { model.saveDictionary() }
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: Views

/// Monty's colors, from the mascot: peach body, pink ears, coral nose, ink eyes.
private enum Palette {
    static let peach = Color(red: 1, green: 0.851, blue: 0.749)        // #FFD9BF
    static let peachDeep = Color(red: 1, green: 0.769, blue: 0.631)    // #FFC4A1
    static let pink = Color(red: 1, green: 0.616, blue: 0.706)         // #FF9DB4
    static let coral = Color(red: 1, green: 0.478, blue: 0.604)        // #FF7A9A
    static let ink = Color(red: 0.106, green: 0.106, blue: 0.122)      // #1B1B1F
    static let rail = Color(red: 0.07, green: 0.07, blue: 0.08)
    static let panel = Color(red: 0.118, green: 0.118, blue: 0.133)    // #1E1E22
    static let tile = Color(red: 0.165, green: 0.165, blue: 0.188)     // #2A2A30
    static let cream = Color(red: 0.957, green: 0.945, blue: 0.925)    // #F4F1EC
    static let mint = Color(red: 0.4, green: 0.86, blue: 0.62)
}

private struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        HStack(spacing: 0) {
            Rail(model: model)
            SidePanel(model: model)
            MainArea(model: model)
        }
        .background(Palette.rail)
        .frame(minWidth: 1040, minHeight: 680)
        .ignoresSafeArea()
    }
}

// MARK: Rail

/// The thin dark strip of round section buttons, like the reference's icon rail.
private struct Rail: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(spacing: 12) {
            Spacer().frame(height: 52)  // room for the window buttons
            ForEach(SettingsModel.Section.allCases) { section in
                let selected = model.section == section
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { model.section = section }
                } label: {
                    Image(systemName: section.icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(selected ? Palette.ink : .white.opacity(0.55))
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(selected ? Palette.peach : Color.white.opacity(0.06)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(section.rawValue)
            }
            Spacer()
            AnimatedMonty(mood: .awake, size: 38, since: Date())
                .padding(6)
                .background(Circle().fill(Color.white.opacity(0.08)))
                .padding(.bottom, 18)
        }
        .frame(width: 76)
    }
}

// MARK: Side panel

/// The dark column: Monty's card, stat tiles and the latest dictations.
private struct SidePanel: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            heroCard
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                StatTile(icon: "sun.max", label: "Today", value: "\(model.stats.today)")
                StatTile(icon: "sparkles", label: "All time", value: "\(model.stats.total)")
                StatTile(icon: "text.word.spacing", label: "Words", value: compact(model.stats.words))
                StatTile(icon: "bolt", label: "Avg speed",
                         value: model.stats.averageSeconds.map { String(format: "%.1fs", $0) } ?? "–")
            }
            Text("Shortcuts").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                .padding(.top, 6)
            ShortcutTile(keys: "Hold fn", what: "Talk while held, let go to type")
            ShortcutTile(keys: "Tap fn twice", what: "Hands-free: fn again to finish, Esc to cancel")
            ShortcutTile(keys: "fn + ⇧", what: "Switch between language A and B")
            Spacer(minLength: 0)
        }
        .padding(.top, 46).padding(.horizontal, 12).padding(.bottom, 12)
        .frame(width: 300)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Palette.panel))
        .padding(.vertical, 10)
    }

    private var heroCard: some View {
        HStack(spacing: 12) {
            // Monty is peach, so his card is pink and he sits on a soft white circle.
            AnimatedMonty(mood: .awake, size: 54, since: Date())
                .padding(8)
                .background(Circle().fill(.white))
            VStack(alignment: .leading, spacing: 6) {
                Text("Hi, I'm Monty")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(Palette.ink)
                HStack(spacing: 5) {
                    Circle().fill(isReady ? Palette.mint : Palette.coral).frame(width: 7, height: 7)
                    Text(isReady ? "Ready" : model.status)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                }
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Capsule().fill(.white.opacity(0.7)))
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Palette.pink))
    }

    private var isReady: Bool { model.status == "Ready" }

    private func compact(_ n: Int) -> String {
        n >= 10_000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }
}

private struct ShortcutTile: View {
    let keys: String
    let what: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            KeyCap(keys: keys)
            Text(what).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.tile))
    }
}

private struct StatTile: View {
    let icon: String
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 18, height: 18)
                    .background(RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.pink.opacity(0.8), lineWidth: 1.2))
                    .foregroundStyle(Palette.pink)
                Text(label).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
            }
            Text(value)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.tile))
    }
}

// MARK: Main area

/// The light right side, where each section is a set of bento cards.
private struct MainArea: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch model.section {
                case .home: HomePage(model: model)
                case .notes: NotesPage(model: model)
                case .settings: SettingsPage(model: model)
                case .dictionary: DictionaryPage(model: model)
                case .about: AboutPage()
                }
            }
            .padding(30)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Palette.cream))
        .environment(\.colorScheme, .light)
        .padding(10)
    }
}

private struct PageTitle: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 34, weight: .regular)).foregroundStyle(Palette.ink)
            Text(subtitle).font(.system(size: 13)).foregroundStyle(Palette.ink.opacity(0.55))
        }
        .padding(.bottom, 6)
    }
}

/// A rounded bento card with a small title.
private struct Bento<Content: View>: View {
    var title: String? = nil
    var fill: Color = .white
    var dark = false
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                Text(title)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(dark ? .white : Palette.ink)
            }
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(fill))
    }
}

private struct Chip: View {
    let text: String
    var fill: Color = Palette.ink
    var foreground: Color = .white
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(fill))
            .foregroundStyle(foreground)
    }
}

private struct KeyCap: View {
    let keys: String
    var body: some View {
        Text(keys)
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(Palette.peach))
    }
}

/// A language as a pill that opens the full list.
private struct LanguageMenu: View {
    let current: OutputLanguage
    let choose: (OutputLanguage) -> Void
    var body: some View {
        Menu {
            ForEach(OutputLanguage.all) { language in
                Button(language.label) { choose(language) }
            }
        } label: {
            HStack(spacing: 6) {
                Text(current.label).font(.system(size: 13, weight: .semibold))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Capsule().fill(Palette.ink))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

private struct HomePage: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        PageTitle(title: "Hey there 👋", subtitle: "Hold fn anywhere, talk in your language, and Monty types it for you.")
        Bento(title: "Typing in", fill: Palette.peach) {
            let active = model.activeSlot == 0 ? model.languageA : model.languageB
            Text(active.label).font(.system(size: 30, weight: .light)).foregroundStyle(Palette.ink)
            HStack(spacing: 8) {
                Chip(text: "A · \(model.languageA.shortLabel)", fill: model.activeSlot == 0 ? Palette.ink : .white.opacity(0.6),
                     foreground: model.activeSlot == 0 ? .white : Palette.ink)
                Chip(text: "B · \(model.languageB.shortLabel)", fill: model.activeSlot == 1 ? Palette.ink : .white.opacity(0.6),
                     foreground: model.activeSlot == 1 ? .white : Palette.ink)
                Spacer()
                Button("Switch") { model.activeSlot = 1 - model.activeSlot }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(.white))
                    .foregroundStyle(Palette.ink)
            }
        }
        HStack {
            Text("Recent").font(.system(size: 20, weight: .regular)).foregroundStyle(Palette.ink)
            Spacer()
            Text("\(model.history.count) saved").font(.system(size: 12)).foregroundStyle(Palette.ink.opacity(0.5))
        }
        .padding(.top, 4)
        if model.history.isEmpty {
            Bento {
                Text("Hold fn and say something. Your dictations show up here.")
                    .font(.system(size: 13)).foregroundStyle(Palette.ink.opacity(0.6))
            }
        }
        ForEach(Array(model.history.enumerated()), id: \.element.id) { index, record in
            RecentRow(record: record, highlighted: index == 0)
        }
    }
}

/// A dictation in the Home list: the text, its language, when, and a copy button.
private struct RecentRow: View {
    let record: DictationRecord
    let highlighted: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(record.language)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(highlighted ? .white : Palette.peach))
                .foregroundStyle(Palette.ink)
            VStack(alignment: .leading, spacing: 6) {
                Text(record.text)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    Text(record.date, style: .relative).font(.system(size: 11)).foregroundStyle(Palette.ink.opacity(0.5))
                    Text(String(format: "· %.1fs", record.seconds)).font(.system(size: 11)).foregroundStyle(Palette.ink.opacity(0.5))
                }
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(record.text, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 12, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(highlighted ? .white : Palette.cream))
                    .foregroundStyle(Palette.ink)
            }
            .buttonStyle(.plain)
            .help("Copy")
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(highlighted ? Palette.peach : .white))
    }
}

/// Languages, microphone, model and startup, on one page.
private struct SettingsPage: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        PageTitle(title: "Settings", subtitle: "Languages, microphone, model and startup.")
        SectionHeader(title: "Languages", icon: "globe")
        LanguagesPage(model: model)
        SectionHeader(title: "Microphone", icon: "mic.fill")
        MicrophonePage(model: model)
        SectionHeader(title: "Model", icon: "cpu.fill")
        ModelPage(model: model)
        SectionHeader(title: "Startup", icon: "power")
        HStack(alignment: .top, spacing: 16) {
            Bento(title: "Open at login") {
                Toggle("Open Monty when you log in", isOn: $model.openAtLogin).toggleStyle(.switch).tint(Palette.coral)
            }
            Bento(title: "Your Monty folder") {
                Text("Notes, history and dictionary, all in Documents › Monty Data.")
                    .font(.system(size: 12)).foregroundStyle(Palette.ink.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    MontyFolder.create()
                    NSWorkspace.shared.open(MontyFolder.root)
                } label: {
                    Label("Open folder", systemImage: "folder").font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(Palette.ink)).foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct SectionHeader: View {
    let title: String
    let icon: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Palette.ink)).foregroundStyle(.white)
            Text(title).font(.system(size: 22, weight: .regular)).foregroundStyle(Palette.ink)
        }
        .padding(.top, 14)
    }
}

private struct LanguagesPage: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        HStack(spacing: 16) {
            slot(0, "A", model.languageA) { model.languageA = $0 }
            slot(1, "B", model.languageB) { model.languageB = $0 }
        }
    }

    private func slot(_ index: Int, _ letter: String, _ language: OutputLanguage, set: @escaping (OutputLanguage) -> Void) -> some View {
        let active = model.activeSlot == index
        return Bento(fill: active ? Palette.peach : .white) {
            HStack {
                Text("Language \(letter)").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink.opacity(0.6))
                Spacer()
                if active { Chip(text: "Typing now", fill: Palette.ink) }
            }
            Text(language.label)
                .font(.system(size: 28, weight: .light)).foregroundStyle(Palette.ink)
                .lineLimit(1).minimumScaleFactor(0.6)
            HStack {
                LanguageMenu(current: language, choose: set)
                Spacer()
                if !active {
                    Button("Use this") { model.activeSlot = index }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Capsule().strokeBorder(Palette.ink.opacity(0.3)))
                        .foregroundStyle(Palette.ink)
                }
            }
        }
    }
}

private struct MicrophonePage: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        Bento(title: "Input") {
            ForEach(model.mics) { mic in
                let selected = model.micID == mic.id
                Button { model.micID = mic.id } label: {
                    HStack {
                        Image(systemName: mic.uid == nil ? "gearshape" : "mic.fill").frame(width: 20)
                        Text(mic.name).font(.system(size: 14))
                        Spacer()
                        if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.coral) }
                    }
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(selected ? Palette.peach : Palette.cream))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Button("Refresh list") { model.onRefreshMics?() }
                .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.coral)
        }
        Bento(title: "Keep microphone ready", fill: Palette.pink) {
            Toggle("Start listening instantly, so no word is cut off", isOn: $model.keepMicReady)
                .toggleStyle(.switch).tint(Palette.ink)
            Text("macOS shows the orange microphone dot the whole time this is on. Audio from before you press fn stays in memory for half a second, then it is gone.")
                .font(.system(size: 12)).foregroundStyle(Palette.ink.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ModelPage: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        Bento(title: "Keep Gemma in memory") {
            HStack(spacing: 10) {
                ForEach(ModelMemory.allCases, id: \.self) { m in
                    let selected = model.memory == m
                    Button { model.memory = m } label: {
                        Text(m.label)
                            .font(.system(size: 15, weight: selected ? .semibold : .regular))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(selected ? Palette.peach : Palette.cream))
                            .foregroundStyle(Palette.ink)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("While loaded, Gemma uses 2 to 4 GB of memory and a dictation takes about a second. After it unloads, the first dictation takes about 4.5 seconds.")
                .font(.system(size: 12)).foregroundStyle(Palette.ink.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }
        Bento(title: "Startup", fill: Palette.pink) {
            Toggle("Load Gemma when Monty starts", isOn: $model.loadAtStart).toggleStyle(.switch).tint(Palette.ink)
        }
    }
}

private struct DictionaryPage: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        PageTitle(title: "Dictionary", subtitle: "Names and words Monty should always spell your way.")
        Bento {
            HStack {
                Text("Word").frame(width: 200, alignment: .leading)
                Text("Wrong spellings, comma separated")
                Spacer()
            }
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.ink.opacity(0.5))
            ForEach($model.dictionary) { $row in
                HStack(spacing: 10) {
                    field("Jane Doe", text: $row.word).frame(width: 200)
                    field("Jain Doe, Jane Dough", text: $row.wrong)
                    Button {
                        model.dictionary.removeAll { $0.id == row.id }
                        model.dictionarySaved = false
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(Palette.cream))
                            .foregroundStyle(Palette.ink.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
                .onChange(of: row) { model.dictionarySaved = false }
            }
            HStack {
                Button {
                    model.dictionary.append(.init(word: "", wrong: ""))
                    model.dictionarySaved = false
                } label: {
                    Label("Add word", systemImage: "plus").font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(Palette.peach)).foregroundStyle(Palette.ink)
                }
                .buttonStyle(.plain)
                Spacer()
                Button { model.saveDictionary() } label: {
                    Text(model.dictionarySaved ? "Saved" : "Save").font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .background(Capsule().fill(model.dictionarySaved ? Palette.cream : Palette.ink))
                        .foregroundStyle(model.dictionarySaved ? Palette.ink.opacity(0.4) : .white)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("s")
                .disabled(model.dictionarySaved)
            }
        }
        Text("Wrong spellings are fixed every time, for example \"Jain Doe\" becomes \"Jane Doe\". Changes apply to the next dictation.")
            .font(.system(size: 12)).foregroundStyle(Palette.ink.opacity(0.5))
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.cream))
    }
}

private struct AboutPage: View {
    var body: some View {
        VStack(spacing: 16) {
            AnimatedMonty(mood: .party, size: 140, since: Date())
                .padding(.top, 10)
            Text("Monty").font(.system(size: 40, weight: .bold, design: .rounded)).foregroundStyle(Palette.ink)
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                .font(.system(size: 13)).foregroundStyle(Palette.ink.opacity(0.5))
            Text("A tiny mouse who lives in your notch and types what you say, in your language.")
                .font(.system(size: 15)).multilineTextAlignment(.center).foregroundStyle(Palette.ink.opacity(0.7))
                .frame(maxWidth: 420)
            HStack(spacing: 8) {
                Chip(text: "Free", fill: Palette.peach, foreground: Palette.ink)
                Chip(text: "100% offline", fill: Palette.pink, foreground: Palette.ink)
                Chip(text: "Open source soon", fill: Palette.ink)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: Notes

private struct NotesPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        if let note = model.selectedNote {
            NoteDetail(note: note) { withAnimation(.spring(response: 0.3)) { model.selectedNote = nil } }
        } else {
            list
        }
    }

    /// Notes for the meeting going on right now: start them from this moment, or stop them.
    @ViewBuilder private var liveCard: some View {
        if model.meetingRecording {
            Bento(fill: Palette.ink, dark: true) {
                HStack(spacing: 12) {
                    Circle().fill(Palette.coral).frame(width: 9, height: 9)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Taking notes · \(model.meetingName)").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(MeetingRecorder.clock(context.date.timeIntervalSince(model.meetingStart)))
                                .font(.system(size: 12).monospacedDigit()).foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    Spacer()
                    liveButton("Stop and write notes") { model.onStopNotes?() }
                }
            }
        } else {
            Bento(fill: model.meetingAvailable ? Palette.peach : .white) {
                HStack(spacing: 12) {
                    Image(systemName: model.meetingAvailable ? "video.fill" : "waveform")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(model.meetingAvailable ? .white : Palette.cream))
                        .foregroundStyle(Palette.ink)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.meetingAvailable ? "\(model.meetingName) is on" : "In a call Monty did not notice?")
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink)
                        Text(model.meetingAvailable
                             ? "Take notes from this moment on."
                             : "Start notes anyway: Monty records every app's sound and your microphone from now.")
                            .font(.system(size: 12)).foregroundStyle(Palette.ink.opacity(0.6))
                    }
                    Spacer()
                    liveButton(model.meetingAvailable ? "Take notes from now" : "Start notes anyway") { model.onStartNotes?() }
                }
            }
        }
    }

    private func liveButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .bold))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(Palette.coral)).foregroundStyle(Palette.ink)
        }
        .buttonStyle(.plain)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageTitle(title: "Meeting notes", subtitle: "When a Zoom, Google Meet, Teams or FaceTime call starts, Monty asks on the notch whether to take notes.")
            liveCard
            HStack(alignment: .top, spacing: 16) {
                Bento(title: "Ask when a meeting starts", fill: Palette.peach) {
                    Toggle("Show the notes question on the notch", isOn: $model.askForNotes)
                        .toggleStyle(.switch).tint(Palette.coral)
                }
                Bento(title: "Notes language", fill: Palette.pink) {
                    LanguageMenu(current: model.notesLanguage) { model.notesLanguage = $0 }
                }
                .frame(width: 260)
            }
            if model.notes.isEmpty {
                Bento {
                    Text("No meetings yet. Start a call, and when Monty asks, choose Start notes.")
                        .font(.system(size: 13)).foregroundStyle(Palette.ink.opacity(0.6))
                }
            } else {
                ForEach(model.notes) { note in
                    Button { withAnimation(.spring(response: 0.3)) { model.selectedNote = note } } label: { NoteRow(note: note) }
                        .buttonStyle(.plain)
                }
            }
            Button {
                try? FileManager.default.createDirectory(at: NotesStore.folder, withIntermediateDirectories: true)
                NSWorkspace.shared.open(NotesStore.folder)
            } label: {
                Label("Open notes folder", systemImage: "folder").font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(Palette.ink)).foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
    }
}

private struct NoteRow: View {
    let note: MeetingNote
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "note.text")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.peach))
                .foregroundStyle(Palette.ink)
            VStack(alignment: .leading, spacing: 4) {
                Text(note.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink).lineLimit(1)
                Text(note.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 12)).foregroundStyle(Palette.ink.opacity(0.55))
            }
            Spacer()
            Chip(text: note.app, fill: Palette.pink.opacity(0.35), foreground: Palette.ink)
            if note.duration > 0 {
                Chip(text: "\(max(1, Int(note.duration / 60))) min", fill: Palette.cream, foreground: Palette.ink)
            }
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.ink.opacity(0.35))
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white))
        .contentShape(Rectangle())
    }
}

private struct NoteDetail: View {
    let note: MeetingNote
    let back: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Button(action: back) {
                    Label("All notes", systemImage: "chevron.left").font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Capsule().fill(.white)).foregroundStyle(Palette.ink)
                }
                .buttonStyle(.plain)
                Spacer()
                pill("Copy", icon: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(note.body, forType: .string)
                }
                pill("Show in Finder", icon: "folder") { NSWorkspace.shared.activateFileViewerSelecting([note.id]) }
            }
            HStack(spacing: 8) {
                Chip(text: note.app, fill: Palette.pink, foreground: Palette.ink)
                Chip(text: note.date.formatted(date: .abbreviated, time: .shortened), fill: .white, foreground: Palette.ink)
                if note.duration > 0 { Chip(text: "\(max(1, Int(note.duration / 60))) min", fill: .white, foreground: Palette.ink) }
                if !note.language.isEmpty { Chip(text: note.language, fill: Palette.peach, foreground: Palette.ink) }
            }
            Bento { MarkdownBody(text: note.body) }
        }
    }

    private func pill(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Capsule().fill(Palette.ink)).foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }
}

/// Draws the notes Markdown: headings, bullets, and text with inline bold and italics.
private struct MarkdownBody: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, raw in
                line(String(raw))
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func line(_ raw: String) -> some View {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("# ") {
            Text(inline(String(trimmed.dropFirst(2)))).font(.system(size: 26, weight: .regular)).foregroundStyle(Palette.ink)
        } else if trimmed.hasPrefix("## ") {
            Text(inline(String(trimmed.dropFirst(3)))).font(.system(size: 16, weight: .bold)).foregroundStyle(Palette.ink)
                .padding(.top, 8)
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(Palette.coral).frame(width: 5, height: 5)
                Text(inline(String(trimmed.dropFirst(2)))).font(.system(size: 13)).foregroundStyle(Palette.ink.opacity(0.85))
            }
        } else if trimmed.isEmpty {
            EmptyView()
        } else {
            Text(inline(trimmed)).font(.system(size: 13)).foregroundStyle(Palette.ink.opacity(0.75))
        }
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s)) ?? AttributedString(s)
    }
}
