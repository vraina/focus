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
        let env = ProcessInfo.processInfo.environment
        // Development only: FOCUSSPRINT_SELFSHOT=<file.png> saves a picture of the real main window, frame and
        // window buttons included, a few seconds after launch. (Snapshots draw screens without a window.)
        if let path = env["FOCUSSPRINT_SELFSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                guard let window = NSApp.windows.first(where: { $0.title == "YoungWonks Focus" }),
                      let frame = window.contentView?.superview,
                      let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return }
                frame.cacheDisplay(in: frame.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                let close = window.standardWindowButton(.closeButton).map { $0.convert($0.bounds, to: nil) } ?? .zero
                FileHandle.standardError.write(Data("selfshot: fullSize=\(window.styleMask.contains(.fullSizeContentView)) titleHidden=\(window.titleVisibility == .hidden) transparent=\(window.titlebarAppearsTransparent) layout=\(window.contentLayoutRect) frame=\(window.frame.size) close=\(close)\n".utf8))
            }
        }
        // Development only: FOCUSSPRINT_AUTOSTART=<minutes> starts a sprint without touching the UI.
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
        AppRelaunch.leave()
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
                // No title bar: content runs to the top edge, under the close, minimise and zoom buttons.
                // The strip they sit in still drags the window; every screen starts its content 44pt down.
                .ignoresSafeArea(.container, edges: .top)
        }
        .windowStyle(.hiddenTitleBar)
        MenuBarExtra {
            MenuContent().environmentObject(engine)
        } label: {
            if engine.phase == .idle {
                Image(systemName: "timer")
            } else {
                Ticking { Text((engine.phase == .onBreak ? "Break " : "") + SprintEngine.clock(engine.clockSeconds)).monospacedDigit() }
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
    /// Development snapshots only: made-up app lists for the Apps screen.
    var sampleApps: AppList?
    var sampleStatus: HelperStatus?
    @State private var canRecord = CGPreflightScreenCaptureAccess()
    /// Bumped when a first-run step is left, so the next one is worked out again.
    @State private var firstRunTurn = 0

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Theme.hairline).frame(width: 1)
            Group {
                switch pane {
                case .focus: SprintView()
                case .history: HistoryView()
                case .apps: AppsView(sample: sampleApps)
                case .parent: SettingsView(sample: sampleStatus)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // While a first-run step or "Who are you?" covers the app, nothing underneath can be pressed or
        // reached with Return.
        .disabled(covered)
        .background(Theme.canvas)
        .overlay { MediaViewerOverlay(viewer: MediaViewer.shared) }
        // The guided first run, one step at a time, and only the steps this login still needs.
        .overlay {
            let _ = firstRunTurn
            if let step = FirstRun.step(status: status, canRecord: canRecord, idle: engine.phase == .idle) {
                FirstRunView(step: step, status: status) {
                    if step == .ready { pane = .focus }
                    firstRunTurn += 1
                }
                .id(step)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            canRecord = CGPreflightScreenCaptureAccess()
        }
        // The computer is linked but this login has no person yet: nothing else in the app until that is settled.
        .overlay { if let status, status.isFresh, status.needsProfile { WhoAreYouView(status: status) } }
        .onReceive(statusTimer) { _ in status = HelperStatus.load() }
        .onAppear { Timing.mark("main window appeared") }
    }

    private var covered: Bool {
        let _ = firstRunTurn
        if let status, status.isFresh, status.needsProfile { return true }
        return FirstRun.step(status: status, canRecord: canRecord, idle: engine.phase == .idle) != nil
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "timer")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.onBrand)
                    .frame(width: 30, height: 30)
                    .background(Theme.brand, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 0) {
                    Text("YoungWonks").font(.system(size: 14, weight: .bold))
                    Text("Focus").font(.system(size: 11.5)).foregroundStyle(Theme.soft)
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 14)
            .accessibilityElement(children: .combine)

            ForEach(Pane.allCases) { item in
                Button { pane = item } label: {
                    Text(item.rawValue).font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 38)
                        .foregroundStyle(pane == item ? Theme.canvas : Theme.soft)
                        .background(pane == item ? Theme.ink : Color.clear, in: PillShape())
                        .contentShape(PillShape())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(pane == item ? .isSelected : [])
            }
            Spacer()
            TodayCard()
        }
        .padding(EdgeInsets(top: 46, leading: 12, bottom: 12, trailing: 12))
        .frame(width: 216)
    }
}

/// Today's distraction at a glance, always visible in the sidebar.
struct TodayCard: View {
    @EnvironmentObject var engine: SprintEngine
    @ObservedObject private var beat = SprintEngine.shared.beat

    var body: some View {
        let _ = engine.pulse
        let level = engine.todayDistraction
        let percent = Int((level * 100).rounded())
        VStack(alignment: .leading, spacing: 0) {
            Text("Today").font(Theme.title(22)).foregroundStyle(Theme.ink)
            // Very large for one or two digits; shrinks to fit the card at 100%.
            (Text("\(percent)").font(.system(size: 100, weight: .bold))
             + Text(" ").font(.system(size: 8))
             + Text("%").font(.system(size: 40, weight: .bold)))
                .monospacedDigit()
                .foregroundStyle(levelColor(level))
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .frame(height: 96)
                .padding(.top, 4)
                .accessibilityLabel("\(percent) percent")
            Text("distracted").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
            Text("\(engine.todaySwitches) switches · \(Format.duration(engine.todayAway)) away")
                .font(.system(size: 11.5)).foregroundStyle(Theme.soft)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 14)
        .accessibilityElement(children: .combine)
    }
}
