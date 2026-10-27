import AppKit
import ApplicationServices
import CoreAudio

/// Notices when a meeting starts or ends: another app starts or stops using the
/// microphone. Meeting apps count right away; a browser counts when one of its windows
/// looks like a meeting (Google Meet, Teams, Zoom or Webex on the web).
final class MeetingDetector {
    struct Meeting: Equatable {
        /// What the notch shows, e.g. "Zoom" or "Google Meet".
        let name: String
        /// Bundle id prefix of the app, used to tap its audio (browsers play from helper processes).
        let bundlePrefix: String
        /// Tells one meeting from the next in the same app: the meeting code in a browser
        /// title (Google Meet "abc-defg-hij"), otherwise the app itself.
        var key = ""
    }

    var onStart: ((Meeting) -> Void)?
    var onEnd: (() -> Void)?
    private(set) var current: Meeting?
    /// While notes are being taken, a meeting gets more time before it counts as ended,
    /// so a short gap does not cut the notes. Otherwise it ends quickly, so reopening a
    /// meeting asks again.
    var isRecording = false

    private static let meetingApps: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams2": "Microsoft Teams",
        "com.microsoft.teams": "Microsoft Teams",
        "com.apple.FaceTime": "FaceTime",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.hnc.Discord": "Discord",
        "com.cisco.webexmeetingsapp": "Webex",
        "com.webex.meetingmanager": "Webex",
        "com.skype.skype": "Skype",
    ]
    private static let browsers = [
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "com.microsoft.edgemac",
        "org.mozilla.firefox", "com.brave.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
    ]
    /// Window title hints for meetings in a browser, and the name to show.
    private static let webMeetings: [(hint: String, name: String)] = [
        ("Meet -", "Google Meet"), ("Google Meet", "Google Meet"), ("Microsoft Teams", "Microsoft Teams"),
        ("| Microsoft Teams", "Microsoft Teams"), ("Zoom Meeting", "Zoom"), ("Webex", "Webex"),
    ]

    private var timer: Timer?
    /// What is on right now. Replaceable for the detector self-test.
    lazy var finder: () -> Meeting? = { [unowned self] in self.findMeeting() }
    /// While notes are taken: whether the meeting is still going on, by a looser test than
    /// `finder`. Replaceable for the detector self-test.
    lazy var stillOn: (Meeting) -> Bool = { Self.stillOn($0) }
    private var seenCount = 0
    private var missingCount = 0
    private var candidate: Meeting?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.poll() }
    }

    /// One check; the timer calls it every 3 seconds.
    func poll() {
        let found = finder()
        if let current {
            // Another meeting in the same app (a new Google Meet code): end this one, start that one.
            if let found, found.bundlePrefix == current.bundlePrefix, found.key != current.key, !isRecording {
                Log.write("meeting changed: \(current.key) -> \(found.key)")
                self.current = nil
                missingCount = 0
                onEnd?()
                self.current = found
                Log.write("meeting started: \(found.name)")
                onStart?(found)
                return
            }
            // A meeting ends once the app has let go of the microphone for a while
            // (about 21 seconds while recording, 9 otherwise). While recording it also
            // stays on as long as either sign is there on its own: in a browser the window
            // title is the front tab's, so switching tabs lost it, and muting in Google
            // Meet lets go of the microphone; either one ended the notes mid-meeting.
            if found?.bundlePrefix == current.bundlePrefix || (isRecording && stillOn(current)) {
                missingCount = 0
            } else {
                missingCount += 1
                if missingCount >= (isRecording ? 7 : 3) {
                    Log.write("meeting ended: \(current.name)")
                    self.current = nil
                    missingCount = 0
                    onEnd?()
                }
            }
            return
        }
        // Starts only after it is seen twice in a row, so a short sound check does not count.
        if let found, found == candidate {
            seenCount += 1
            if seenCount >= 2 {
                current = found
                seenCount = 0
                Log.write("meeting started: \(found.name)")
                onStart?(found)
            }
        } else {
            candidate = found
            seenCount = found == nil ? 0 : 1
        }
    }

    /// The meeting app using the microphone right now, if any.
    private func findMeeting() -> Meeting? {
        let myBundle = Bundle.main.bundleIdentifier ?? "com.faheemmehdi.monty"
        for bundle in Self.bundlesUsingMicrophone() where !bundle.hasPrefix(myBundle) {
            if let entry = Self.meetingApps.first(where: { bundle.hasPrefix($0.key) }) {
                return Meeting(name: entry.value, bundlePrefix: entry.key, key: entry.key)
            }
            if let browser = Self.browsers.first(where: { bundle.hasPrefix($0) }),
               let web = Self.webMeeting(inBrowser: browser) {
                return Meeting(name: web.name, bundlePrefix: browser, key: web.key)
            }
        }
        return nil
    }

    /// The meeting app still uses the microphone, or (in a browser) a window still shows it.
    private static func stillOn(_ meeting: Meeting) -> Bool {
        if bundlesUsingMicrophone().contains(where: { $0.hasPrefix(meeting.bundlePrefix) }) { return true }
        return browsers.contains(meeting.bundlePrefix) && webMeeting(inBrowser: meeting.bundlePrefix) != nil
    }

    /// The meeting a browser window shows, if any: its name and a key for this meeting.
    private static func webMeeting(inBrowser bundleID: String) -> (name: String, key: String)? {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            var windows: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windows) == .success,
                  let list = windows as? [AXUIElement] else { continue }
            for window in list {
                var title: CFTypeRef?
                AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
                guard let text = title as? String else { continue }
                if let match = webMeetings.first(where: { text.contains($0.hint) }) {
                    // Google Meet codes look like abc-defg-hij.
                    let code = text.range(of: "[a-z]{3}-[a-z]{4}-[a-z]{3}", options: .regularExpression).map { String(text[$0]) }
                    return (match.name, code ?? match.name)
                }
            }
        }
        return nil
    }

    // MARK: Core Audio process list

    /// Bundle ids of the processes recording from any input device right now.
    static func bundlesUsingMicrophone() -> [String] {
        processObjects().compactMap { object in
            guard uint32(object, kAudioProcessPropertyIsRunningInput) == 1 else { return nil }
            return string(object, kAudioProcessPropertyBundleID)
        }
    }

    /// Core Audio process objects whose bundle id starts with `prefix`, to tap their audio.
    static func processObjects(bundlePrefix prefix: String) -> [AudioObjectID] {
        processObjects().filter { string($0, kAudioProcessPropertyBundleID)?.hasPrefix(prefix) == true }
    }

    private static func processObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
