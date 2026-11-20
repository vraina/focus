import AppKit
import SwiftUI
import FocusSprintCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var meter: MeterPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        meter = MeterPanelController(engine: SprintEngine.shared)
        NSApp.activate(ignoringOtherApps: true)
        #if DEBUG
        // Development only: FOCUSSPRINT_AUTOSTART=<minutes> starts a sprint without touching the UI.
        let env = ProcessInfo.processInfo.environment
        if let minutes = env["FOCUSSPRINT_AUTOSTART"].flatMap(Int.init) {
            let apps = (env["FOCUSSPRINT_ALLOW"] ?? "").split(separator: ",").map { AllowedApp(bundleId: String($0), name: String($0)) }
            SprintEngine.shared.startSprint(task: "Dev test sprint", minutes: minutes, allowedApps: apps,
                                            domains: FocusRules.parseList(env["FOCUSSPRINT_DOMAINS"] ?? ""))
        }
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        SprintEngine.shared.appIsQuitting()
    }
}

@main
struct FocusSprintApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var engine = SprintEngine.shared

    var body: some Scene {
        Window("YoungWonks Focus", id: "main") {
            ContentView()
                .environmentObject(engine)
                .frame(minWidth: 860, minHeight: 600)
        }
        MenuBarExtra {
            MenuContent().environmentObject(engine)
        } label: {
            if engine.phase == .idle {
                Image(systemName: "timer")
            } else {
                Text((engine.phase == .onBreak ? "Break " : "") + SprintEngine.clock(engine.remaining)).monospacedDigit()
            }
        }
    }
}

struct MenuContent: View {
    @EnvironmentObject var engine: SprintEngine
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open YoungWonks Focus") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        if engine.phase != .idle {
            Button(engine.phase == .running ? "End sprint early" : "Skip break") { engine.stopEarly() }
        }
        Divider()
        Button("Quit YoungWonks Focus") { NSApp.terminate(nil) }
    }
}

struct ContentView: View {
    var body: some View {
        TabView {
            SprintView().tabItem { Label("Sprint", systemImage: "timer") }
            HistoryView().tabItem { Label("History", systemImage: "chart.bar.xaxis") }
            SettingsView().tabItem { Label("Parent settings", systemImage: "lock") }
        }
        .padding(.top, 8)
    }
}
