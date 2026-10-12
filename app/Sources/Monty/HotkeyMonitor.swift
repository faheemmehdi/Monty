import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Watches the Fn (Globe) key system-wide. Needs Accessibility.
///
/// - Hold Fn: dictate while held, release to finish.
/// - Double-tap Fn: hands-free, keeps listening with no key held. Press Fn again to
///   finish, or Esc to throw it away.
/// - Fn + Shift: switches the output language (English <-> Roman Urdu).
/// - Fn together with another key (Fn + arrow, Fn + F1, ...) cancels and works as usual.
final class HotkeyMonitor {
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?
    /// A double-tap turned the running dictation into hands-free.
    var onHandsFree: (() -> Void)?
    /// Fn + Shift: switch the output language.
    var onToggleMode: (() -> Void)?

    /// Recent Macs also send the Globe key as its own key press, next to the Fn flag change.
    private static let globeKeyCode: Int64 = 179
    private static let fnKeyCodes: Set<Int64> = [Int64(kVK_Function), globeKeyCode]
    /// A press shorter than this is a tap, not a hold.
    private static let tapLength: TimeInterval = 0.3
    /// The second tap has to come this soon after the first.
    private static let doubleTapGap: TimeInterval = 0.4
    /// Hands-free stops by itself after this long, in case it was left on by mistake.
    private static let handsFreeLimit: TimeInterval = 5 * 60

    private var tap: CFMachPort?
    private var fnDown = false
    private var dictating = false
    private var handsFree = false
    // Times come from the key events themselves (nanoseconds since startup), not from the
    // clock when the event is handled: starting the microphone blocks for a quarter second,
    // which would make a quick tap look like a hold.
    private var pressStart: UInt64 = 0
    private var lastTapEnd: UInt64?
    private var pressIsSecondTap = false
    private var swallowNextFnUp = false
    private var watchdog: Timer?
    private var handsFreeTimer: Timer?

    var isRunning: Bool { tap != nil }

    /// Whether Fn is down on the keyboard right now. Replaceable for the gesture self-test.
    var isFnPhysicallyHeld: () -> Bool = { CGEventSource.flagsState(.hidSystemState).contains(.maskSecondaryFn) }

    /// Feeds an event as if it came from the keyboard, for the gesture self-test.
    func simulate(_ type: CGEventType, _ event: CGEvent) -> Bool { handle(type, event) != nil }

    /// Returns false when the tap cannot be created, which means Accessibility is not granted yet.
    func start() -> Bool {
        if tap != nil { return true }
        let types: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        Log.write("hotkey tap started")
        return true
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        // macOS switches a tap off if a callback is ever too slow; switch it back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Log.write("tap was disabled (\(type.rawValue)), re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }

        let key = event.getIntegerValueField(.keyboardEventKeycode)

        switch type {
        case .flagsChanged:
            // Shift pressed while Fn is held: switch the language instead of dictating.
            if key == Int64(kVK_Shift) || key == Int64(kVK_RightShift) {
                if event.flags.contains(.maskShift), fnDown, dictating, !handsFree {
                    Log.write("fn + shift: switch language")
                    end(cancelled: true)
                    toggleMode()
                }
                return pass  // Shift itself stays visible to other apps, it does nothing on its own
            }
            guard key == Int64(kVK_Function) else { return pass }
            let isDown = event.flags.contains(.maskSecondaryFn)
            guard isDown != fnDown else { return pass }
            fnDown = isDown
            Log.write("fn \(isDown ? "down" : "up") at \(Self.nanoseconds(event) / 1_000_000) ms")
            if isDown {
                // Not with Command, Option or Control: those are other shortcuts.
                guard event.flags.isDisjoint(with: [.maskCommand, .maskControl, .maskAlternate]) else {
                    return pass
                }
                // Shift held first, then Fn: switch the language.
                if event.flags.contains(.maskShift), !handsFree {
                    Log.write("shift + fn: switch language")
                    toggleMode()
                    return nil
                }
                fnPressed(at: Self.nanoseconds(event))
            } else {
                fnReleased(at: Self.nanoseconds(event))
            }
            // Swallowed, so macOS does not also open the emoji picker or switch input source.
            return nil

        case .keyDown, .keyUp:
            // The Globe key's own key events belong to Fn: swallow them, never cancel on them.
            if Self.fnKeyCodes.contains(key) { return nil }
            guard type == .keyDown, dictating else { return pass }
            if handsFree {
                guard key == Int64(kVK_Escape) else { return pass }  // typing during hands-free is fine
                Log.write("esc: cancel hands-free")
                end(cancelled: true)
                return nil
            }
            // Another key while Fn is held: the user wanted a normal Fn shortcut.
            Log.write("key \(key) pressed while fn held: cancel")
            end(cancelled: true)
            return pass

        default:
            return pass
        }
    }

    // MARK: Gestures

    private func fnPressed(at time: UInt64) {
        if handsFree {
            // Fn again finishes hands-free. Its release is part of this press, not a new one.
            swallowNextFnUp = true
            end(cancelled: false)
            return
        }
        pressIsSecondTap = lastTapEnd.map { Self.seconds(from: $0, to: time) < Self.doubleTapGap } ?? false
        lastTapEnd = nil
        pressStart = time
        // Start at once: a hold should not wait to find out whether a double-tap is coming.
        begin()
    }

    private func fnReleased(at time: UInt64) {
        if swallowNextFnUp {
            swallowNextFnUp = false
            return
        }
        guard dictating, !handsFree else { return }
        if Self.seconds(from: pressStart, to: time) < Self.tapLength {
            if pressIsSecondTap {
                startHandsFree()
            } else {
                // A single tap: maybe the first half of a double-tap. Drop it quietly.
                lastTapEnd = time
                end(cancelled: true)
            }
        } else {
            end(cancelled: false)
        }
    }

    /// An event's time in nanoseconds since startup. The timestamp is documented as
    /// nanoseconds, but can be in mach ticks, which differ on Apple silicon; the event just
    /// happened, so whichever reading is closer to the current time is the right one.
    private static func nanoseconds(_ event: CGEvent) -> UInt64 {
        let stamp = event.timestamp
        let nowNanos = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let nowTicks = mach_absolute_time()
        let distance = { (a: UInt64, b: UInt64) in a > b ? a - b : b - a }
        guard distance(stamp, nowTicks) < distance(stamp, nowNanos) else { return stamp }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return stamp * UInt64(timebase.numer) / UInt64(timebase.denom)
    }

    private static func seconds(from start: UInt64, to end: UInt64) -> TimeInterval {
        end > start ? TimeInterval(end - start) / 1e9 : 0
    }

    private func toggleMode() {
        swallowNextFnUp = true  // this Fn press is used up
        lastTapEnd = nil        // and does not count as the first tap of a double-tap
        DispatchQueue.main.async { self.onToggleMode?() }
    }

    private func startHandsFree() {
        handsFree = true
        watchdog?.invalidate()
        watchdog = nil
        handsFreeTimer = Timer.scheduledTimer(withTimeInterval: Self.handsFreeLimit, repeats: false) { [weak self] _ in
            Log.write("hands-free time limit reached")
            self?.end(cancelled: false)
        }
        Log.write("hands-free on")
        DispatchQueue.main.async { self.onHandsFree?() }
    }

    private func begin() {
        dictating = true
        // Checks the real key state, in case the Fn release event never reaches the tap.
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, self.dictating, !self.handsFree else { return }
            if !self.isFnPhysicallyHeld() {
                Log.write("watchdog: fn no longer held")
                self.fnDown = false
                self.fnReleased(at: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
            }
        }
        // Do the work after returning, so the tap callback stays fast.
        DispatchQueue.main.async { self.onStart?() }
    }

    private func end(cancelled: Bool) {
        guard dictating else { return }
        dictating = false
        handsFree = false
        watchdog?.invalidate()
        watchdog = nil
        handsFreeTimer?.invalidate()
        handsFreeTimer = nil
        DispatchQueue.main.async { cancelled ? self.onCancel?() : self.onStop?() }
    }
}

private func hotkeyCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
    return monitor.handle(type, event)
}
