import AppKit
import SwiftUI
import FocusSprintCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var meter: MeterPanelController?
    private var presence: Timer?

    /// Tells the helper this login is in use (so it sets up the login's area), and while nobody has said
    /// whose login this is, keeps the "Who are you?" screen in front. The Mac itself is never locked.
    private func checkIn() {
        let status = HelperStatus.load()
        if status?.isFresh != true { try? SiteRequest.hello().drop() }
        guard status?.needsProfile == true, let window = NSApp.windows.first(where: { $0.title == "YoungWonks Focus" }) else {
            NSApp.windows.first(where: { $0.title == "YoungWonks Focus" })?.level = .normal
            return
        }
        window.level = .floating
        if !window.isVisible || !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if AppRelaunch.yieldToOtherCopy() { exit(0) }
        #if DEBUG
        if let folder = ProcessInfo.processInfo.environment["FOCUSSPRINT_SNAPSHOT"] {
            NSApp.setActivationPolicy(.accessory)
            Snapshots.run(to: URL(fileURLWithPath: folder))
            return
        }
        #endif
        Timing.mark("didFinishLaunching")
        NSApp.setActivationPolicy(.regular)
        meter = MeterPanelController(engine: SprintEngine.shared)
        Timing.mark("engine and widget ready")
        checkIn()
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in self?.checkIn() }
        RunLoop.main.add(timer, forMode: .common)
        presence = timer
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
                .frame(minWidth: 940, minHeight: 640)
        }
        MenuBarExtra {
            MenuContent().environmentObject(engine)
        } label: {
            if engine.phase == .idle {
                Image(systemName: "timer")
            } else {
                Text((engine.phase == .onBreak ? "Break " : "") + SprintEngine.clock(engine.clockSeconds)).monospacedDigit()
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

enum Pane: String, CaseIterable, Identifiable {
    case focus = "Focus"
    case history = "History"
    case apps = "Apps"
    case parent = "Account"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .focus: return "timer"
        case .history: return "chart.bar.xaxis"
        case .apps: return "square.grid.2x2"
        case .parent: return "person.crop.circle"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var engine: SprintEngine
    @State private var status = HelperStatus.load()
    private let statusTimer = Ticker.every2
    @State var pane: Pane = Pane(rawValue: ProcessInfo.processInfo.environment["FOCUSSPRINT_PANE"] ?? "") ?? .focus

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Theme.hairline).frame(width: 1)
            Group {
                switch pane {
                case .focus: SprintView()
                case .history: HistoryView()
                case .apps: AppsView()
                case .parent: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.canvas)
        .overlay { MediaViewerOverlay(viewer: MediaViewer.shared) }
        // The computer is linked but this login has no person yet: nothing else in the app until that is settled.
        .overlay { if let status, status.isFresh, status.needsProfile { WhoAreYouView(status: status) } }
        .onReceive(statusTimer) { _ in status = HelperStatus.load() }
        .onAppear { Timing.mark("main window appeared") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 9) {
                Image(systemName: "scope")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Theme.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 0) {
                    Text("YoungWonks").font(.system(size: 13, weight: .bold, design: .rounded))
                    Text("Focus").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 14)

            ForEach(Pane.allCases) { item in
                Button { pane = item } label: {
                    HStack(spacing: 9) {
                        Image(systemName: item.icon).font(.system(size: 13, weight: .medium)).frame(width: 18)
                        Text(item.rawValue).font(.system(size: 13, weight: pane == item ? .semibold : .regular))
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .foregroundStyle(pane == item ? Theme.brand : Color.primary)
                    .background(pane == item ? Theme.brand.opacity(0.12) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            TodayCard()
        }
        .padding(12)
        .frame(width: 204)
        .background(.regularMaterial)
    }
}

/// Today's distraction at a glance, always visible in the sidebar.
struct TodayCard: View {
    @EnvironmentObject var engine: SprintEngine

    var body: some View {
        let _ = engine.pulse
        let level = engine.todayDistraction
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Today")
            HStack(spacing: 12) {
                ZStack {
                    Ring(progress: level, lineWidth: 6, tint: levelColor(level))
                    Text("\(Int((level * 100).rounded()))%").font(Theme.number(13))
                }
                .frame(width: 50, height: 50)
                VStack(alignment: .leading, spacing: 2) {
                    Text("distracted").font(.system(size: 12, weight: .medium))
                    Text("\(engine.todaySwitches) switches").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("\(Format.duration(engine.todayAway)) away").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 12, radius: 12)
    }
}
