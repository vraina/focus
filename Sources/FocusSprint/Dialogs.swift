import AppKit
import SwiftUI
import FocusSprintCore

/// A borderless window that can still take typing.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The app's own dialogs, in its own style, instead of macOS alert boxes.
@MainActor
enum AppDialog {
    private static var panel: KeyPanel?

    static func present<Content: View>(_ content: Content) {
        dismiss()
        let window = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .modalPanel
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: content)
        window.contentView = host
        window.setContentSize(host.fittingSize)
        window.center()
        panel = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    static func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct DialogShell<Content: View>: View {
    var icon: String
    var tint: Color?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(Theme.gradient), in: Circle())
            content
        }
        .padding(24)
        .frame(width: 440)
        .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.hairline))
    }
}

/// "Why do you need this site, and for how long?"
struct RequestDialog: View {
    static let durations: [(title: String, minutes: Int, permanent: Bool)] = [
        ("15 min", 15, false), ("30 min", 30, false), ("1 hour", 60, false), ("2 hours", 120, false), ("Always", 60, true),
    ]
    var host: String
    var onSend: (String, Int, Bool) -> Void
    var onCancel: () -> Void
    @State private var reason = ""
    @State private var choice = 1
    @FocusState private var typing: Bool

    private var trimmed: String { reason.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        DialogShell(icon: "hand.raised.fill", tint: nil) {
            VStack(spacing: 4) {
                Text("Need \(host) for work?").font(Theme.title(20)).multilineTextAlignment(.center)
                Text("Say what you are working on and how long you need it.")
                    .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "What for?")
                TextField("e.g. Watching the physics lecture for Thursday's class", text: $reason, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .lineLimit(2...4)
                    .focused($typing)
                    .padding(10)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(typing ? Theme.brand.opacity(0.7) : Theme.hairline, lineWidth: typing ? 1.5 : 1))
                    .onSubmit(send)
                SectionLabel(text: "How long?").padding(.top, 6)
                HStack(spacing: 6) {
                    ForEach(Array(RequestDialog.durations.enumerated()), id: \.offset) { index, item in
                        Chip(title: item.title, selected: choice == index) { choice = index }
                    }
                }
                if RequestDialog.durations[choice].permanent {
                    Text("Choose Always only if this site is never a distraction, like a reference or school site.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Text("The request is checked straight away. Your reason and the answer go into your parent's daily summary.")
                .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .font(.system(size: 15, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .keyboardShortcut(.cancelAction)
                Button("Send request", action: send)
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(trimmed.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear { typing = true }
    }

    private func send() {
        guard !trimmed.isEmpty else { return }
        let pick = RequestDialog.durations[choice]
        onSend(trimmed, pick.minutes, pick.permanent)
    }
}

/// The reviewer's answer.
struct AnswerDialog: View {
    var answer: RequestAnswer
    var onClose: () -> Void

    private var title: String {
        switch answer.decision {
        case "approve_permanent": return "\(answer.host) is approved"
        case "approve_temporary": return "\(answer.host) is approved for \(answer.minutes) min"
        default: return "\(answer.host) was not approved"
        }
    }
    private var note: String {
        switch answer.decision {
        case "approve_permanent": return "It will not count as a distraction."
        case "approve_temporary": return "It will not count as a distraction until the time is up."
        default: return "It still counts as a distraction. You can ask again with a more specific reason."
        }
    }

    var body: some View {
        DialogShell(icon: answer.approved ? "checkmark" : "xmark", tint: answer.approved ? Theme.good : Theme.bad) {
            Text(title).font(Theme.title(20)).multilineTextAlignment(.center)
            Text(answer.explanation)
                .font(.system(size: 14))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(note)
                .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("OK", action: onClose)
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
    }
}

@MainActor
enum DisputePrompt {
    static func ask(host: String, engine: SprintEngine) {
        AppDialog.present(RequestDialog(host: host, onSend: { reason, minutes, permanent in
            engine.dispute(host: host, reason: reason, minutes: minutes, permanent: permanent)
            AppDialog.dismiss()
        }, onCancel: { AppDialog.dismiss() }))
    }

    static func show(_ answer: RequestAnswer) {
        AppDialog.present(AnswerDialog(answer: answer, onClose: { AppDialog.dismiss() }))
    }
}
