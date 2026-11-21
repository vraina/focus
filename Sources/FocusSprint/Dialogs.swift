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
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 12) { content }
            .padding(24)
            .frame(width: 440)
            .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.hairline))
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
        DialogShell {
            VStack(spacing: 3) {
                Text("Need \(host) for work?").font(Theme.title(24)).foregroundStyle(Theme.ink).multilineTextAlignment(.center)
                Text("Say what you are working on and how long you need it.")
                    .font(.system(size: 13)).foregroundStyle(Theme.soft).multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 5) {
                SectionLabel(text: "What for?")
                TextField("e.g. Watching the physics lecture for Thursday's class", text: $reason, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .lineLimit(3...4)
                    .focused($typing)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(typing ? Theme.brand : Theme.outline, lineWidth: 1.5))
                    .onSubmit(send)
                SectionLabel(text: "How long?").padding(.top, 7)
                Segments(label: "How long",
                         options: RequestDialog.durations.enumerated().map { (value: $0.offset, title: $0.element.title) },
                         selection: $choice, height: 34)
                if RequestDialog.durations[choice].permanent {
                    Text("Choose Always only if this site is never a distraction, like a reference or school site.")
                        .font(.system(size: 12)).foregroundStyle(Theme.soft).padding(.top, 1)
                }
            }
            Text(HelperStatus.load()?.isAdult == true
                 ? "The request is checked straight away. It goes into your own daily summary, which only you see."
                 : "The request is checked straight away. Your reason and the answer go into the household admins' daily summary.")
                .font(.system(size: 12)).foregroundStyle(Theme.soft).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Cancel", action: onCancel)
                    .buttonStyle(OutlineButtonStyle(height: 46, wide: true))
                    .keyboardShortcut(.cancelAction)
                Button("Send request", action: send)
                    .buttonStyle(PrimaryButtonStyle(height: 46))
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
        DialogShell {
            Pill(text: answer.approved ? "Approved" : "Not approved", tint: answer.approved ? Theme.good : Theme.bad)
            Text(title).font(Theme.title(20)).foregroundStyle(Theme.ink).multilineTextAlignment(.center)
            Text(answer.explanation)
                .font(.system(size: 14)).foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(note)
                .font(.system(size: 12)).foregroundStyle(Theme.soft).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("OK", action: onClose)
                .buttonStyle(PrimaryButtonStyle(height: 44))
                .keyboardShortcut(.defaultAction)
                .padding(.top, 4)
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
