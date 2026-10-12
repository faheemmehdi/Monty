import AppKit
import SwiftUI

/// A black island that grows out of the MacBook notch, like the iPhone Dynamic Island.
///
/// While dictating it shows the mode and a live voice meter. When idle, moving the
/// mouse into the notch opens it into a small panel: status, the output language
/// toggle and the last dictation. On screens without a notch it sits at the top center.
final class NotchIndicator {
    enum Phase: Equatable {
        case hidden
        case recording(OutputLanguage)
        case processing
        case done
        case copied  // no text field had focus, so the text is on the clipboard
        case modeChanged(OutputLanguage)  // Fn + Shift switched the output language
        case failed
    }

    let model = IndicatorModel()
    var onSelectMode: ((OutputLanguage) -> Void)? {
        get { model.onSelectMode }
        set { model.onSelectMode = newValue }
    }

    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private var hoverWork: DispatchWorkItem?
    private var monitors: [Any] = []
    private var screenFrame = NSRect.zero

    func show(_ phase: Phase) {
        hideWork?.cancel()
        ensurePanel()
        Log.write("indicator: \(phase)")
        if case .recording = phase {
            model.levels = Array(repeating: 0, count: IndicatorModel.barCount)
        }
        if phase != model.phase { model.phaseStart = Date() }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { model.phase = phase }
        updateMouseHandling()

        // Finished states linger briefly, then the island shrinks back into the notch.
        let linger: Double? = switch phase {
        case .done: 0.9
        case .copied: 1.8
        case .modeChanged: 1.2
        case .failed: 1.6
        default: nil
        }
        if let linger {
            let work = DispatchWorkItem { [weak self] in self?.show(.hidden) }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + linger, execute: work)
        }
    }

    /// Audio level from 0 to 1, called many times per second while recording.
    func push(level: Float) {
        guard case .recording = model.phase else { return }
        var levels = model.levels
        levels.removeFirst()
        levels.append(CGFloat(level))
        model.levels = levels
    }

    /// Creates the island window and starts watching the mouse, once.
    func ensurePanel() {
        guard panel == nil else { return }
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
        let geometry = NotchGeometry(screen: screen)
        model.geometry = geometry
        screenFrame = screen.frame

        let size = geometry.panelSize
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
            width: size.width, height: size.height
        )
        // Non-activating, so clicking it never takes focus away from the text field.
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)  // above the menu bar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = ClickThroughHostingView(rootView: IslandView(model: model))
        panel.orderFrontRegardless()
        self.panel = panel


        let moved: (NSEvent) -> Void = { [weak self] _ in self?.mouseMoved() }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: moved) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { moved($0); return $0 }) {
            monitors.append(m)
        }
    }

    // MARK: Hover

    private func mouseMoved() {
        let point = NSEvent.mouseLocation
        let g = model.geometry
        let top = screenFrame.maxY
        let notch = NSRect(x: screenFrame.midX - g.hoverWidth / 2, y: top - g.height, width: g.hoverWidth, height: g.height)
        let openHeight = g.expandedSize.height + NotchGeometry.meetingRow
        let open = NSRect(
            x: screenFrame.midX - g.expandedSize.width / 2, y: top - openHeight,
            width: g.expandedSize.width, height: openHeight
        ).insetBy(dx: -10, dy: -10)

        if !model.hovering {
            guard notch.contains(point) else {
                hoverWork?.cancel()
                hoverWork = nil
                return
            }
            // A short pause first, so passing through the menu bar does not open it.
            guard hoverWork == nil else { return }
            schedule(after: 0.15) { [weak self] in self?.setHovering(true) }
        } else if open.contains(point) {
            hoverWork?.cancel()
            hoverWork = nil
        } else if hoverWork == nil {
            schedule(after: 0.25) { [weak self] in self?.setHovering(false) }
        }
    }

    private func schedule(after delay: Double, _ action: @escaping () -> Void) {
        let work = DispatchWorkItem { [weak self] in
            self?.hoverWork = nil
            action()
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func setHovering(_ hovering: Bool) {
        guard model.hovering != hovering else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.78)) { model.hovering = hovering }
        updateMouseHandling()
    }

    /// Clicks reach the island only while it is open as a panel; otherwise they pass
    /// through to the menu bar and the windows underneath.
    private func updateMouseHandling() {
        panel?.ignoresMouseEvents = !model.isInteractive
    }

    /// Meeting notes: asking, recording, writing, saved, or nil when there is no meeting.
    func setMeeting(_ state: IndicatorModel.MeetingState?) {
        ensurePanel()
        Log.write("meeting indicator: \(state.map { "\($0)" } ?? "none")")
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { model.meetingState = state }
        if state == .recording { model.meetingStart = Date() }
        updateMouseHandling()
    }
}

/// Lets a click on the island work at once, without first having to focus its window.
private final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct NotchGeometry {
    static let wing: CGFloat = 78  // how far the recording island extends past each side of the notch

    var notchWidth: CGFloat = 0
    var height: CGFloat = 32

    init() {}

    init(screen: NSScreen) {
        let top = screen.safeAreaInsets.top
        if top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchWidth = screen.frame.width - left.width - right.width
            height = top
        } else {
            notchWidth = 0
            height = NSStatusBar.system.thickness
        }
    }

    /// The area at the top center that opens the panel when the mouse rests on it.
    var hoverWidth: CGFloat { notchWidth > 0 ? notchWidth : 200 }
    var compactWidth: CGFloat { notchWidth + 2 * Self.wing }
    // Top band, language toggle, last dictation and the hint line, with their spacing.
    var expandedSize: CGSize { CGSize(width: max(notchWidth + 220, 400), height: height + 152) }
    /// Extra height of the hover panel while meeting notes are being taken (the Stop row).
    static let meetingRow: CGFloat = 44
    /// The "take notes?" card when a meeting starts.
    var promptSize: CGSize { CGSize(width: max(notchWidth + 220, 400), height: height + 80) }
    var panelSize: CGSize { CGSize(width: expandedSize.width + 24, height: expandedSize.height + Self.meetingRow + 12) }
}

final class IndicatorModel: ObservableObject {
    static let barCount = 9
    @Published var phase = NotchIndicator.Phase.hidden
    @Published var levels = Array(repeating: CGFloat(0), count: barCount)
    @Published var hovering = false
    @Published var mode = OutputLanguage.english
    /// Languages A and B, switched with Fn + Shift.
    @Published var slots: [OutputLanguage] = [.english, .romanUrdu]
    @Published var status = "Ready"
    @Published var isHealthy = true
    @Published var lastText: String?
    @Published var micName = "System Default"
    @Published var justCopied = false  // brief checkmark on the copy button
    @Published var handsFree = false  // recording continues with no key held
    @Published var keepMicReady = false
    /// Seconds from releasing Fn to the text being written, shown next to the checkmark.
    @Published var responseSeconds: Double?
    /// When the current phase started, so Monty's animation for it plays from the start.
    @Published var phaseStart = Date()
    @Published var memory = ModelMemory.thirtyMinutes
    var geometry = NotchGeometry()
    var onSelectMode: ((OutputLanguage) -> Void)?
    /// Opens the language list for slot 0 (A) or 1 (B).
    var onPickLanguage: ((Int) -> Void)?
    var onOpenSettings: (() -> Void)?
    var onToggleMicReady: (() -> Void)?
    var onCycleMemory: (() -> Void)?
    var onCycleMic: (() -> Void)?

    // MARK: Meeting notes
    enum MeetingState: Equatable { case prompt, recording, writing, saved }
    @Published var meetingState: MeetingState?
    @Published var meetingName = ""
    @Published var meetingStart = Date()
    @Published var notesLanguage = OutputLanguage.english
    @Published var meetingLevel: CGFloat = 0
    /// A meeting is on but notes were declined; the hover panel still offers them.
    @Published var meetingAvailable = false
    var onStartNotes: (() -> Void)?
    var onDismissMeeting: (() -> Void)?
    var onStopNotes: (() -> Void)?
    var onPickNotesLanguage: (() -> Void)?

    /// Open as the hover panel: only when idle, a dictation always takes over the island.
    var isExpanded: Bool { hovering && phase == .hidden && meetingState != .prompt }
    var isMeetingPrompt: Bool { meetingState == .prompt && phase == .hidden }
    /// The small island that says notes are being taken, between dictations.
    var showsMeetingCompact: Bool {
        phase == .hidden && !isExpanded && (meetingState == .recording || meetingState == .writing || meetingState == .saved)
    }
    /// Whether clicks should reach the island.
    var isInteractive: Bool { isExpanded || isMeetingPrompt }
}

private struct IslandView: View {
    @ObservedObject var model: IndicatorModel

    private var isOpen: Bool { model.phase != .hidden }

    var body: some View {
        let g = model.geometry
        let meetingRow: CGFloat = model.meetingState == .recording || (model.meetingAvailable && model.meetingState == nil)
            ? NotchGeometry.meetingRow : 0
        let size: CGSize = model.isExpanded
            ? CGSize(width: g.expandedSize.width, height: g.expandedSize.height + meetingRow)
            : model.isMeetingPrompt ? g.promptSize
            : CGSize(width: isOpen || model.showsMeetingCompact ? g.compactWidth : max(g.notchWidth, 1), height: g.height)
        let radius: CGFloat = model.isExpanded || model.isMeetingPrompt ? 24 : 14

        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius, style: .continuous)
                    .fill(Color.black)
                    .shadow(color: .black.opacity(model.isExpanded ? 0.35 : 0), radius: 12, y: 6)
                if model.isExpanded {
                    ExpandedPanel(model: model)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                } else if model.isMeetingPrompt {
                    MeetingPrompt(model: model)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                } else if model.showsMeetingCompact {
                    meetingCompact
                } else {
                    compact.opacity(isOpen ? 1 : 0)
                }
            }
            // Pinned to the top: content taller than the island grows downward instead of
            // being centered, which would push Monty up past the top of the screen.
            .frame(width: size.width, height: size.height, alignment: .top)
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius, style: .continuous))
            // Fade out fully when closed, rather than relying on matching the notch exactly.
            .opacity(isOpen || model.isExpanded || model.isMeetingPrompt || model.showsMeetingCompact ? 1 : 0)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// While notes are being taken: Monty listening and the time so far.
    private var meetingCompact: some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                switch model.meetingState {
                case .writing: AnimatedMonty(mood: .nibbling, size: 27, since: model.meetingStart)
                case .saved: AnimatedMonty(mood: .party, size: 27, since: model.phaseStart)
                default: AnimatedMonty(mood: .listening, size: 27, since: model.meetingStart, level: model.meetingLevel)
                }
                Text(model.meetingState == .saved ? "Saved" : "Notes")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .fixedSize()
            }
            .frame(width: NotchGeometry.wing, alignment: .leading)
            .padding(.leading, 12)
            Spacer(minLength: model.geometry.notchWidth)
            Group {
                switch model.meetingState {
                case .writing:
                    Text("Writing…").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.8))
                case .saved:
                    Image(systemName: "doc.text.fill").font(.system(size: 14)).foregroundStyle(.white)
                default:
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        HStack(spacing: 5) {
                            Circle().fill(Color.red).frame(width: 7, height: 7)
                                .opacity(Int(context.date.timeIntervalSince1970) % 2 == 0 ? 1 : 0.35)
                            Text(MeetingRecorder.clock(context.date.timeIntervalSince(model.meetingStart)))
                                .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                                .foregroundStyle(.white)
                        }
                    }
                }
            }
            .frame(width: NotchGeometry.wing)
        }
        .frame(height: model.geometry.height)
    }

    private var compact: some View {
        HStack(spacing: 0) {
            leading.frame(width: NotchGeometry.wing)
            Spacer(minLength: model.geometry.notchWidth)
            trailing.frame(width: NotchGeometry.wing)
        }
        .frame(height: model.geometry.height)
    }

    /// Monty sits in the left wing and slides out from under the notch when the island opens.
    private var leading: some View {
        HStack(spacing: 5) {
            if isOpen {
                monty
                    .transition(.offset(x: 34).combined(with: .opacity))
            }
            leadingLabel
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 12)
    }

    private var mood: MontyMood {
        switch model.phase {
        case .hidden: return .sleeping
        case .recording: return .listening
        case .processing: return .nibbling
        case .done: return .party
        case .copied: return .happy
        case .modeChanged: return .wink
        case .failed: return .confused
        }
    }

    /// Animated only while the island is open; when it is closed Monty is not drawn at all.
    private var monty: some View {
        AnimatedMonty(mood: mood, size: 27, since: model.phaseStart, level: model.levels.last ?? 0)
    }

    @ViewBuilder private var leadingLabel: some View {
        switch model.phase {
        case .recording(let mode):
            HStack(spacing: 3) {
                if model.handsFree {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.orange)
                        .transition(.scale.combined(with: .opacity))
                }
                Text(mode.shortLabel)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
        case .modeChanged(let mode):
            Text(mode.shortLabel)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        case .copied:
            Text("Copied")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var trailing: some View {
        switch model.phase {
        case .recording:
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(Array(model.levels.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(Color.white)
                        .frame(width: 3, height: 4 + level * 16)
                }
            }
            .animation(.easeOut(duration: 0.08), value: model.levels)
        case .processing:
            // Three bouncing dots; the system spinner draws dark on the black island.
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                HStack(spacing: 4) {
                    ForEach(0..<3) { i in
                        Circle()
                            .fill(Color.white)
                            .frame(width: 5, height: 5)
                            .offset(y: -3 * max(0, sin(t * 7 - Double(i) * 0.9)))
                    }
                }
            }
        case .done:
            HStack(spacing: 5) {
                if let seconds = model.responseSeconds {
                    Text(String(format: "%.1fs", seconds))
                        .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                }
                Image(systemName: "checkmark.circle.fill").font(.system(size: 16)).foregroundStyle(.green)
            }
        case .modeChanged(let mode):
            Text(mode.label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        case .copied:
            Image(systemName: "doc.on.clipboard.fill").font(.system(size: 14)).foregroundStyle(.white)
        case .failed:
            Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundStyle(.red)
        case .hidden:
            Color.clear
        }
    }
}

/// The panel shown while the mouse rests on the notch.
private struct ExpandedPanel: View {
    @ObservedObject var model: IndicatorModel
    @Namespace private var modeSelection

    var body: some View {
        let g = model.geometry
        VStack(alignment: .leading, spacing: 12) {
            // The top band sits beside the notch, so its two halves go left and right of it.
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    AnimatedMonty(mood: .awake, size: 22, since: model.phaseStart)
                    Text("Monty").font(.system(size: 13, weight: .semibold, design: .rounded))
                }
                Spacer(minLength: g.notchWidth + 12)
                HStack(spacing: 5) {
                    Circle().fill(model.isHealthy ? Color.green : Color.orange).frame(width: 7, height: 7)
                    Text(model.isHealthy ? "Ready" : "Check")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                    Button { model.onOpenSettings?() } label: {
                        Image(systemName: "gearshape.fill").font(.system(size: 12))
                            .frame(width: 20, height: 20).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Settings")
                }
                .help(model.status)
            }
            .frame(height: g.height)
            .foregroundStyle(.white)

            if model.meetingState == .recording { meetingRow } else if model.meetingAvailable && model.meetingState == nil { offerRow }

            modeToggle

            lastDictation

            Label("Hold fn to talk · tap twice for hands-free · fn ⇧ language · ⚙︎ for settings", systemImage: "globe")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
    }

    private var meetingRow: some View {
        HStack(spacing: 8) {
            Circle().fill(Color.red).frame(width: 7, height: 7)
            Text("Taking notes · \(model.meetingName)")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Spacer()
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(MeetingRecorder.clock(context.date.timeIntervalSince(model.meetingStart)))
                    .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }
            Button { model.onStopNotes?() } label: {
                Text("Stop").font(.system(size: 12, weight: .bold, design: .rounded))
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Capsule().fill(Color(red: 1, green: 0.478, blue: 0.604)))
                    .foregroundStyle(.black)
            }
            .buttonStyle(.plain)
        }
        .frame(height: NotchGeometry.meetingRow - 12)
    }

    /// After "Not now": the meeting is still on, notes can still be started.
    private var offerRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "video.fill").font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
            Text("\(model.meetingName) in progress")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Spacer()
            Button { model.onStartNotes?() } label: {
                Text("Take notes").font(.system(size: 12, weight: .bold, design: .rounded))
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Capsule().fill(Color(red: 1, green: 0.478, blue: 0.604)))
                    .foregroundStyle(.black)
            }
            .buttonStyle(.plain)
        }
        .frame(height: NotchGeometry.meetingRow - 12)
    }

    /// Languages A and B: click a name to use it, click its arrow to pick another language.
    private var modeToggle: some View {
        HStack(spacing: 4) {
            ForEach(Array(model.slots.enumerated()), id: \.offset) { slot, language in
                let selected = model.mode == language
                HStack(spacing: 2) {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { model.mode = language }
                        model.onSelectMode?(language)
                    } label: {
                        Text(language.label)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Button {
                        model.onPickLanguage?(slot)
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Choose language \(slot == 0 ? "A" : "B")")
                }
                .foregroundStyle(selected ? Color.black : Color.white.opacity(0.75))
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity)
                .background {
                    if selected {
                        Capsule().fill(Color.white).matchedGeometryEffect(id: "selected", in: modeSelection)
                    }
                }
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.white.opacity(0.12)))
    }

    private var lastDictation: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(model.lastText ?? "Your last dictation will show up here.")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(.white.opacity(model.lastText == nil ? 0.4 : 0.85))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let text = model.lastText {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    withAnimation { model.justCopied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [model] in withAnimation { model.justCopied = false } }
                } label: {
                    Image(systemName: model.justCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(model.justCopied ? Color.green : Color.white.opacity(0.8))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .help("Copy")
            }
        }
        .padding(10)
        .frame(height: 52, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.08)))
    }
}

/// Shown when a meeting starts: take notes, in which language, or not.
private struct MeetingPrompt: View {
    @ObservedObject var model: IndicatorModel

    var body: some View {
        let g = model.geometry
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    AnimatedMonty(mood: .awake, size: 22, since: model.phaseStart)
                    Text(model.meetingName).font(.system(size: 13, weight: .semibold, design: .rounded)).lineLimit(1)
                }
                Spacer(minLength: g.notchWidth + 12)
                Text("Take notes?").font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            .frame(height: g.height)
            .foregroundStyle(.white)

            HStack(spacing: 8) {
                Button { model.onPickNotesLanguage?() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "globe").font(.system(size: 10, weight: .semibold))
                        Text(model.notesLanguage.label).font(.system(size: 12, weight: .semibold, design: .rounded)).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .help("Language of the notes")
                Spacer()
                Button { model.onDismissMeeting?() } label: {
                    Text("Not now").font(.system(size: 12, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                Button { model.onStartNotes?() } label: {
                    Text("Start notes").font(.system(size: 12, weight: .bold, design: .rounded))
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Capsule().fill(Color(red: 1, green: 0.478, blue: 0.604)))
                        .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
            }
            Text("Let everyone know you are taking notes.")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
    }
}
