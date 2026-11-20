import AppKit
import SwiftUI
import FocusSprintCore

/// Shown over the whole app when this computer is linked to a household but nobody has said whose this
/// Mac login is. The app cannot be used until that is settled; the Mac itself is never locked.
struct WhoAreYouView: View {
    var status: HelperStatus
    @State private var waitingFor: String?
    @State private var startedWaiting = Date()
    @State private var message: String?
    @State private var showCode = false
    @State private var code = ""
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var profiles: [HelperStatus.Profile] { status.profiles ?? [] }

    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.system(size: 30, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 76, height: 76).background(Theme.gradient, in: Circle())
                VStack(spacing: 6) {
                    Text("Who are you?").font(Theme.title(30))
                    Text("This Mac is shared by your household. Pick your profile once, and this login is yours from then on.")
                        .font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                if profiles.isEmpty {
                    Notice(text: "There is no profile free to pick on this computer. A household admin can add you under People on the website, or assign this login under Computers.",
                           tint: Theme.warn, icon: "person.badge.plus")
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                        ForEach(profiles) { profile in
                            Button { pick(profile) } label: {
                                VStack(spacing: 6) {
                                    Text(String(profile.name.prefix(1)).uppercased())
                                        .font(Theme.title(20)).foregroundStyle(.white)
                                        .frame(width: 44, height: 44).background(Theme.gradient, in: Circle())
                                    Text(profile.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity).padding(.vertical, 14)
                                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(waitingFor != nil)
                        }
                    }
                }
                if let message { Notice(text: message, tint: Theme.bad) }
                if waitingFor != nil { ProgressView().controlSize(.small) }

                // Adults are not in the list: an adult's records are private, so an adult proves who they are with a code.
                if showCode {
                    HStack(spacing: 8) {
                        TextField("Code from the website", text: $code)
                            .textFieldStyle(.plain).font(.system(size: 16, weight: .semibold, design: .monospaced)).padding(10)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .onSubmit(useCode)
                        Button("Use code", action: useCode)
                            .disabled(waitingFor != nil || code.filter { $0.isLetter || $0.isNumber }.count < 8)
                    }
                    Text("Sign in on the website, open Computers, and choose \"Get a code\" for yourself.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    Button("I am an adult in this household") { showCode = true }
                        .buttonStyle(.plain).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.brand)
                }
                Text("Picked the wrong one? A household admin can change it on the website. Until someone is chosen, what this login records waits on this Mac.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(32)
            .frame(maxWidth: 520)
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
