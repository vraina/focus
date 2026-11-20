import AppKit
import Combine
import SwiftUI
import FocusSprintCore

func levelColor(_ fraction: Double) -> Color {
    if fraction < 0.05 { return .green }
    if fraction < 0.15 { return .orange }
    return .red
}

/// The always-on-top gauge: sprint progress, distraction in this sprint, distraction for the day.
struct MeterView: View {
    @ObservedObject var engine: SprintEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let away = engine.awayNow {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("Away: \(away.label)").lineLimit(1)
                    Spacer(minLength: 4)
                    Text(SprintEngine.clock(Date().timeIntervalSince(away.since))).monospacedDigit()
                }
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.red)
                if let host = away.host, away.category == .distraction {
                    switch engine.disputeOption(for: host) {
                    case .available:
                        Button("Needed for work") { DisputePrompt.ask(host: host, engine: engine) }
                            .controlSize(.small)
                    case .sent:
                        Label("Checking your request…", systemImage: "hourglass")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    case .closed:
                        EmptyView()
                    }
                }
            }
            row(title: "Sprint",
                value: engine.phase == .running ? SprintEngine.clock(engine.remaining) : (engine.phase == .onBreak ? "Break" : "—"),
                fraction: engine.sprintProgress, color: .blue)
            row(title: "Sprint distraction",
                value: engine.phase == .running ? "\(Int((engine.sprintDistraction * 100).rounded()))%" : "—",
                fraction: engine.sprintDistraction, color: levelColor(engine.sprintDistraction))
            row(title: "Today",
                value: "\(Int((engine.todayDistraction * 100).rounded()))%",
                fraction: engine.todayDistraction, color: levelColor(engine.todayDistraction))
            Text("\(engine.todaySwitches) switches · \(Format.duration(engine.todayAway)) of \(Format.duration(engine.todaySprintSeconds)) today")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            if engine.todayAwayUnderReview >= 1 {
                Text("Leaving out sites approved since: \(Int((engine.todayDistractionStrict * 100).rounded()))%")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(11)
        .frame(width: 236)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(engine.awayNow != nil ? Color.red : Color.primary.opacity(0.15), lineWidth: engine.awayNow != nil ? 2 : 1))
    }

    private func row(title: String, value: String, fraction: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.system(size: 11, weight: .medium))
                Spacer()
                Text(value).font(.system(size: 12, weight: .bold)).monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(color).frame(width: max(fraction > 0 ? 4 : 0, geo.size.width * fraction))
                }
            }
            .frame(height: 5)
        }
    }
}

/// Asks the student why a site is needed and for how long, and later shows the reviewer's answer.
@MainActor
enum DisputePrompt {
    private static let durations: [(title: String, minutes: Int, permanent: Bool)] = [
        ("15 minutes", 15, false), ("30 minutes", 30, false), ("1 hour", 60, false), ("2 hours", 120, false),
        ("Always: this site is never a distraction", 60, true),
    ]

    static func ask(host: String, engine: SprintEngine) {
        let alert = NSAlert()
        alert.messageText = "Why do you need \(host)?"
        alert.informativeText = "Say what you are working on and how long you need. The request is checked straight away. Your reason and the answer go into your parent's daily summary."
        let field = NSTextField(frame: NSRect(x: 0, y: 32, width: 340, height: 24))
        field.placeholderString = "e.g. Watching the physics lecture for Thursday's class"
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 340, height: 26))
        picker.addItems(withTitles: durations.map(\.title))
        picker.selectItem(at: 1)
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 58))
        box.addSubview(field)
        box.addSubview(picker)
        alert.accessoryView = box
        alert.addButton(withTitle: "Send")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let reason = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty else { return }
        let choice = durations[max(0, picker.indexOfSelectedItem)]
        engine.dispute(host: host, reason: reason, minutes: choice.minutes, permanent: choice.permanent)
    }

    static func show(_ answer: RequestAnswer) {
        let alert = NSAlert()
        switch answer.decision {
        case "approve_permanent": alert.messageText = "\(answer.host) is approved"
        case "approve_temporary": alert.messageText = "\(answer.host) is approved for \(answer.minutes) minutes"
        default:
            alert.messageText = "\(answer.host) was not approved"
            alert.alertStyle = .warning
        }
        alert.informativeText = answer.explanation
            + (answer.approved ? "\n\nIt will not count as a distraction\(answer.decision == "approve_temporary" ? " until the time is up" : "")."
                               : "\n\nIt still counts as a distraction. You can ask again with a more specific reason.")
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

@MainActor
final class MeterPanelController {
    private let panel: NSPanel
    private var watcher: AnyCancellable?
    private var answers: AnyCancellable?

    init(engine: SprintEngine) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 236, height: 150),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: MeterView(engine: engine))
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - panel.frame.width - 16, y: frame.maxY - panel.frame.height - 16))
        }
        panel.setFrameAutosaveName("FocusSprintMeter")

        answers = engine.$answer.compactMap { $0 }.receive(on: RunLoop.main).sink { reply in
            DisputePrompt.show(reply)
        }
        watcher = engine.$pulse.sink { [weak self, weak engine] _ in
            guard let self, let engine else { return }
            let size = host.fittingSize
            if abs(size.height - self.panel.frame.height) > 0.5 {
                // Grow downwards so the top edge stays where the user put it.
                var frame = self.panel.frame
                frame.origin.y += frame.height - size.height
                frame.size = size
                self.panel.setFrame(frame, display: true)
            }
            if engine.meterVisible, !self.panel.isVisible {
                self.panel.orderFrontRegardless()
            } else if !engine.meterVisible, self.panel.isVisible {
                self.panel.orderOut(nil)
            }
        }
    }
}
