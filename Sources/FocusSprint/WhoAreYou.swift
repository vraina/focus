import AppKit
import SwiftUI
import FocusSprintCore

/// Shown over the whole app when this computer is linked to a household but nobody has said whose this
/// Mac login is. The app cannot be used until that is settled; the Mac itself is never locked.
struct WhoAreYouView: View {
    var status: HelperStatus
    /// Development snapshots only: open with the adult's code entry showing.
    var startAsAdult = false
    @State private var waitingFor: String?
    @State private var startedWaiting = Date()
    @State private var message: String?
    @State private var showCode = false
    @State private var code = ""
    private let poll = Ticker.every1

    private var profiles: [HelperStatus.Profile] { status.profiles ?? [] }

    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                // On a Mac that is already linked, choosing a profile is this login's first step.
                StepRow(current: 1, first: "Choose your profile").padding(.bottom, 6)
                Text("Who are you?").font(Theme.title(42)).kerning(-1).foregroundStyle(Theme.ink)
                Text("This Mac is shared by your household. Pick your profile once, and this login is yours from then on.")
                    .font(.system(size: 15)).foregroundStyle(Theme.soft).frame(maxWidth: 640, alignment: .leading)
                if profiles.isEmpty {
                    Notice(text: "There is no profile free to pick on this computer. A household admin can add you under People on the website, or assign this login under Computers.",
                           tint: Theme.warn, icon: "person.badge.plus")
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), alignment: .leading, spacing: 12) {
                        ForEach(profiles) { profile in
                            Button { pick(profile) } label: { ProfileCard(name: profile.name) }
                                .buttonStyle(.plain)
                                .disabled(waitingFor != nil)
                        }
                    }
                }
                if let message { Notice(text: message, tint: Theme.bad) }
                if waitingFor != nil { ProgressView().controlSize(.small) }

                // Adults are not in the list: an adult's records are private, so an adult proves who they are with a code.
                if showCode {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Adults are not in the list, because an adult's records are private. Enter your own code from the website.")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.soft)
                        HStack(spacing: 8) {
                            CodeField(placeholder: "Code from the website", code: $code, size: 18, height: 50, paste: false, onSubmit: useCode)
                            Button("Use code", action: useCode)
                                .buttonStyle(PrimaryButtonStyle(wide: false, height: 49))
                                .disabled(waitingFor != nil || code.filter { $0.isLetter || $0.isNumber }.count < 8)
                        }
                        Text("Sign in on the website, open Computers, and choose \"Get a code\" for yourself.")
                            .font(.system(size: 12.5)).foregroundStyle(Theme.soft)
                    }
                    .card(padding: 16)
                } else {
                    Button("I am an adult in this household") { showCode = true }
                        .buttonStyle(OutlineButtonStyle(height: 44))
                }
                Spacer(minLength: 0)
                Text("Picked the wrong one? A household admin can change it on the website. Until someone is chosen, what this login records waits on this Mac.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.soft)
            }
            .padding(EdgeInsets(top: 48, leading: 40, bottom: 28, trailing: 40))
            .frame(maxWidth: 1000, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear {
            if startAsAdult { showCode = true }
            FirstRun.noteStarted()
        }
        .onReceive(poll) { _ in
            guard let id = waitingFor else { return }
            if let result = PairingResult.load(), result.id == id {
                waitingFor = nil
                message = result.ok ? nil : result.message
            } else if Date().timeIntervalSince(startedWaiting) > 40 {
                waitingFor = nil
                message = "No answer yet. Check that the Mac is online and try again."
            }
        }
    }

    private func send(_ request: SiteRequest, id: String) {
        do {
            try request.drop()
            waitingFor = id
            startedWaiting = Date()
            message = nil
        } catch {
            message = "Could not reach the helper. Ask an administrator to run the installer again."
        }
    }

    private func pick(_ profile: HelperStatus.Profile) {
        let id = UUID().uuidString.lowercased()
        send(.claim(member: profile.id, id: id), id: id)
    }

    private func useCode() {
        let id = UUID().uuidString.lowercased()
        send(.pairing(code: code, deviceName: Host.current().localizedName ?? "Mac", id: id), id: id)
    }
}

/// One profile to pick: the initial in a circle over the name. The edge turns accent under the pointer.
private struct ProfileCard: View {
    var name: String
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 10) {
            Text(String(name.prefix(1)).uppercased())
                .font(Theme.title(28)).foregroundStyle(hovering ? Theme.onBrand : Theme.brandText)
                .frame(width: 64, height: 64).background(hovering ? Theme.brand : Theme.brandTint, in: Circle())
                .accessibilityHidden(true)
            Text(name).font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.ink).lineLimit(1)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 20).padding(.horizontal, 12)
        .background(hovering ? Theme.brandTint : Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(hovering ? Theme.brand : Theme.hairline, lineWidth: 1.5))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
