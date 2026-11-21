import AppKit
import SwiftUI
import FocusSprintCore

/// Root-owned changes. macOS shows its own administrator password prompt, so a Standard
/// account cannot do these.
enum AdminWriter {
    /// Removes this Mac's link to its household.
    static func unlink() throws {
        let fm = FileManager.default
        if fm.isWritableFile(atPath: Paths.root.path) {
            // Development root owned by the current user: no elevation needed.
            try? fm.removeItem(at: Paths.service)
            return
        }
        let shell = "/bin/rm -f '\(Paths.service.path)'"
            .replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = NSAppleScript(source: "do shell script \"\(shell)\" with prompt \"Unlink this Mac from its household\" with administrator privileges")
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        if let error {
            throw NSError(domain: "YoungWonksFocus", code: 1, userInfo: [
                NSLocalizedDescriptionKey: (error[NSAppleScript.errorMessage] as? String) ?? "Administrator approval was not given."])
        }
    }
}

/// The Account tab. Reports and settings live on the website; this screen only links the Mac to
/// a member of a household and shows how the link is doing.
struct SettingsView: View {
    /// Development snapshots only: a made-up status to draw instead of the helper's.
    var sample: HelperStatus?
    @StateObject private var linker = Linker()
    private let poll = Ticker.every1
    @FocusState private var nameFocused: Bool

    private var status: HelperStatus? { linker.status }
    private var waitingFor: String? { linker.waitingFor }
    private var message: String? { linker.message }
    private var messageIsError: Bool { linker.messageIsError }
    private var code: String { linker.code }

    private var helperRunning: Bool { status?.isFresh == true }
    private var linked: Bool { status?.linked == true }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Account").font(Theme.title(34)).kerning(-0.8).foregroundStyle(Theme.ink)
                    Text("Reports and settings are on the website. A computer is linked to a household once; each Mac login on it then belongs to one person.")
                        .font(.system(size: 14)).foregroundStyle(Theme.soft).fixedSize(horizontal: false, vertical: true)
                }
                if !helperRunning {
                    Notice(text: "The YoungWonks Focus helper is not answering on this Mac. Run the installer again from an administrator account."
                           + (Paths.helperProblem().map { "\n(Detail: \($0), app \(AppVersion.installed).)" } ?? ""), tint: Theme.bad)
                } else if linked {
                    linkedCard
                } else {
                    linkCard
                }
                if let message {
                    Notice(text: message, tint: messageIsError ? Theme.bad : Theme.good,
                           icon: messageIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                }
            }
            .padding(EdgeInsets(top: 44, leading: 30, bottom: 24, trailing: 30))
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onReceive(poll) { _ in refresh() }
        .onAppear(perform: refresh)
        #if DEBUG
        .onAppear {
            // For testing the link screen without typing: submits the given code once the screen opens.
            if let auto = ProcessInfo.processInfo.environment["FOCUSSPRINT_AUTOLINK"], waitingFor == nil, message == nil {
                linker.code = auto
                link()
                FileHandle.standardError.write(Data("autolink: submitted\n".utf8))
            }
        }
        .onChange(of: linked) { _, new in FileHandle.standardError.write(Data("autolink: linked card shown = \(new), still waiting = \(waitingFor != nil)\n".utf8)) }
        .onChange(of: waitingFor) { _, new in FileHandle.standardError.write(Data("autolink: waiting = \(new != nil)\n".utf8)) }
        .onChange(of: message) { _, new in FileHandle.standardError.write(Data("autolink: message = \(new ?? "nil")\n".utf8)) }
        #endif
    }

    // MARK: Not linked yet

    private var linkCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Link this computer").font(Theme.title(22)).foregroundStyle(Theme.ink)
                Text("On the website, open Computers, pick whose login this is, and choose \"Get a code\".")
                    .font(.system(size: 13)).foregroundStyle(Theme.soft)
            }
            VStack(alignment: .leading, spacing: 5) {
                SectionLabel(text: "Code from the website")
                CodeField(code: $linker.code, onSubmit: link)
            }
            VStack(alignment: .leading, spacing: 5) {
                SectionLabel(text: "Name for this computer")
                TextField("e.g. Mia's MacBook", text: $linker.deviceName)
                    .textFieldStyle(.plain).font(.system(size: 15))
                    .focused($nameFocused)
                    .padding(.horizontal, 16).frame(height: 44)
                    .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(nameFocused ? Theme.brand : Theme.outline, lineWidth: 1.5))
            }
            HStack(spacing: 14) {
                Button(waitingFor == nil ? "Link this computer" : "Linking…", action: link)
                    .buttonStyle(PrimaryButtonStyle(wide: false, height: 46))
                    .disabled(waitingFor != nil || code.filter { $0.isLetter || $0.isNumber }.count < 8)
                Text("No account password is ever typed on this computer. Until it is linked, everything recorded simply waits on this Mac.")
                    .font(.system(size: 12)).foregroundStyle(Theme.soft).fixedSize(horizontal: false, vertical: true)
            }
        }
        .card(padding: 20)
    }

    // MARK: Linked

    private var linkedCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                Image(systemName: status?.linkProblem == nil ? "checkmark" : "exclamationmark")
                    .font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(status?.linkProblem == nil ? Theme.good : Theme.warn, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(status?.memberName.map { $0.isEmpty ? "Linked" : "This login is \($0)" } ?? "Linked")
                        .font(Theme.title(24)).foregroundStyle(Theme.ink)
                    Text([status?.deviceName.map { "\"\($0)\"" }, status?.account.map { "household account \($0)" }].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 13)).foregroundStyle(Theme.soft)
                }
            }
            if let problem = status?.linkProblem { Notice(text: problem, tint: Theme.warn) }
            HStack(spacing: 12) {
                figure("Waiting to send", "\(status?.pending ?? 0)")
                figure("Last sent", status?.lastUploadAt.map { $0.formatted(date: .omitted, time: .shortened) } ?? "—")
            }
            if let error = status?.lastError, status?.linkProblem == nil {
                Text("Cannot reach the service right now (\(error)). Everything is kept here and sent when it is back.")
                    .font(.system(size: 12)).foregroundStyle(Theme.soft)
            }
            HStack(spacing: 12) {
                Button("Open the website") {
                    if let url = URL(string: ServiceConfig.baseURL) { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(PrimaryButtonStyle(wide: false, height: 44))
                Spacer()
                Button("Unlink this computer…", action: unlink)
                    .buttonStyle(OutlineButtonStyle(tint: Theme.badText, height: 44))
            }
            Text(status?.isAdult == true
                 ? "Your records are private: only you can see them, on your own sign-in. Unlinking the computer needs the Mac administrator password and affects every login on it."
                 : "A household admin can see what this login records, and can change whose login it is on the website. Unlinking the computer needs the Mac administrator password.")
                .font(.system(size: 12)).foregroundStyle(Theme.soft).fixedSize(horizontal: false, vertical: true)
        }
        .card(padding: 20)
    }

    private func figure(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.soft)
            Text(value).font(Theme.number(28)).foregroundStyle(Theme.ink).lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    // MARK: Actions

    private func refresh() { linker.refresh(sample: sample) }
    private func link() { linker.link() }

    private func unlink() {
        do {
            try AdminWriter.unlink()
            linker.message = "Unlinked. This computer keeps recording, and sends everything once it is linked again."
            linker.messageIsError = false
        } catch {
            linker.message = error.localizedDescription
            linker.messageIsError = true
        }
    }
}

/// Linking this Mac with a code from the website: what is typed, the wait for the helper's answer, and
/// what to say afterwards. Shared by the Account tab and the first run's "Link this Mac" step.
@MainActor
final class Linker: ObservableObject {
    @Published var status = HelperStatus.load()
    @Published var code = ""
    @Published var deviceName = Host.current().localizedName ?? "Mac"
    @Published var waitingFor: String?
    @Published var message: String?
    @Published var messageIsError = false
    private var startedWaiting = Date()

    var canLink: Bool { waitingFor == nil && code.filter { $0.isLetter || $0.isNumber }.count >= 8 }

    func refresh(sample: HelperStatus? = nil) {
        status = sample ?? HelperStatus.load()
        guard let id = waitingFor else { return }
        if status?.linked == true, PairingResult.load()?.id != id, Date().timeIntervalSince(startedWaiting) > 5 {
            // The computer is linked but the helper's note about this attempt is missing: say so plainly.
            waitingFor = nil
            message = nil // the linked card that has replaced the form says it
            code = ""
        } else if let result = PairingResult.load(), result.id == id {
            // Accepted: stay on "Linking…" for the moment it takes the helper to report whose login this is,
            // so the form is replaced by the linked card rather than by a line of text under it.
            if result.ok, status?.linked != true || (status?.memberName ?? "").isEmpty,
               Date().timeIntervalSince(startedWaiting) < 20 { return }
            waitingFor = nil
            message = result.ok && status?.linked == true ? nil : result.message
            messageIsError = !result.ok
            if result.ok { code = "" }
        } else if Date().timeIntervalSince(startedWaiting) > 60 {
            waitingFor = nil
            message = "No answer from the helper. Check that the Mac is online and try again."
            messageIsError = true
        }
    }

    func link() {
        let id = UUID().uuidString.lowercased()
        let name = deviceName.trimmingCharacters(in: .whitespaces)
        do {
            try SiteRequest.pairing(code: code, deviceName: name.isEmpty ? "Mac" : name, id: id).drop()
            waitingFor = id
            startedWaiting = Date()
            message = nil
        } catch {
            message = "Could not pass the code to the helper. Run the installer again from an administrator account."
            messageIsError = true
        }
    }
}
