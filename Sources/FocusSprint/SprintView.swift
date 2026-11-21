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
    @State private var askedToRecord = false
    /// The apps ticked for the sprint being set up, once the person has changed a tick. Nil = the defaults.
    @State private var picked: Set<String>?
    @State private var linked = HelperStatus.load()?.linked ?? true
    /// A website being typed, not yet turned into a tag.
    @State private var siteDraft = ""
    private enum Field { case task, site }
    @FocusState private var focus: Field?
    /// The sites as tags. Kept the way they always were: one line of text in the "domains" setting.
    private var sites: [String] {
        var seen = Set<String>()
        return FocusRules.parseList(domains).filter { seen.insert($0).inserted }
    }

    private var allowed: [AllowedApp] {
        (try? JSONDecoder().decode([AllowedApp].self, from: Data(allowedJSON.utf8))) ?? []
    }
    /// What is ticked to begin with: the person's Work apps. A Mac with no labels yet (not linked) falls back
    /// to whatever was ticked last time.
    private var hasLabels: Bool { !engine.apps.entries.isEmpty }
    private var defaults: Set<String> {
        hasLabels ? Set(engine.apps.entries.filter { $0.value.state == "work" }.keys) : Set(allowed.map { $0.bundleId.lowercased() })
    }
    private var ticked: Set<String> { picked ?? defaults }
    /// Running apps, plus Work apps and anything ticked that is not running right now.
    private var choices: [AllowedApp] {
        var list = running
        var seen = Set(running.map { $0.bundleId.lowercased() })
        for entry in engine.apps.sorted where entry.state == "work" && seen.insert(entry.id).inserted {
            list.append(AllowedApp(bundleId: entry.bundleId, name: entry.name))
        }
        for saved in allowed where seen.insert(saved.bundleId.lowercased()).inserted { list.append(saved) }
        return list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    private var chosen: [AllowedApp] { choices.filter { ticked.contains($0.bundleId.lowercased()) } }
    private var canStart: Bool {
        helperReady && canRecord && !(chosen.isEmpty && FocusRules.parseList(domains).isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    notices
                    switch engine.phase {
                    case .idle:
                        if let summary = engine.lastSummary { finished(summary) } else { setup }
                    case .running: Ticking { live }
                    case .onBreak: Ticking { onBreak }
                    }
                }
                .padding(EdgeInsets(top: 44, leading: 30, bottom: 16, trailing: 30))
                .frame(maxWidth: 860, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            if engine.phase == .idle, engine.lastSummary == nil { startRow }
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    @ViewBuilder private var notices: some View {
        if !helperReady {
            Notice(text: AppRelaunch.isInstalledCopy
                   ? "The YoungWonks Focus helper is not installed on this Mac. Run the installer once from an administrator account."
                   : "This copy of the app was opened from \(Bundle.main.bundleURL.deletingLastPathComponent().path), and the installer has not been run on this Mac. Run YoungWonksFocus.pkg, then use the app it puts in Applications.",
                   tint: Theme.bad)
        }
        if helperReady && !linked {
            Notice(text: "This Mac is not linked to a household yet. Sprints still work and are kept here; open Account to link it.",
                   tint: Theme.warn, icon: "link")
        }
        if !canRecord {
            // macOS decides this once per launch: after the switch is turned on, the app has to be reopened
            // before it can record. Asking again without reopening never succeeds.
            HStack(spacing: 10) {
                Notice(text: askedToRecord
                       ? "Turn on YoungWonks Focus in the list that opened, then choose Reopen. If it is already on and this message keeps coming back, select it there, remove it with the − button, choose Reopen, and allow it again."
                       : "Screen Recording permission is needed so switches can be captured.", tint: Theme.warn)
                if askedToRecord {
                    Button("Reopen") { AppRelaunch.now() }.buttonStyle(OutlineButtonStyle()).keyboardShortcut(.defaultAction)
                }
                Button(askedToRecord ? "Open Settings" : "Grant…") {
                    if !askedToRecord { CGRequestScreenCaptureAccess() }
                    askedToRecord = true
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
                .buttonStyle(OutlineButtonStyle())
            }
        }
    }

    private func refresh() {
        canRecord = CGPreflightScreenCaptureAccess()
        helperReady = Paths.helperInstalled
        linked = HelperStatus.load()?.linked ?? true
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
        var now = ticked
        let key = app.bundleId.lowercased()
        if now.remove(key) == nil { now.insert(key) }
        picked = now == defaults ? nil : now
        if !hasLabels { remember(choices.filter { now.contains($0.bundleId.lowercased()) }); picked = nil }
    }

    private func remember(_ list: [AllowedApp]) {
        allowedJSON = String(data: (try? JSONEncoder().encode(list)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
    }

    // MARK: Setup

    /// Turns what has been typed or pasted into tags. A pasted list separated by commas, spaces or new
    /// lines becomes one tag per site.
    private func addSites(_ text: String) {
        let added = FocusRules.parseList(text)
        siteDraft = ""
        guard !added.isEmpty else { return }
        var seen = Set<String>()
        domains = (sites + added).filter { seen.insert($0).inserted }.joined(separator: ", ")
    }

    private func removeSite(_ site: String) {
        domains = sites.filter { $0 != site }.joined(separator: ", ")
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Ready to focus?").font(Theme.title(34)).kerning(-0.8).foregroundStyle(Theme.ink)
                Text("Pick what this task needs. Anything else you switch to gets noticed.")
                    .font(.system(size: 14)).foregroundStyle(Theme.soft)
            }

            VStack(alignment: .leading, spacing: 5) {
                SectionLabel(text: "What are you working on?")
                TextField("e.g. Algebra homework, chapter 4", text: $task)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17, weight: .semibold))
                    .focused($focus, equals: .task)
                    .padding(.horizontal, 16)
                    .frame(height: 48)
                    .field(focused: focus == .task)
            }

            VStack(alignment: .leading, spacing: 5) {
                SectionLabel(text: "How long?")
                Segments(label: "How long",
                         options: [15, 25, 45, 60].map { (value: $0, title: "\($0) min") } + [(value: 0, title: "Until I stop")],
                         selection: $minutes)
                if minutes == 0 {
                    Text("No timer. The sprint keeps going, and keeps noticing switches, until you end it.")
                        .font(.system(size: 12)).foregroundStyle(Theme.soft)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                SectionLabel(text: "Websites you need")
                Flow(spacing: 6, fillLast: true) {
                    ForEach(sites, id: \.self) { site in
                        HStack(spacing: 2) {
                            Text(site).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Button { removeSite(site) } label: {
                                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                                    .frame(width: 24, height: 24).contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(site)")
                        }
                        .foregroundStyle(Theme.goodText)
                        .padding(.leading, 12).padding(.trailing, 4)
                        .frame(height: 30)
                        .background(Theme.goodTint, in: PillShape())
                    }
                    TextField(sites.isEmpty ? "khanacademy.org, docs.google.com" : "Type a website and press Return", text: $siteDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .focused($focus, equals: .site)
                        .padding(.horizontal, 6)
                        .frame(height: 30)
                        .onSubmit { addSites(siteDraft) }
                        .onChange(of: siteDraft) { _, text in
                            // A separator means a whole site (or a pasted list) is in: make the tags now.
                            if text.contains(where: { $0 == "," || $0 == " " || $0 == "\n" }) { addSites(text) }
                        }
                        .accessibilityLabel("Add a website")
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .frame(minHeight: 46)
                .field(focused: focus == .site)
                .contentShape(Rectangle())
                .onTapGesture { focus = .site }
                Text("Sites already known to be productive count automatically. A quick tab switch to anything else is recorded.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.soft)
            }

            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Apps you need")
                let all = choices
                if all.isEmpty {
                    Text("Open the apps you will use, then come back here.").font(.system(size: 13)).foregroundStyle(Theme.soft)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(all) { app in
                        AppPill(name: app.name, icon: AppIcons.icon(bundleId: app.bundleId),
                                ticked: ticked.contains(app.bundleId.lowercased())) { toggle(app) }
                    }
                }
                if hasLabels {
                    HStack(spacing: 6) {
                        Text(picked == nil ? "Your Work apps are ticked. Changes here apply to this sprint only."
                                           : "Changed for this sprint only. The sprint's record shows what was changed.")
                            .font(.system(size: 12)).foregroundStyle(Theme.soft)
                        if picked != nil {
                            Button("Reset") { picked = nil }.buttonStyle(.link).font(.system(size: 12))
                        }
                    }
                    .padding(.top, 2)
                }
            }

            if let error = engine.startError { Notice(text: error, tint: Theme.bad) }
        }
    }

    /// Stays at the bottom of the window however long the list of apps is.
    private var startRow: some View {
        HStack(spacing: 14) {
            Button(minutes == 0 ? "Start sprint" : "Start \(minutes) minute sprint") {
                addSites(siteDraft) // a site typed but not yet entered still counts
                engine.startSprint(task: task.trimmingCharacters(in: .whitespaces), minutes: minutes,
                                   allowedApps: chosen, domains: FocusRules.parseList(domains),
                                   defaultApps: hasLabels ? defaults : nil)
                picked = nil // the next sprint starts from the Work apps again
            }
            .buttonStyle(PrimaryButtonStyle(wide: false))
            // Return starts the sprint, except while a website is being typed: there it enters the website.
            .keyboardShortcut(siteDraft.isEmpty ? .defaultAction : nil)
            .disabled(!canStart)

            Text(canStart ? "Nothing is ever blocked. Switches are saved with a picture so you can review them under History."
                          : "Choose at least one website or app to start.")
                .font(.system(size: 12)).foregroundStyle(Theme.soft)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(EdgeInsets(top: 12, leading: 30, bottom: 24, trailing: 30))
        .frame(maxWidth: 860)
        .frame(maxWidth: .infinity)
        .background(Theme.canvas)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    // MARK: Finished

    /// Shown once when a sprint ends. Both buttons leave it, and so does going anywhere else in the app.
    private func finished(_ summary: SprintSummary) -> some View {
        let whole = max(1, summary.elapsed)
        let arcs = [RingArc(from: 0, to: 1, color: Theme.good)]
            + summary.visits.map { RingArc(from: $0.from / whole, to: $0.to / whole, color: $0.distraction ? Theme.bad : Theme.warn) }
        return VStack(spacing: 12) {
            Text(summary.status == .completed ? "Sprint complete" : "Sprint ended early")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.soft)
            Text(summary.task).font(Theme.title(24)).foregroundStyle(Theme.ink).multilineTextAlignment(.center)
            ZStack {
                ArcRing(arcs: arcs, lineWidth: 12)
                VStack(spacing: 4) {
                    Text("\(summary.focusPercent)%").font(Theme.number(66)).kerning(-2)
                        .foregroundStyle(Theme.text(for: levelColor(1 - Double(summary.focusPercent) / 100)))
                    Text("focused").font(.system(size: 13)).foregroundStyle(Theme.soft)
                }
            }
            .frame(width: 240, height: 240)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(summary.focusPercent) percent focused. The full circle is the sprint, with red and amber arcs for the switches away.")
            Text("\(summary.switches) \(summary.switches == 1 ? "switch" : "switches") · \(Format.duration(summary.awaySeconds)) away · \(Format.duration(summary.elapsed))")
                .font(.system(size: 14)).foregroundStyle(Theme.soft)
            HStack(spacing: 10) {
                Button("Take a 5 min break") { engine.startBreak(minutes: 5) }
                    .buttonStyle(PrimaryButtonStyle(wide: false))
                Button("Start another sprint") { engine.clearSummary() }
                    .buttonStyle(OutlineButtonStyle(height: 50))
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
        .onDisappear { if engine.phase == .idle { engine.clearSummary() } }
    }

    // MARK: Running

    private var live: some View {
        let _ = engine.pulse
        return VStack(spacing: 12) {
            VStack(spacing: 4) {
                SectionLabel(text: "Focusing on")
                Text(engine.start?.task ?? "").font(Theme.title(24)).foregroundStyle(Theme.ink).multilineTextAlignment(.center)
            }
            ZStack {
                ArcRing(arcs: engine.sprintArcs, lineWidth: 11)
                VStack(spacing: 4) {
                    Text(SprintEngine.clock(engine.clockSeconds)).font(Theme.number(engine.clockSeconds >= 6000 ? 54 : 66)).kerning(-2)
                        .foregroundStyle(Theme.ink)
                    Text(engine.isOpenEnded ? "so far · until you stop" : "remaining").font(.system(size: 13)).foregroundStyle(Theme.soft)
                }
            }
            .frame(width: 260, height: 260)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(engine.isOpenEnded
                ? "\(SprintEngine.clock(engine.clockSeconds)) so far. The full circle is the time so far, with red and amber where you were away."
                : "\(SprintEngine.clock(engine.clockSeconds)) remaining. The full circle is the planned sprint. The coloured part is the time so far, with red and amber where you were away.")
            LegendRow(items: [("On task", Theme.brand), ("Distraction", Theme.bad), ("Off task", Theme.warn)]
                             + (engine.isOpenEnded ? [] : [("Still to go", Theme.track)]))

            Group {
                if let away = engine.awayNow {
                    Text("Away: \(away.label) · \(SprintEngine.clock(Date().timeIntervalSince(away.since)))")
                        .foregroundStyle(.white).padding(.horizontal, 18).padding(.vertical, 7)
                        .background(Theme.badFill, in: PillShape())
                } else {
                    Text("On task")
                        .foregroundStyle(Theme.goodText).padding(.horizontal, 18).padding(.vertical, 7)
                        .background(Theme.goodTint, in: PillShape())
                }
            }
            .font(.system(size: 15, weight: .bold)).lineLimit(1)
            .padding(.top, 4)

            HStack(spacing: 10) {
                StatTile(title: "Switches", value: "\(engine.sprintSwitches)")
                StatTile(title: "Time away", value: Format.duration(engine.sprintAway))
                StatTile(title: "Distraction", value: "\(Int((engine.sprintDistraction * 100).rounded()))%",
                         color: Theme.text(for: levelColor(engine.sprintDistraction)))
            }
            .frame(maxWidth: 460)

            Button(engine.isOpenEnded ? "End sprint" : "End sprint early") { engine.stopEarly() }
                .buttonStyle(OutlineButtonStyle(tint: Theme.badText))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var onBreak: some View {
        let _ = engine.pulse
        return VStack(spacing: 12) {
            SectionLabel(text: "Break")
            ZStack {
                ArcRing(arcs: engine.breakArcs, lineWidth: 11)
                VStack(spacing: 4) {
                    Text(SprintEngine.clock(engine.remaining)).font(Theme.number(66)).kerning(-2).foregroundStyle(Theme.ink)
                    Text("remaining").font(.system(size: 13)).foregroundStyle(Theme.soft)
                }
            }
            .frame(width: 260, height: 260)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(SprintEngine.clock(engine.remaining)) of the break remaining. The full circle is the break; the coloured part is the time used.")
            Text("Nothing is tracked during a break.").font(.system(size: 14)).foregroundStyle(Theme.soft)
            Button("Skip break") { engine.stopEarly() }
                .buttonStyle(OutlineButtonStyle(height: 46))
                .padding(.top, 10)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }
}

/// One app in the "Apps you need" grid: its icon and name, lighter violet with a tick when it is ticked.
private struct AppPill: View {
    var name: String
    var icon: NSImage?
    var ticked: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if let icon {
                    Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                } else {
                    Image(systemName: "app").font(.system(size: 16)).frame(width: 22, height: 22)
                }
                Text(name).font(.system(size: 14, weight: ticked ? .bold : .medium)).lineLimit(1).truncationMode(.tail)
                if ticked { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)) }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .foregroundStyle(ticked ? Theme.onTicked : Theme.ink)
            .background(ticked ? Theme.ticked : Theme.raised, in: PillShape())
            .contentShape(PillShape())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityValue(ticked ? "Needed for this sprint" : "Not needed")
        .accessibilityAddTraits(ticked ? .isSelected : [])
    }
}
