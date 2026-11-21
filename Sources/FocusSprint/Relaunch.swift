import AppKit
import FocusSprintCore

/// Closing and reopening the app, which macOS requires before a newly granted permission takes effect.
enum AppRelaunch {
    /// True for the copy the installer put in Applications (started and kept running by the system).
    static var isInstalledCopy: Bool { Bundle.main.bundlePath.hasPrefix("/Applications/") }

    /// True for the copy the system starts at login and restarts whenever it exits.
    static var startedBySystem: Bool { ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == "com.focussprint.app" }

    /// Only one copy of the installed app may run in a login. The system keeps one running; when macOS or a person
    /// opens a second (System Settings' "Quit & Reopen" does exactly that), the system's copy stays and the other leaves.
    /// Returns true when this copy should exit.
    static func yieldToOtherCopy() -> Bool {
        guard isInstalledCopy, let id = Bundle.main.bundleIdentifier else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != me && $0.bundleURL?.path == Bundle.main.bundlePath }
        if others.isEmpty { return false }
        if startedBySystem { others.forEach { $0.terminate() }; return false }
        others.first?.activate() // bring the copy that stays to the front
        return true
    }

    /// Set while the app is closing only so that it can come straight back (after a permission change).
    static var restarting = false

    /// A household admin or co-admin may quit the app and have it stay closed until they open it again.
    /// The service sends the kids' app list only to them, which is how this Mac knows who they are.
    /// Everyone else's copy is reopened by the system, as before.
    static var mayStayClosed: Bool { AppList.load().kids != nil }

    /// Called as the app closes. The system reopens the installed app after any exit that is not a clean
    /// one, so this ends with an error code unless an admin chose to quit.
    static func leave() {
        if startedBySystem, restarting || !mayStayClosed { exit(1) }
    }

    static func now() {
        restarting = true
        // The installed app is restarted by the system as soon as it exits. Any other copy reopens itself.
        if !startedBySystem {
            var arguments = ["-n", Bundle.main.bundlePath]
            for (key, value) in ProcessInfo.processInfo.environment where key.hasPrefix("FOCUSSPRINT_") {
                arguments += ["--env", "\(key)=\(value)"]
            }
            let quoted = arguments.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = ["-c", "sleep 1; /usr/bin/open \(quoted)"]
            try? task.run()
        }
        NSApp.terminate(nil)
    }
}
