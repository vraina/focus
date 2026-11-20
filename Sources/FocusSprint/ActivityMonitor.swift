import AppKit
import FocusSprintCore

/// Answers "what is in front of the user right now?": the frontmost app, its window title,
/// and for browsers the URL of the active tab.
@MainActor
final class ActivityMonitor {
    /// Bundle id -> AppleScript expression for the active tab's URL ("" = browser without scripting support).
    static let browsers: [String: String] = [
        "com.apple.Safari": "URL of current tab of front window",
        "com.apple.SafariTechnologyPreview": "URL of current tab of front window",
        "com.google.Chrome": "URL of active tab of front window",
        "com.google.Chrome.canary": "URL of active tab of front window",
        "com.brave.Browser": "URL of active tab of front window",
        "com.microsoft.edgemac": "URL of active tab of front window",
        "company.thebrowser.Browser": "URL of active tab of front window",
        "com.vivaldi.Vivaldi": "URL of active tab of front window",
        "com.operasoftware.Opera": "URL of active tab of front window",
        "org.mozilla.firefox": "",
        "app.zen-browser.zen": "",
        "com.duckduckgo.macos.browser": "",
    ]

    private var scripts: [String: NSAppleScript] = [:]
    private(set) var frontDisplay: CGDirectDisplayID = CGMainDisplayID()

    func current() -> ActivityContext? {
        Timing.measure("read front app and tab") { readCurrent() }
    }

    private func readCurrent() -> ActivityContext? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let bundleId = app.bundleIdentifier ?? "pid.\(app.processIdentifier)"
        let name = app.localizedName ?? bundleId
        let isSelf = app.processIdentifier == ProcessInfo.processInfo.processIdentifier
        let title = isSelf ? "" : frontWindowTitle(pid: app.processIdentifier)
        let expression = ActivityMonitor.browsers[bundleId]
        var url: String?
        if let expression, !expression.isEmpty { url = tabURL(bundleId: bundleId, expression: expression) }
        return ActivityContext(bundleId: bundleId, appName: name, title: title, url: url,
                               isBrowser: expression != nil, isSelf: isSelf)
    }

    /// Window titles are only returned once Screen Recording permission is granted.
    private func frontWindowTitle(pid: pid_t) -> String {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return "" }
        for window in list {
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (window[kCGWindowLayer as String] as? Int) == 0 else { continue }
            if let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
               let x = bounds["X"], let y = bounds["Y"], let w = bounds["Width"], let h = bounds["Height"] {
                var display: CGDirectDisplayID = 0
                var count: UInt32 = 0
                if CGGetDisplaysWithPoint(CGPoint(x: x + w / 2, y: y + h / 2), 1, &display, &count) == .success, count > 0 {
                    frontDisplay = display
                }
            }
            return (window[kCGWindowName as String] as? String) ?? ""
        }
        return ""
    }

    private func tabURL(bundleId: String, expression: String) -> String? {
        let script: NSAppleScript
        if let cached = scripts[bundleId] {
            script = cached
        } else {
            let source = """
            with timeout of 1 seconds
                tell application id "\(bundleId)"
                    if (count of windows) is 0 then return ""
                    return \(expression)
                end tell
            end timeout
            """
            guard let made = NSAppleScript(source: source) else { return nil }
            scripts[bundleId] = made
            script = made
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if error != nil { return nil } // not permitted, or a window without tabs: caller falls back to the title
        return result.stringValue ?? ""
    }
}
