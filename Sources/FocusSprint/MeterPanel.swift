import AppKit
import Combine
import SwiftUI
import FocusSprintCore

/// The always-on-top gauge: sprint progress, distraction in this sprint, distraction for the day.
/// While the student is on a distraction the whole card turns red.
struct MeterView: View {
    @ObservedObject var engine: SprintEngine

    var body: some View {
        let away = engine.awayNow
        let alert = away != nil
        let ink: Color = alert ? .white : .primary
        let soft: Color = alert ? .white.opacity(0.82) : .secondary
        VStack(alignment: .leading, spacing: 11) {
            if let away {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12, weight: .bold))
                    Text(away.label).font(.system(size: 14, weight: .bold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(SprintEngine.clock(Date().timeIntervalSince(away.since))).font(Theme.number(14))
                }
                .foregroundStyle(.white)
            }

            if engine.phase != .idle {
                HStack(spacing: 11) {
                    ZStack {
                        Ring(progress: engine.sprintProgress, lineWidth: 5, tint: alert ? .white : nil)
                        Image(systemName: engine.phase == .onBreak ? "cup.and.saucer.fill" : "timer")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(soft)
                    }
                    .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(engine.phase == .running ? "Sprint" : "Break").font(.system(size: 11, weight: .medium)).foregroundStyle(soft)
                        Text(SprintEngine.clock(engine.clockSeconds)).font(Theme.number(20)).foregroundStyle(ink)
                    }
                    Spacer(minLength: 0)
                }
            }

            if engine.phase == .running {
                bar(title: "This sprint", value: engine.sprintDistraction, alert: alert)
            }
            bar(title: "Today", value: engine.todayDistraction, alert: alert)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(engine.todaySwitches) switches · \(Format.duration(engine.todayAway)) of \(Format.duration(engine.todaySprintSeconds))")
                if engine.todayAwayUnderReview >= 1 {
                    Text("Leaving out sites approved since: \(Int((engine.todayDistractionStrict * 100).rounded()))%")
                }
                if engine.searchCounts.work + engine.searchCounts.distraction > 0 {
                    Text("Searches: \(engine.searchCounts.work) work · \(engine.searchCounts.distraction) distraction")
                }
            }
            .font(.system(size: 10)).foregroundStyle(soft)

            // Deliberately quiet: available when it is true, but not the thing the card invites you to press.
            if let away, let host = away.host, away.category == .distraction {
                switch engine.disputeOption(for: host) {
                case .available:
                    Button { DisputePrompt.ask(host: host, engine: engine) } label: {
                        Text("Needed for work?").font(.system(size: 10, weight: .medium)).underline()
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                case .sent:
                    Label("Checking your request…", systemImage: "hourglass")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                case .closed:
                    EmptyView()
                }
            }
        }
        .padding(13)
        .frame(width: 244)
        .background {
            if alert {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.bad)
            } else {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.regularMaterial)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(alert ? Color.white.opacity(0.25) : Color.primary.opacity(0.12), lineWidth: 1))
    }

    private func bar(title: String, value: Double, alert: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(alert ? .white : .primary)
                Text("distraction").font(.system(size: 11)).foregroundStyle(alert ? .white.opacity(0.82) : .secondary)
                Spacer()
                Text("\(Int((value * 100).rounded()))%")
                    .font(Theme.number(13)).foregroundStyle(alert ? .white : levelColor(value))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(alert ? Color.white.opacity(0.25) : Color.primary.opacity(0.10))
                    Capsule().fill(alert ? Color.white : levelColor(value))
                        .frame(width: max(value > 0 ? 5 : 0, geo.size.width * value))
                }
            }
            .frame(height: 5)
        }
    }
}

@MainActor
final class MeterPanelController {
    private let panel: NSPanel
    private var watcher: AnyCancellable?
    private var answers: AnyCancellable?

    init(engine: SprintEngine) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 244, height: 170),
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
