import AppKit
import SwiftUI
import FocusSprintCore

/// The guided first run: up to three steps shown before the main app, each only when it is needed.
/// A login that is linked and may record the screen never sees any of it.
enum FirstRunStep: Int { case link = 1, pictures, ready }

@MainActor
enum FirstRun {
    /// Steps left with "Link later" or "Later". They stay away until the app is next opened, and come back then.
    static var skipped: Set<FirstRunStep> = []
    /// Off for development snapshots and the DEBUG hooks, which need to land on a particular screen.
    static var enabled: Bool = {
        let env = ProcessInfo.processInfo.environment
        return !["FOCUSSPRINT_PANE", "FOCUSSPRINT_SNAPSHOT", "FOCUSSPRINT_AUTOSTART", "FOCUSSPRINT_AUTOLINK"].contains { env[$0] != nil }
    }()

    /// "Ready" is shown once, after a login has gone through at least one of the other steps.
    private static let startedKey = "firstRunStarted", doneKey = "firstRunDone"
    static func noteStarted() { UserDefaults.standard.set(true, forKey: startedKey) }
    static func finish() { UserDefaults.standard.set(true, forKey: doneKey) }
    private static var owesReady: Bool {
        UserDefaults.standard.bool(forKey: startedKey) && !UserDefaults.standard.bool(forKey: doneKey)
    }

    /// The step to show now, if any. "Who are you?" is handled by its own screen and counts as step 1.
    static func step(status: HelperStatus?, canRecord: Bool, idle: Bool) -> FirstRunStep? {
        guard enabled, idle else { return nil }
        // Linking goes through the helper, so the step is only offered while the helper is answering.
        if let status, status.isFresh, !status.linked, !skipped.contains(.link) { return .link }
        if status?.isFresh == true, status?.needsProfile == true { return nil }
        if !canRecord, !skipped.contains(.pictures) { return .pictures }
        return owesReady ? .ready : nil
    }
}

/// The numbered row across the top of every first-run screen.
struct StepRow: View {
    var current: Int
    var first = "Link this Mac"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 26) {
                ForEach(Array([first, "Allow screen pictures", "Ready"].enumerated()), id: \.offset) { index, name in
                    let number = index + 1
                    HStack(spacing: 9) {
                        Text("\(number)").font(.system(size: 12, weight: .bold))
                            .foregroundStyle(number < current ? Color.white : number == current ? Theme.onBrand : Theme.soft)
                            .frame(width: 22, height: 22)
                            .background(number < current ? Theme.good : number == current ? Theme.brand : Theme.raised, in: Circle())
                        Text(name).font(.system(size: 13, weight: number == current ? .bold : .medium))
                            .foregroundStyle(number == current ? Theme.ink : Theme.soft)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Step \(number): \(name)" + (number < current ? ", done" : number == current ? ", current" : ""))
                }
            }
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }
}

struct FirstRunView: View {
    var step: FirstRunStep
    var status: HelperStatus?
    /// Called when a step is left, so the next one (or the app) shows.
    var advance: () -> Void
    @StateObject private var linker = Linker()
    @State private var askedToRecord = false
    @FocusState private var nameFocused: Bool
    private let poll = Ticker.every1

    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 20) {
                StepRow(current: step.rawValue)
                switch step {
                case .link: link
                case .pictures: pictures
                case .ready: ready
                }
            }
            .padding(EdgeInsets(top: 48, leading: 40, bottom: 28, trailing: 40))
            .frame(maxWidth: 1100, maxHeight: .infinity, alignment: .topLeading)
            .frame(maxWidth: .infinity)
        }
        .onAppear { if step != .ready { FirstRun.noteStarted() } }
        .onReceive(poll) { _ in if step == .link { linker.refresh() } }
    }

    private func title(_ text: String, size: CGFloat = 42) -> some View {
        Text(text).font(Theme.title(size)).kerning(-1).foregroundStyle(Theme.ink)
    }

    private func numbered(_ number: Int, accent: Bool = false, _ text: Text) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)").font(.system(size: 12, weight: .bold))
                .foregroundStyle(accent ? Theme.onBrand : Theme.ink)
                .frame(width: 26, height: 26).background(accent ? Theme.brand : Theme.raised, in: Circle())
            text.font(.system(size: 14)).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3)
        }
    }

    // MARK: 1. Link this Mac

    private var link: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 14) {
                title("Link this Mac")
                Text("Type the code from the website. It joins this Mac to your household, and makes this login the chosen person's.")
                    .font(.system(size: 15)).foregroundStyle(Theme.soft).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(text: "Code from the website")
                    CodeField(code: $linker.code, size: 30, height: 64, fill: Theme.surface) { if linker.canLink { linker.link() } }
                }
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(text: "Name for this computer")
                    TextField("e.g. Mia's MacBook", text: $linker.deviceName)
                        .textFieldStyle(.plain).font(.system(size: 15))
                        .focused($nameFocused)
                        .padding(.horizontal, 16).frame(height: 46)
                        .field(focused: nameFocused)
                }
                if let message = linker.message {
                    Notice(text: message, tint: linker.messageIsError ? Theme.bad : Theme.good,
                           icon: linker.messageIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                }
                Spacer(minLength: 8)
                HStack(spacing: 14) {
                    Button(linker.waitingFor == nil ? "Link this computer" : "Linking…") { linker.link() }
                        .buttonStyle(PrimaryButtonStyle(wide: false))
                        .keyboardShortcut(.defaultAction)
                        .disabled(!linker.canLink)
                    Text("No account password is ever typed on this computer.")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.soft)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1.35)

            VStack(alignment: .leading, spacing: 14) {
                Text("Where is the code?").font(Theme.title(18)).foregroundStyle(Theme.ink)
                numbered(1, Text("A parent signs in on the YoungWonks Focus website, on any device."))
                numbered(2, Text("They open ") + Text("Computers").bold() + Text(", pick whose login this is, and choose ") + Text("Get a code").bold() + Text("."))
                numbered(3, Text("The code is shown there, and can be emailed. It works once."))
                Spacer(minLength: 8)
                Button("Open the website") {
                    if let url = URL(string: ServiceConfig.baseURL) { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(PrimaryButtonStyle(height: 46))
                Button("Link later. Sprints still work and are kept here.") {
                    FirstRun.skipped.insert(.link)
                    advance()
                }
                .buttonStyle(.plain)
                .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.brandText)
                .frame(maxWidth: .infinity).frame(height: 36)
            }
            .frame(width: 330, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .top)
            .card(padding: 22)
        }
    }

    // MARK: 2. Allow screen pictures

    private var pictures: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 14) {
                title("Allow screen pictures")
                Text("Screen Recording permission is needed so switches can be captured: a picture of the screen is saved when you switch away, so it can be reviewed later.")
                    .font(.system(size: 15)).foregroundStyle(Theme.soft).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 12) {
                    numbered(1, accent: !askedToRecord, Text("Choose ") + Text("Grant…").bold() + Text(" below. macOS opens System Settings."))
                    numbered(2, accent: askedToRecord, Text("Turn on ") + Text("YoungWonks Focus").bold() + Text(" in the list that opens."))
                    numbered(3, accent: askedToRecord, Text("Come back and choose ") + Text("Reopen").bold() + Text(". macOS only applies the change after the app reopens."))
                }
                .padding(.top, 4)
                Text("Already on, and this step keeps coming back? Select it in that list, remove it with the − button, choose Reopen, and allow it again.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.soft).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                HStack(spacing: 10) {
                    // macOS decides this once per launch: after the switch is turned on, the app has to be reopened.
                    if askedToRecord {
                        Button("Reopen") { AppRelaunch.now() }
                            .buttonStyle(PrimaryButtonStyle(wide: false)).keyboardShortcut(.defaultAction)
                        Button("Open Settings", action: openSettings).buttonStyle(OutlineButtonStyle(height: 50))
                    } else {
                        Button("Grant…", action: openSettings)
                            .buttonStyle(PrimaryButtonStyle(wide: false)).keyboardShortcut(.defaultAction)
                        Button("Reopen") { AppRelaunch.now() }.buttonStyle(OutlineButtonStyle(height: 50))
                    }
                    Button("Later") {
                        FirstRun.skipped.insert(.pictures)
                        advance()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.brandText)
                    .padding(.horizontal, 10).frame(height: 50)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1.2)

            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(text: "What you will see in System Settings")
                VStack(alignment: .leading, spacing: 12) {
                    Text("Screen & System Audio Recording").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.ink)
                    HStack(spacing: 12) {
                        Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 26, height: 26)
                        Text("YoungWonks Focus").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                        Spacer(minLength: 4)
                        PillShape().fill(Theme.good).frame(width: 40, height: 24)
                            .overlay(alignment: .trailing) { Circle().fill(.white).frame(width: 18, height: 18).padding(3) }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.brand, lineWidth: 1.5))
                }
                .padding(16)
                .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.hairline))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("A picture of the list in System Settings, with YoungWonks Focus switched on")
                Spacer(minLength: 8)
                Text("Nothing is ever blocked. Pictures are only for reviewing switches under History.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.soft).fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 360, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .top)
            .card(padding: 22)
        }
    }

    private func openSettings() {
        if !askedToRecord { CGRequestScreenCaptureAccess() }
        askedToRecord = true
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    // MARK: 3. Ready

    private var ready: some View {
        let name = status?.memberName ?? ""
        return VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "checkmark").font(.system(size: 24, weight: .bold)).foregroundStyle(Theme.goodText)
                .frame(width: 60, height: 60).background(Theme.goodTint, in: Circle())
                .accessibilityHidden(true)
            title(name.isEmpty ? "You're all set" : "You're all set, \(name)", size: 48)
            HStack(alignment: .top, spacing: 12) {
                fact("Start a sprint when you sit down to work", "Say what the task is and which apps and websites it needs.")
                fact("Switches are noticed, never blocked", "Anything else you open is saved with a picture you can review under History.")
                fact("A small meter stays on screen", "It shows the sprint clock and how distracted today has been.")
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            HStack(spacing: 14) {
                Button("Start my first sprint") {
                    FirstRun.finish()
                    advance()
                }
                .buttonStyle(PrimaryButtonStyle(wide: false, height: 52))
                .keyboardShortcut(.defaultAction)
                Text(status?.linked != true ? "This Mac is not linked to a household yet. Sprints still work and are kept here."
                     : status?.isAdult == true ? "Your records are private: only you can see them, on your own sign-in."
                     : "A household admin can see what this login records.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.soft)
            }
        }
    }

    private func fact(_ heading: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(heading).font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
            Text(detail).font(.system(size: 13.5)).foregroundStyle(Theme.soft).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card(padding: 18)
    }
}
