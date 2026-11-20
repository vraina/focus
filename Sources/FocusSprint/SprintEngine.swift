import AppKit
import FocusSprintCore

struct AllowedApp: Codable, Hashable, Identifiable {
    var bundleId: String
    var name: String
    var id: String { bundleId }
}

struct SprintSummary {
    var task: String
    var status: SprintStatus
    var focusPercent: Int
    var switches: Int
    var awaySeconds: Double
}

@MainActor
final class SprintEngine: ObservableObject {
    static let shared = SprintEngine()

    enum Phase { case idle, running, onBreak }

    @Published private(set) var phase: Phase = .idle
    /// Bumped twice a second so the timer, live counters and floating meter redraw.
    @Published private(set) var pulse = 0
    /// Goes up each time a finished visit has been written to disk, so History can refresh at once.
    @Published private(set) var savedVisits = 0
    /// The screen is checked four times a second; the windows redraw on every second check.
    static let tickSeconds = 0.25
    private var ticks = 0
    @Published private(set) var lastSummary: SprintSummary?
    @Published private(set) var startError: String?

    private(set) var start: SprintStart?
    private(set) var endsAt = Date()
    private(set) var breakEndsAt = Date()
    private(set) var awayNow: (label: String, since: Date, category: EventCategory, host: String?)?
    /// Website labels (AI and parent decisions), kept current by the helper.
    private(set) var sites = SiteBook()
    private var sitesStamp: Date?
    /// How each app counts for this person (from the website). Empty until the Mac is linked and labels arrive.
    @Published private(set) var apps = AppBook()
    private var appsStamp: Date?
    private var appAsked: [String: Date] = [:]
    private var labelRequested: [String: Date] = [:]
    /// Requests sent and not answered yet: request id -> website.
    private var pendingRequests: [String: String] = [:]
    private var answersStamp: Date?
    /// The reviewer's latest answer, for the app to show to the student.
    @Published var answer: RequestAnswer?
    /// Today's time away per website, for the totals that leave out sites under review.
    private var awayByHost: [String: Double] = [:]

    private struct OpenVisit {
        var key: String
        var startedAt: Date
        var context: ActivityContext
        var category: EventCategory
        var recorder: EventRecorder
        var seq: Int
        var session: SprintStart
    }

    /// A stretch of all-day tracking outside sprints. Closed and restarted every half hour so that
    /// at most that much "screen in use" time is lost if the app is killed.
    private struct Ambient {
        var start: SprintStart
        var active = 0.0
        var away = 0.0
        var switches = 0
        var lastActive: Date
    }
    private static let ambientMaxSeconds = 1800.0
    private static let idleAfterSeconds = 120.0

    private let monitor = ActivityMonitor()
    private let capturer = ScreenCapturer()
    private var config = ParentConfig.load()
    private var rules: FocusRules?
    private var open: OpenVisit?
    private var closedAway = 0.0
    private var switches = 0
    private var timer: Timer?
    private var ambient: Ambient?
    private var ambientRules: FocusRules?
    private var lastTick = Date()

    // Totals for sprints already finished today.
    private var day = Calendar.current.startOfDay(for: Date())
    private var baseSprint = 0.0
    private var baseAway = 0.0
    private var baseSwitches = 0

    private init() {
        Timing.measure("loadDay") { loadDay() }
        let timer = Timer(timeInterval: SprintEngine.tickSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // App switches are caught the instant they happen, not just on the next half-second tick.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase == .running else { return }
                self.observe()
            }
        }
    }

    // MARK: Live numbers

    var remaining: TimeInterval { max(0, (phase == .onBreak ? breakEndsAt : endsAt).timeIntervalSinceNow) }
    var sprintElapsed: Double { phase == .running ? Date().timeIntervalSince(start?.startedAt ?? Date()) : 0 }
    var sprintAway: Double { phase == .running ? closedAway + (open.map { Date().timeIntervalSince($0.startedAt) } ?? 0) : 0 }
    var sprintSwitches: Int { phase == .running ? switches : 0 }
    var sprintProgress: Double {
        guard phase == .running, let start else { return 0 }
        return min(1, sprintElapsed / Double(max(1, start.plannedSeconds)))
    }
    var sprintDistraction: Double { sprintElapsed > 0 ? min(1, sprintAway / sprintElapsed) : 0 }
    private var ambientAwayLive: Double {
        guard let ambient else { return 0 }
        return ambient.away + (open.map { $0.session.isAmbient ? Date().timeIntervalSince($0.startedAt) : 0 } ?? 0)
    }
    /// Tracked time today: sprint time plus time the Mac was in use outside sprints.
    var todaySprintSeconds: Double { baseSprint + sprintElapsed + (ambient?.active ?? 0) }
    var todayAway: Double { baseAway + sprintAway + ambientAwayLive }
    var todaySwitches: Int { baseSwitches + sprintSwitches + (ambient?.switches ?? 0) }
    var todayDistraction: Double { todaySprintSeconds > 0 ? min(1, todayAway / todaySprintSeconds) : 0 }
    /// Today's time away on sites the student marked "needed for work" (or the parent has since allowed).
    var todayAwayUnderReview: Double {
        var total = awayByHost.reduce(0) { $0 + (sites.isCleared($1.key) ? $1.value : 0) }
        if let visit = open, let host = visit.context.host, sites.isCleared(host) {
            total += Date().timeIntervalSince(visit.startedAt)
        }
        return total
    }
    var todayDistractionStrict: Double {
        todaySprintSeconds > 0 ? min(1, max(0, todayAway - todayAwayUnderReview) / todaySprintSeconds) : 0
    }

    // MARK: "Needed for work"

    enum DisputeOption { case available, sent, closed }

    func disputeOption(for host: String) -> DisputeOption {
        if pendingRequests.values.contains(host) { return .sent }
        if sites.state(for: host) == .locked || sites.isCleared(host) { return .closed }
        return .available // a turned-down request can be made again with a better reason
    }

    /// Queued through the helper, so it is reviewed even if the Mac is offline right now.
    func dispute(host: String, reason: String, minutes: Int, permanent: Bool) {
        let id = UUID().uuidString.lowercased()
        let listed = config.distractionDomains.map(FocusRules.normalize).contains { host == $0 || host.hasSuffix("." + $0) }
        let request = SiteRequest(kind: "dispute", host: host, reason: reason, user: NSUserName(),
                                  device: Host.current().localizedName ?? "Mac", id: id, minutes: minutes,
                                  permanent: permanent, onParentList: listed)
        if (try? request.drop()) != nil { pendingRequests[id] = host }
    }

    private func collectAnswers() {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: Paths.answers.path))?[.modificationDate] as? Date
        guard !pendingRequests.isEmpty, stamp != answersStamp else { return }
        answersStamp = stamp
        for reply in AnswerList.load() where pendingRequests[reply.id] != nil {
            pendingRequests[reply.id] = nil
            answer = reply
        }
    }

    // MARK: Searches

    private var seenSearches: [String: Date] = [:]
    private var searchesStamp: Date?
    /// Today's labelled searches.
    private(set) var searchCounts: (work: Int, distraction: Int, personal: Int) = (0, 0, 0)

    /// When the tab in front is a search results page, sends the search for labelling (once per search).
    private func noteSearch(_ context: ActivityContext) {
        guard context.isBrowser, let address = context.url, let found = SearchQuery.parse(address) else { return }
        let key = found.query.lowercased()
        if let last = seenSearches[key], Date().timeIntervalSince(last) < 1800 { return }
        seenSearches[key] = Date()
        try? SiteRequest(kind: "search", host: found.engine, user: NSUserName(), device: Host.current().localizedName ?? "Mac",
                         id: UUID().uuidString.lowercased(), query: found.query,
                         task: phase == .running ? start?.task : nil).drop()
    }

    private func reloadSearchesIfChanged() {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: Paths.searches.path))?[.modificationDate] as? Date
        guard stamp != searchesStamp else { return }
        searchesStamp = stamp
        let today = SearchLog.load().filter { ($0.date ?? .distantPast) >= day }
        searchCounts = SearchLog.counts(today)
    }

    /// Asks for an AI label the first time a site is seen. True while the answer is still on its way.
    private func awaitingLabel(_ context: ActivityContext, rules: FocusRules) -> Bool {
        guard context.isBrowser, let host = context.host, SiteRequest.isValidHost(host),
              rules.siteCountsAsDistraction(host, sites: sites) == nil else { return false }
        if let asked = labelRequested[host] { return Date().timeIntervalSince(asked) < 25 }
        labelRequested[host] = Date()
        try? SiteRequest(kind: "classify", host: host).drop()
        return true
    }

    private func reloadSitesIfChanged() {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: Paths.sites.path))?[.modificationDate] as? Date
        guard stamp != sitesStamp else { return }
        sitesStamp = stamp
        sites = SiteBook(file: Paths.sites)
    }

    /// Reads the labels straight away (the regular reload runs on the engine's tick).
    func loadAppLabels() { appsStamp = nil; reloadAppsIfChanged() }

    private func reloadAppsIfChanged() {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: Paths.apps.path))?[.modificationDate] as? Date
        guard stamp != appsStamp else { return }
        appsStamp = stamp
        apps = AppBook(file: Paths.apps)
        rules?.appLabels = apps.labels
        ambientRules?.appLabels = apps.labels
    }

    /// Asks for a label the first time an app is seen in use. Browsers are left out: their time is judged per website.
    private func noteApp(_ context: ActivityContext) {
        guard !context.isSelf, !context.isBrowser, !FocusRules.systemOverlays.contains(context.bundleId),
              apps.state(for: context.bundleId) == nil else { return }
        let key = context.bundleId.lowercased()
        if let asked = appAsked[key], Date().timeIntervalSince(asked) < 600 { return } // not labelled yet: ask again later
        appAsked[key] = Date()
        try? SiteRequest.app(bundleId: context.bundleId, name: context.appName)?.drop()
    }

    /// The floating meter stays hidden while the day is clean and appears once there is real distraction.
    var meterVisible: Bool { awayNow != nil || todayAway > 0 }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: Sprint control

    /// `defaultApps`: the bundle ids that were ticked to begin with (the person's Work apps). What the person
    /// ticked or unticked on top of that is written into the sprint's record.
    func startSprint(task: String, minutes: Int, allowedApps: [AllowedApp], domains: [String], defaultApps: Set<String>? = nil) {
        guard phase != .running else { return }
        closeAmbient(quitting: false)
        config = ParentConfig.load()
        let now = Date()
        var sprint = SprintStart(
            id: Format.newSprintId(now: now), device: Host.current().localizedName ?? "Mac", user: NSUserName(),
            task: task.isEmpty ? "Focus sprint" : task, plannedSeconds: minutes * 60, startedAt: now,
            allowedApps: allowedApps.map(\.name), allowedBundleIds: allowedApps.map(\.bundleId),
            allowedDomains: domains, captureMode: config.captureMode)
        if let defaultApps {
            let changes = SprintApps.changes(defaults: defaultApps, chosen: allowedApps.map { ($0.bundleId, $0.name) },
                                             names: apps.entries.mapValues(\.name))
            sprint.addedApps = changes.added.isEmpty ? nil : changes.added
            sprint.removedApps = changes.removed.isEmpty ? nil : changes.removed
        }
        do {
            try Inbox.drop(sprintId: sprint.id, file: "start.json", data: JSONCoding.encoder.encode(sprint))
        } catch {
            startError = "Could not reach the YoungWonks Focus helper. Run the installer again from an administrator account."
            return
        }
        startError = nil
        rules = FocusRules(allowedBundleIds: Set(sprint.allowedBundleIds), allowedDomains: domains,
                           distractionDomains: config.distractionDomains, distractionApps: config.distractionApps)
        rules?.appLabels = apps.labels
        start = sprint
        endsAt = now.addingTimeInterval(Double(sprint.plannedSeconds))
        closedAway = 0
        switches = 0
        open = nil
        awayNow = nil
        lastSummary = nil
        phase = .running
    }

    func stopEarly() {
        if phase == .running { finish(.endedEarly, quitting: false) }
        if phase == .onBreak { phase = .idle }
    }

    /// Called from applicationWillTerminate: everything must be on disk before the process exits.
    func appIsQuitting() {
        if phase == .running { finish(.endedEarly, quitting: true) }
        closeAmbient(quitting: true)
    }

    func startBreak(minutes: Int) {
        guard phase == .idle else { return }
        breakEndsAt = Date().addingTimeInterval(Double(minutes * 60))
        phase = .onBreak
    }

    private func finish(_ status: SprintStatus, quitting: Bool) {
        guard let sprint = start else { return }
        let now = Date()
        closeVisit(at: now, quitting: quitting)
        let elapsed = now.timeIntervalSince(sprint.startedAt)
        let end = SprintEnd(id: sprint.id, endedAt: now, status: status, focusedSeconds: max(0, elapsed - closedAway),
                            awaySeconds: closedAway, switchCount: switches)
        if let data = try? JSONCoding.encoder.encode(end) {
            try? Inbox.drop(sprintId: sprint.id, file: "end.json", data: data)
        }
        lastSummary = SprintSummary(task: sprint.task, status: status,
                                    focusPercent: Int((max(0, elapsed - closedAway) / max(1, elapsed) * 100).rounded()),
                                    switches: switches, awaySeconds: closedAway)
        baseSprint += elapsed
        baseAway += closedAway
        baseSwitches += switches
        phase = .idle
        start = nil
        rules = nil
        if !quitting {
            NSSound(named: "Glass")?.play()
            if status == .completed { NSApp.activate(ignoringOtherApps: true) }
        }
    }

    #if DEBUG
    func stopTimerForPreview() {
        timer?.invalidate()
        timer = nil
    }

    func setPreview(running: Bool, away: Bool, now: Date) {
        baseSprint = 3.2 * 3600; baseAway = 14 * 60; baseSwitches = 23
        open = nil
        if running {
            start = SprintStart(id: "preview", device: "MacBook", user: "sam", task: "Algebra homework, chapter 4",
                                plannedSeconds: 1500, startedAt: now.addingTimeInterval(-560), allowedApps: [],
                                allowedBundleIds: [], allowedDomains: [], captureMode: .screenshot)
            endsAt = now.addingTimeInterval(940)
            closedAway = away ? 90 : 48
            switches = away ? 4 : 3
            awayNow = away ? ("espn.com", now.addingTimeInterval(-42), .distraction, "espn.com") : nil
            lastSummary = nil
            phase = .running
        } else {
            start = nil
            awayNow = away ? ("rediff.com", now.addingTimeInterval(-8), .distraction, "rediff.com") : nil
            phase = .idle
            lastSummary = SprintSummary(task: "Algebra homework, chapter 4", status: .completed, focusPercent: 92,
                                        switches: 3, awaySeconds: 118)
        }
        pulse &+= 1
    }
    #endif

    private func noteVisitSaved() { savedVisits += 1 }

    // MARK: Watching

    private func tick() {
        Timing.measure("tick") { tickBody() }
    }

    private func tickBody() {
        let now = Date()
        // How late this tick is: anything well above zero means the main thread was busy with something else.
        Timing.record("main thread delay", ms: max(0, now.timeIntervalSince(lastTick) - SprintEngine.tickSeconds) * 1000)
        let step = min(2, max(0, now.timeIntervalSince(lastTick))) // a long gap means the Mac slept: don't count it
        lastTick = now
        let today = Calendar.current.startOfDay(for: now)
        if today != day {
            closeAmbient(quitting: false) // its totals belong to the day that just ended
            day = today
            baseSprint = 0; baseAway = 0; baseSwitches = 0
            awayByHost = [:]
            searchesStamp = nil
            searchCounts = (0, 0, 0)
        }
        ticks &+= 1
        let wasAway = awayNow?.label
        if ticks % 2 == 0 {
            reloadSitesIfChanged()
            reloadAppsIfChanged()
            collectAnswers()
            reloadSearchesIfChanged()
        }
        switch phase {
        case .running:
            if now >= endsAt { finish(.completed, quitting: false) } else { observe() }
        case .onBreak:
            if now >= breakEndsAt {
                phase = .idle
                NSSound(named: "Glass")?.play()
            }
        case .idle:
            observeAmbient(step: step)
        }
        // Redraw at once when the state flips, so the widget reacts within a quarter of a second.
        if ticks % 2 == 0 || awayNow?.label != wasAway { pulse &+= 1 }
    }

    // MARK: All-day tracking (outside sprints)

    private static var screenUnavailable: Bool {
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 { return true }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return (session?["CGSSessionScreenIsLocked"] as? Bool) == true
    }

    private func observeAmbient(step: Double) {
        let now = Date()
        if ambient == nil, ticks % 40 == 0 { config = ParentConfig.load() } // pick up parent changes within ~10s
        guard config.trackAllDay else {
            closeAmbient(quitting: false)
            return
        }
        if ambientRules == nil {
            ambientRules = FocusRules(allowedBundleIds: [], allowedDomains: [], distractionDomains: config.distractionDomains,
                                      distractionApps: config.distractionApps)
            ambientRules?.appLabels = apps.labels
        }
        guard let rules = ambientRules else { return }
        let context = SprintEngine.screenUnavailable ? nil : monitor.current()
        if let context {
            _ = awaitingLabel(context, rules: rules)
            noteSearch(context)
            noteApp(context)
        }
        let distracted = context.map { rules.isKnownDistraction($0, sites: sites) } ?? false
        // Watching a video means no typing or mouse movement, so idle time only ends "in use" when
        // the thing on screen is not a known distraction.
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        let inUse = context != nil && (distracted || idle < SprintEngine.idleAfterSeconds)

        if inUse {
            if ambient == nil { startAmbient(at: now) }
            ambient?.active += step
            ambient?.lastActive = now
        }
        guard let current = ambient else { return }

        if distracted, let context {
            if let visit = open, visit.key == context.key {
                open?.context = context
            } else {
                closeVisit(at: now, quitting: false)
                ambient?.switches += 1
                let recorder = EventRecorder(mode: config.captureMode, clipSeconds: config.clipSeconds)
                recorder.start(capturer: capturer) { [monitor] in monitor.frontDisplay }
                open = OpenVisit(key: context.key, startedAt: now, context: context, category: .distraction,
                                 recorder: recorder, seq: ambient?.switches ?? 1, session: current.start)
                awayNow = (context.host ?? context.appName, now, .distraction, context.host)
            }
        } else {
            closeVisit(at: now, quitting: false)
        }

        let age = now.timeIntervalSince(current.start.startedAt)
        let quiet = now.timeIntervalSince(current.lastActive)
        if quiet > 300 || (age > SprintEngine.ambientMaxSeconds && open == nil) {
            closeAmbient(quitting: false)
        }
    }

    private func startAmbient(at now: Date) {
        config = ParentConfig.load()
        ambientRules = nil
        let session = SprintStart(
            id: Format.newSprintId(now: now), device: Host.current().localizedName ?? "Mac", user: NSUserName(),
            task: "All day, outside sprints", plannedSeconds: Int(SprintEngine.ambientMaxSeconds), startedAt: now,
            allowedApps: [], allowedBundleIds: [], allowedDomains: [], captureMode: config.captureMode, kind: "ambient")
        guard let data = try? JSONCoding.encoder.encode(session),
              (try? Inbox.drop(sprintId: session.id, file: "start.json", data: data)) != nil else { return } // helper not installed
        ambient = Ambient(start: session, lastActive: now)
    }

    private func closeAmbient(quitting: Bool) {
        guard let current = ambient else { return }
        if let visit = open, visit.session.isAmbient { closeVisit(at: Date(), quitting: quitting) }
        guard let closed = ambient else { return }
        ambient = nil
        ambientRules = nil
        let end = SprintEnd(id: current.start.id, endedAt: Date(), status: .completed,
                            focusedSeconds: max(0, closed.active - closed.away), awaySeconds: closed.away,
                            switchCount: closed.switches, activeSeconds: closed.active)
        if let data = try? JSONCoding.encoder.encode(end) {
            try? Inbox.drop(sprintId: current.start.id, file: "end.json", data: data)
        }
        baseSprint += closed.active
        baseAway += closed.away
        baseSwitches += closed.switches
    }

    private func observe() {
        guard let rules, let context = monitor.current() else { return }
        noteSearch(context)
        noteApp(context)
        let now = Date()
        switch rules.classify(context, sites: sites, awaitingLabel: awaitingLabel(context, rules: rules)) {
        case .neutral:
            break
        case .onTask:
            closeVisit(at: now, quitting: false)
        case .offTask(let category):
            if let current = open, current.key == context.key {
                open?.context = context // same place, keep the newest title / URL
                return
            }
            closeVisit(at: now, quitting: false) // hopping from one off-task place to another is a new visit
            switches += 1
            let recorder = EventRecorder(mode: config.captureMode, clipSeconds: config.clipSeconds)
            recorder.start(capturer: capturer) { [monitor] in monitor.frontDisplay }
            guard let sprint = start else { return }
            open = OpenVisit(key: context.key, startedAt: now, context: context, category: category,
                             recorder: recorder, seq: switches, session: sprint)
            awayNow = (context.host ?? context.appName, now, category, context.host)
        }
    }

    private func closeVisit(at now: Date, quitting: Bool) {
        guard let visit = open else { return }
        let sprint = visit.session
        open = nil
        awayNow = nil
        visit.recorder.stop()
        let duration = now.timeIntervalSince(visit.startedAt)
        if sprint.isAmbient { ambient?.away += duration } else { closedAway += duration }
        if let host = visit.context.host { awayByHost[host, default: 0] += duration }
        let event = DistractionEvent(
            id: "\(sprint.id)-e\(visit.seq)", sprintId: sprint.id, seq: visit.seq, startedAt: visit.startedAt,
            endedAt: now, durationSeconds: (duration * 10).rounded() / 10, appName: visit.context.appName,
            bundleId: visit.context.bundleId, title: visit.context.title, url: visit.context.url,
            host: visit.context.host, category: visit.category, media: [])
        let job = EventPersister.Job(event: event, head: visit.recorder.head, tail: visit.recorder.tail, mode: visit.recorder.mode)
        if quitting {
            EventPersister.persistStills(job)
        } else {
            Task.detached(priority: .utility) { [weak self] in
                await EventPersister.persist(job)
                await self?.noteVisitSaved()
            }
        }
    }

    private func loadDay() {
        // Only today's folders are read, so this stays quick however much history is kept.
        let records = SprintReader.list(in: Paths.vault.appendingPathComponent("sprints"), since: day)
        for record in records where record.start.startedAt >= day && (record.end != nil || record.interrupted || record.isAmbient) {
            baseSprint += record.elapsedSeconds
            baseAway += record.awaySeconds
            baseSwitches += record.end?.switchCount ?? record.events.count
            for event in record.events { if let host = event.host { awayByHost[host, default: 0] += event.durationSeconds } }
        }
        reloadSitesIfChanged()
    }
}
