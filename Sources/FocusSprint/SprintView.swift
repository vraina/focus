import AppKit
import SwiftUI
import FocusSprintCore

struct SprintView: View {
    @EnvironmentObject var engine: SprintEngine
    @AppStorage("task") private var task = ""
    @AppStorage("minutes") private var minutes = 25
    @AppStorage("domains") private var domains = ""
    @AppStorage("allowedApps") private var allowedJSON = "[]"
    @State private var running: [AllowedApp] = []
    @State private var canRecord = CGPreflightScreenCaptureAccess()
    @State private var helperReady = Paths.helperInstalled

    private var allowed: [AllowedApp] {
        (try? JSONDecoder().decode([AllowedApp].self, from: Data(allowedJSON.utf8))) ?? []
    }
    private var canStart: Bool {
        helperReady && canRecord && !(allowed.isEmpty && FocusRules.parseList(domains).isEmpty)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !helperReady {
                    Notice(text: "The YoungWonks Focus helper is not installed on this Mac. A parent needs to run scripts/install.sh once.", tint: Theme.bad)
                }
                if !canRecord {
                    HStack(spacing: 10) {
                        Notice(text: "Screen Recording permission is needed so switches can be captured.", tint: Theme.warn)
                        Button("Grant…") {
                            CGRequestScreenCaptureAccess()
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                        }
                    }
                }
                switch engine.phase {
                case .idle: setup
                case .running: live
                case .onBreak: onBreak
                }
            }
            .padding(28)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func refresh() {
        canRecord = CGPreflightScreenCaptureAccess()
        helperReady = Paths.helperInstalled
        let me = ProcessInfo.processInfo.processIdentifier
        var seen = Set<String>()
        running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != me }
            .compactMap { app -> AllowedApp? in
                guard let id = app.bundleIdentifier, ActivityMonitor.browsers[id] == nil, seen.insert(id).inserted else { return nil }
                return AllowedApp(bundleId: id, name: app.localizedName ?? id)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func toggle(_ app: AllowedApp) {
        var list = allowed.filter { $0.bundleId != app.bundleId }
        if list.count == allowed.count { list.append(app) }
        allowedJSON = String(data: (try? JSONEncoder().encode(list)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
    }

    // MARK: Setup

    private var setup: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Ready to focus?").font(Theme.title(30))
                Text("Pick what this task needs. Anything else you switch to gets noticed.")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
            }
            .padding(.bottom, 2)

            if let summary = engine.lastSummary { summaryCard(summary) }

            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "What are you working on?")
                TextField("e.g. Algebra homework, chapter 4", text: $task)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17, weight: .medium))
            }
            .card()

            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "How long?")
                HStack(spacing: 8) {
                    ForEach([15, 25, 45, 60], id: \.self) { value in
                        Chip(title: "\(value) min", selected: minutes == value) { minutes = value }
                    }
                }
            }
            .card()

            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Websites you need")
                TextField("khanacademy.org, docs.google.com", text: $domains)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                Text("Sites already known to be productive count automatically. A quick tab switch to anything else is recorded.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .card()

            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Apps you need")
                let all = running + allowed.filter { saved in !running.contains { $0.bundleId == saved.bundleId } }
                if all.isEmpty {
                    Text("Open the apps you will use, then come back here.").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(all) { app in
                        Chip(title: app.name, selected: allowed.contains { $0.bundleId == app.bundleId },
                             icon: AppIcons.icon(bundleId: app.bundleId)) { toggle(app) }
                    }
                }
            }
            .card()

            if let error = engine.startError { Notice(text: error, tint: Theme.bad) }

            Button {
                engine.startSprint(task: task.trimmingCharacters(in: .whitespaces), minutes: minutes,
                                   allowedApps: allowed, domains: FocusRules.parseList(domains))
            } label: {
                Label("Start \(minutes) minute sprint", systemImage: "play.fill")
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(!canStart)

            Text(canStart ? "Nothing is ever blocked. Switches are saved with a picture so you can review them under History."
                          : "Choose at least one website or app to start.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func summaryCard(_ summary: SprintSummary) -> some View {
        let tint = levelColor(1 - Double(summary.focusPercent) / 100)
        return HStack(spacing: 16) {
            ZStack {
                Ring(progress: Double(summary.focusPercent) / 100, lineWidth: 7, tint: tint)
                Text("\(summary.focusPercent)%").font(Theme.number(15))
            }
            .frame(width: 60, height: 60)
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.status == .completed ? "Sprint complete" : "Sprint ended early").font(Theme.title(17))
                Text("\(summary.focusPercent)% focused · \(summary.switches) switches · \(Format.duration(summary.awaySeconds)) away")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Take a 5 min break") { engine.startBreak(minutes: 5) }
                .controlSize(.large)
        }
        .card()
    }

    // MARK: Running

    private var live: some View {
        let _ = engine.pulse
        return VStack(spacing: 22) {
            VStack(spacing: 6) {
                SectionLabel(text: "Focusing on")
                Text(engine.start?.task ?? "").font(Theme.title(22)).multilineTextAlignment(.center)
            }
            ZStack {
                Ring(progress: engine.sprintProgress, lineWidth: 16, tint: nil)
                VStack(spacing: 2) {
                    Text(SprintEngine.clock(engine.remaining)).font(Theme.number(68))
                    Text("remaining").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 280, height: 280)
            .padding(.vertical, 4)

            if let away = engine.awayNow {
                Pill(text: "Away: \(away.label) · \(SprintEngine.clock(Date().timeIntervalSince(away.since)))",
                     tint: Theme.bad, icon: "exclamationmark.triangle.fill")
                    .scaleEffect(1.25)
            } else {
                Pill(text: "On task", tint: Theme.good, icon: "checkmark.circle.fill").scaleEffect(1.25)
            }

            HStack(spacing: 12) {
                StatTile(title: "Switches", value: "\(engine.sprintSwitches)", icon: "arrow.left.arrow.right")
                StatTile(title: "Time away", value: Format.duration(engine.sprintAway), icon: "clock")
                StatTile(title: "Distraction", value: "\(Int((engine.sprintDistraction * 100).rounded()))%",
                         color: levelColor(engine.sprintDistraction), icon: "gauge.medium")
            }
            .padding(.top, 6)

            Button("End sprint early") { engine.stopEarly() }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.bad)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var onBreak: some View {
        let _ = engine.pulse
        return VStack(spacing: 18) {
            Image(systemName: "cup.and.saucer.fill").font(.system(size: 40)).foregroundStyle(Theme.gradient)
            Text("Break").font(Theme.title(30))
            Text(SprintEngine.clock(engine.remaining)).font(Theme.number(68))
            Text("Nothing is tracked during a break.").font(.system(size: 13)).foregroundStyle(.secondary)
            Button("Skip break") { engine.stopEarly() }.controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}
