import AppKit
import Combine
import SwiftUI
import FocusSprintCore

/// The always-on-top gauge: sprint progress, distraction in this sprint, distraction for the day.
struct MeterView: View {
    @ObservedObject var engine: SprintEngine

    var body: some View {
        let away = engine.awayNow
        VStack(alignment: .leading, spacing: 11) {
            if let away {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11, weight: .bold))
                        Text(away.label).font(.system(size: 12, weight: .bold)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(SprintEngine.clock(Date().timeIntervalSince(away.since))).font(Theme.number(12))
                    }
                    .foregroundStyle(.white)
                    if let host = away.host, away.category == .distraction {
                        switch engine.disputeOption(for: host) {
                        case .available:
                            Button { DisputePrompt.ask(host: host, engine: engine) } label: {
                                Text("Needed for work")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Theme.bad)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 5)
                                    .background(.white, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        case .sent:
                            Label("Checking your request…", systemImage: "hourglass")
                                .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                        case .closed:
                            EmptyView()
                        }
                    }
                }
                .padding(10)
                .background(Theme.bad, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }

            HStack(spacing: 11) {
                ZStack {
                    Ring(progress: engine.sprintProgress, lineWidth: 5, tint: nil)
                    Image(systemName: engine.phase == .onBreak ? "cup.and.saucer.fill" : "timer")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                }
                .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 0) {
                    Text(engine.phase == .running ? "Sprint" : (engine.phase == .onBreak ? "Break" : "No sprint running"))
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Text(engine.phase == .idle ? "—" : SprintEngine.clock(engine.remaining)).font(Theme.number(20))
                }
                Spacer(minLength: 0)
            }

            bar(title: "This sprint", value: engine.phase == .running ? engine.sprintDistraction : nil)
            bar(title: "Today", value: engine.todayDistraction)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(engine.todaySwitches) switches · \(Format.duration(engine.todayAway)) of \(Format.duration(engine.todaySprintSeconds))")
                if engine.todayAwayUnderReview >= 1 {
                    Text("Leaving out sites approved since: \(Int((engine.todayDistractionStrict * 100).rounded()))%")
                }
            }
            .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(13)
        .frame(width: 244)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(away != nil ? Theme.bad.opacity(0.8) : Color.primary.opacity(0.12), lineWidth: away != nil ? 1.5 : 1))
    }

    /// One distraction meter. `nil` means "not applicable right now".
    private func bar(title: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 11, weight: .medium))
                Text("distraction").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text(value.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                    .font(Theme.number(13)).foregroundStyle(value.map(levelColor) ?? .secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.10))
                    Capsule().fill(levelColor(value ?? 0))
                        .frame(width: max((value ?? 0) > 0 ? 5 : 0, geo.size.width * (value ?? 0)))
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
