import AppKit
import ApplicationServices

/// Finds out, through the Accessibility API, whether the focused element can take typed text.
enum FocusDetector {
    private static let textRoles: Set<String> = [
        kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField",
    ]

    enum Answer {
        case text
        case notText
        /// The app did not say what has focus. Some apps (the ChatGPT app, for one) answer
        /// nothing at first, even with a text box in focus.
        case unknown
    }

    static func focusedElementAcceptsText() -> Answer {
        // Chrome and Electron apps (Slack, VS Code, ...) only expose their text fields
        // once an assistive app asks for it.
        let app = NSWorkspace.shared.frontmostApplication
        var appElement: AXUIElement?
        if let app {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            appElement = element
        }

        guard let element = focusedElement(appElement) else {
            Log.write("focus: no focused element in \(app?.bundleIdentifier ?? "?")")
            return .unknown
        }

        let role = stringAttribute(element, kAXRoleAttribute) ?? "?"
        if textRoles.contains(role) {
            Log.write("focus: \(role)")
            return .text
        }
        // Rich editors (web pages, documents) often use other roles but still have a
        // text cursor, which shows up as a selected text range.
        var range: CFTypeRef?
        let hasCursor = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        Log.write("focus: \(role), cursor \(hasCursor), editable \(settable.boolValue)")
        return hasCursor || settable.boolValue ? .text : .notText
    }

    /// The focused element: asked of the whole system first, then of the front app itself,
    /// a few times, as an app that was just asked to expose its fields may take a moment.
    private static func focusedElement(_ app: AXUIElement?) -> AXUIElement? {
        func focused(in element: AXUIElement) -> AXUIElement? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &value) == .success,
                  let value, CFGetTypeID(value) == AXUIElementGetTypeID()
            else { return nil }
            return (value as! AXUIElement)
        }
        if let element = focused(in: AXUIElementCreateSystemWide()) { return element }
        guard let app else { return nil }
        for attempt in 0..<3 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.08) }
            if let element = focused(in: app) { return element }
        }
        return nil
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
