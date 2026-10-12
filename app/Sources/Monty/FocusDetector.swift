import AppKit
import ApplicationServices

/// Finds out, through the Accessibility API, whether the focused element can take typed text.
enum FocusDetector {
    private static let textRoles: Set<String> = [
        kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField",
    ]

    static func focusedElementAcceptsText() -> Bool {
        // Chrome and Electron apps (Slack, VS Code, ...) only expose their text fields
        // once an assistive app asks for it.
        if let app = NSWorkspace.shared.frontmostApplication {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }

        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else {
            Log.write("focus: no focused element")
            return false
        }
        let element = focused as! AXUIElement

        let role = stringAttribute(element, kAXRoleAttribute) ?? "?"
        if textRoles.contains(role) {
            Log.write("focus: \(role)")
            return true
        }
        // Rich editors (web pages, documents) often use other roles but still have a
        // text cursor, which shows up as a selected text range.
        var range: CFTypeRef?
        let hasCursor = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        Log.write("focus: \(role), cursor \(hasCursor), editable \(settable.boolValue)")
        return hasCursor || settable.boolValue
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
