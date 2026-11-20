#if DEBUG
import AppKit
import SwiftUI
import FocusSprintCore

/// Development only. `FOCUSSPRINT_SNAPSHOT=<folder>` renders the app's screens to PNG files and exits,
/// so the design can be reviewed without clicking through the app.
@MainActor
enum Snapshots {
    struct Shot {
        var name: String
        var size: CGSize
        var dark = false
        var prepare: () -> Void = {}
        var view: () -> AnyView
    }

    static func run(to folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let engine = SprintEngine.shared
        let window = CGSize(width: 1040, height: 760)
        let answerYes = RequestAnswer(id: "1", host: "youtube.com", decision: "approve_temporary", minutes: 45,
                                      explanation: "Approved for 45 minutes to watch the recorded physics lecture for Thursday's class. That is a specific school task YouTube can serve.",
                                      allowedUntil: nil)
        let answerNo = RequestAnswer(id: "2", host: "espn.com", decision: "deny", minutes: 0,
                                     explanation: "ESPN is a sports site and doesn't offer chemistry study material, so this reason doesn't fit what the site is for.",
                                     allowedUntil: nil)
        func app(_ pane: Pane) -> AnyView { AnyView(ContentView(pane: pane).environmentObject(engine)) }
        func padded<V: View>(_ view: V) -> AnyView { AnyView(view.padding(30).background(Color(white: 0.5).opacity(0.25))) }

        let shots: [Shot] = [
            Shot(name: "1-focus-setup", size: window, prepare: { engine.debugPreview("idle") }, view: { app(.focus) }),
            Shot(name: "2-focus-running", size: window, prepare: { engine.debugPreview("running") }, view: { app(.focus) }),
            Shot(name: "3-focus-away", size: window, prepare: { engine.debugPreview("away") }, view: { app(.focus) }),
            Shot(name: "4-history", size: CGSize(width: 1040, height: 900), prepare: { engine.debugPreview("idle") }, view: { app(.history) }),
            Shot(name: "5-parent", size: window, view: { app(.parent) }),
            Shot(name: "6-widget-away", size: CGSize(width: 304, height: 300), prepare: { engine.debugPreview("away") },
                 view: { padded(MeterView(engine: engine)) }),
            Shot(name: "7-widget-calm", size: CGSize(width: 304, height: 180), prepare: { engine.debugPreview("idle") },
                 view: { padded(MeterView(engine: engine)) }),
            Shot(name: "7b-widget-away-no-sprint", size: CGSize(width: 304, height: 220), prepare: { engine.debugPreview("away-idle") },
                 view: { padded(MeterView(engine: engine)) }),
            Shot(name: "7c-widget-sprint-calm", size: CGSize(width: 304, height: 260), prepare: { engine.debugPreview("running") },
                 view: { padded(MeterView(engine: engine)) }),
            Shot(name: "8-dialog-request", size: CGSize(width: 500, height: 470),
                 view: { padded(RequestDialog(host: "youtube.com", onSend: { _, _, _ in }, onCancel: {})) }),
            Shot(name: "9-dialog-approved", size: CGSize(width: 500, height: 330),
                 view: { padded(AnswerDialog(answer: answerYes, onClose: {})) }),
            Shot(name: "10-dialog-denied", size: CGSize(width: 500, height: 330),
                 view: { padded(AnswerDialog(answer: answerNo, onClose: {})) }),
            Shot(name: "11-focus-setup-dark", size: window, dark: true, prepare: { engine.debugPreview("idle") }, view: { app(.focus) }),
            Shot(name: "12-history-dark", size: CGSize(width: 1040, height: 900), dark: true, view: { app(.history) }),
            Shot(name: "13-widget-away-dark", size: CGSize(width: 304, height: 300), dark: true,
                 prepare: { engine.debugPreview("away") }, view: { padded(MeterView(engine: engine)) }),
            Shot(name: "14-viewer", size: CGSize(width: 1040, height: 760), prepare: {
                engine.debugPreview("idle")
                let folder = Paths.vault.appendingPathComponent("sprints")
                if let record = SprintReader.list(in: folder).first(where: { $0.events.contains { !$0.media.isEmpty } }) {
                    let items = record.events.reversed().flatMap { event in
                        event.media.map { ViewerItem(event: event, ref: $0, directory: record.directory, source: .local) }
                    }
                    MediaViewer.shared.open(items, at: items.dropFirst().first?.id ?? "")
                }
            }, view: { app(.history) }),
            Shot(name: "15-who-are-you", size: CGSize(width: 1040, height: 760), view: {
                var status = HelperStatus(linked: true, deviceName: "Den iMac", pending: 3)
                status.profiles = [.init(id: "1", name: "Aarav"), .init(id: "2", name: "Mia"), .init(id: "3", name: "Leo")]
                return AnyView(WhoAreYouView(status: status))
            }),
            Shot(name: "AppIcon", size: CGSize(width: 1024, height: 1024), view: { AnyView(AppIconArt()) }),
        ]
        Task { @MainActor in
            for shot in shots {
                shot.prepare()
                await render(shot, to: folder.appendingPathComponent(shot.name + ".png"))
            }
            exit(0)
        }
    }

    private static func render(_ shot: Shot, to url: URL) async {
        if shot.name == "AppIcon" {
            // Drawn from plain shapes, so it can be rendered directly with a transparent background.
            let renderer = ImageRenderer(content: AppIconArt())
            renderer.scale = 1
            if let image = renderer.cgImage {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
            }
            return
        }
        let frame = NSRect(x: -6000, y: -6000, width: shot.size.width, height: shot.size.height) // off every screen
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: shot.dark ? .darkAqua : .aqua)
        window.isOpaque = shot.name != "AppIcon"
        window.backgroundColor = shot.name == "AppIcon" ? .clear : .windowBackgroundColor
        let host = NSHostingView(rootView: shot.view().frame(width: shot.size.width, height: shot.size.height))
        host.frame = NSRect(origin: .zero, size: shot.size)
        window.contentView = host
        window.orderFrontRegardless()
        try? await Task.sleep(nanoseconds: 900_000_000) // let onAppear, images and layout settle
        host.layoutSubtreeIfNeeded()
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        window.orderOut(nil)
    }
}

/// The app icon, drawn in code so it can be regenerated: a focus target on the brand gradient.
struct AppIconArt: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 186, style: .continuous)
                .fill(Theme.gradient)
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.25), radius: 18, y: 10)
            Circle().stroke(.white.opacity(0.35), lineWidth: 44).frame(width: 520, height: 520)
            Circle().trim(from: 0, to: 0.72).stroke(.white, style: StrokeStyle(lineWidth: 44, lineCap: .round))
                .rotationEffect(.degrees(-90)).frame(width: 520, height: 520)
            Circle().fill(.white).frame(width: 150, height: 150)
        }
        .frame(width: 1024, height: 1024)
    }
}

extension SprintEngine {
    /// Puts the engine into a fixed, made-up state for screenshots. Tracking is switched off.
    func debugPreview(_ mode: String) {
        stopTimerForPreview()
        let now = Date()
        setPreview(running: mode == "running" || mode == "away", away: mode.hasPrefix("away"), now: now)
    }
}
#endif
