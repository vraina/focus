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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !helperReady {
                    banner("The YoungWonks Focus vault helper is not installed on this Mac. A parent needs to run scripts/install.sh once.", .red)
                }
                if !canRecord {
                    HStack {
                        banner("Screen Recording permission is needed so switches can be captured.", .orange)
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
            .padding(24)
            .frame(maxWidth: 640, alignment: .leading)
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

    private func banner(_ text: String, _ color: Color) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(color)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Setup

    private var setup: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let summary = engine.lastSummary {
                VStack(alignment: .leading, spacing: 6) {
                    Text(summary.status == .completed ? "Sprint complete" : "Sprint ended early").font(.headline)
                    Text("\(summary.focusPercent)% focused · \(summary.switches) switches · \(Format.duration(summary.awaySeconds)) away")
                        .font(.title3.bold())
                        .foregroundStyle(levelColor(1 - Double(summary.focusPercent) / 100))
                    Button("Take a 5 minute break") { engine.startBreak(minutes: 5) }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            }

            Text("New sprint").font(.largeTitle.bold())

            VStack(alignment: .leading, spacing: 6) {
                Text("What are you working on?").font(.headline)
                TextField("e.g. Algebra homework, chapter 4", text: $task).textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("How long?").font(.headline)
                Picker("", selection: $minutes) {
                    ForEach([15, 25, 45, 60], id: \.self) { Text("\($0) min").tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Websites you need").font(.headline)
                TextField("khanacademy.org, docs.google.com", text: $domains).textFieldStyle(.roundedBorder)
                Text("Any other site, including a quick tab switch, is recorded as a switch away.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Apps you need").font(.headline)
                let all = (running + allowed.filter { saved in !running.contains { $0.bundleId == saved.bundleId } })
                if all.isEmpty {
                    Text("Open the apps you will use, then come back here.").foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach(all) { app in
                        Toggle(app.name, isOn: Binding(
                            get: { allowed.contains { $0.bundleId == app.bundleId } },
                            set: { on in
                                var list = allowed.filter { $0.bundleId != app.bundleId }
                                if on { list.append(app) }
                                allowedJSON = String(data: (try? JSONEncoder().encode(list)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
                            }))
                    }
                }
            }

            if let error = engine.startError { banner(error, .red) }

            Button {
                engine.startSprint(task: task.trimmingCharacters(in: .whitespaces), minutes: minutes,
                                   allowedApps: allowed, domains: FocusRules.parseList(domains))
            } label: {
                Text("Start sprint").font(.title3.bold()).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!helperReady || !canRecord || (allowed.isEmpty && FocusRules.parseList(domains).isEmpty))

            Text("During a sprint, every switch to something not listed above is saved with a picture of the screen. You can review all of it under History. Outside a sprint, only visits to the known distractions listed under Parent settings are recorded.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Running

    private var live: some View {
        let _ = engine.pulse
        return VStack(spacing: 22) {
            Text(engine.start?.task ?? "").font(.title2)
            ZStack {
                Circle().stroke(Color.primary.opacity(0.1), lineWidth: 14)
                Circle().trim(from: 0, to: engine.sprintProgress)
                    .stroke(Color.blue, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(SprintEngine.clock(engine.remaining)).font(.system(size: 64, weight: .bold)).monospacedDigit()
            }
            .frame(width: 260, height: 260)

            if let away = engine.awayNow {
                Label("Away: \(away.label) · \(SprintEngine.clock(Date().timeIntervalSince(away.since)))",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.title3.bold()).foregroundStyle(.red)
            } else {
                Label("On task", systemImage: "checkmark.circle.fill").font(.title3.bold()).foregroundStyle(.green)
            }

            HStack(spacing: 14) {
                StatTile(title: "Switches", value: "\(engine.sprintSwitches)")
                StatTile(title: "Time away", value: Format.duration(engine.sprintAway))
                StatTile(title: "Distraction", value: "\(Int((engine.sprintDistraction * 100).rounded()))%",
                         color: levelColor(engine.sprintDistraction))
            }
            Button("End sprint early", role: .destructive) { engine.stopEarly() }
        }
        .frame(maxWidth: .infinity)
    }

    private var onBreak: some View {
        let _ = engine.pulse
        return VStack(spacing: 16) {
            Text("Break").font(.largeTitle.bold())
            Text(SprintEngine.clock(engine.remaining)).font(.system(size: 64, weight: .bold)).monospacedDigit()
            Text("Nothing is tracked during a break.").foregroundStyle(.secondary)
            Button("Skip break") { engine.stopEarly() }
        }
        .frame(maxWidth: .infinity)
    }
}

struct StatTile: View {
    var title: String
    var value: String
    var color: Color = .primary

    var body: some View {
        VStack(spacing: 4) {
            Text(value).font(.system(size: 26, weight: .bold)).monospacedDigit().foregroundStyle(color)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }
}
