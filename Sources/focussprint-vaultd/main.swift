import Foundation
import FocusSprintCore

// Background helper. Installed as a LaunchDaemon so it runs as root, and serves every Mac login:
//   1. copies finished records into the vault of the login that made them (root-owned: readable, not deletable)
//   2. links this computer to a household when given a pairing code, and keeps the token root-only
//   3. finds out from the service whose each login is; a login nobody has claimed yet keeps its records here
//   4. sends records, pictures and labelling requests to the service, retrying until confirmed
//   5. fetches the settings and website decisions that apply to each login's person
// Which login something came from is taken from who owns the file, never from what the app says.

setvbuf(stdout, nil, _IOLBF, 0)
func log(_ message: String) {
    print("\(ISO8601DateFormatter().string(from: Date())) \(message)")
}

let fm = FileManager.default
do {
    try Vault(uid: getuid()).ensureDirectories()
} catch {
    log("cannot create \(Paths.root.path): \(error)")
    exit(1)
}
let sync = SiteSync()
sync.ensureDirectories()

// Before logins had their own areas there was one shared vault. A development copy is folded into the
// developer's own login; nothing like it exists on an installed Mac.
let oldVault = Paths.root.appendingPathComponent("vault")
if getuid() != 0, fm.fileExists(atPath: oldVault.path) {
    Paths.prepareHome(for: getuid())
    let mine = Paths.home(for: getuid()).appendingPathComponent("vault")
    for folder in ["sprints", "pending"] {
        for name in (try? fm.contentsOfDirectory(atPath: oldVault.appendingPathComponent(folder).path)) ?? [] {
            try? fm.moveItem(at: oldVault.appendingPathComponent("\(folder)/\(name)"), to: mine.appendingPathComponent("\(folder)/\(name)"))
        }
    }
    for name in ["sites.json", "searches.json", "answers.json"] where !fm.fileExists(atPath: mine.appendingPathComponent(name).path) {
        try? fm.moveItem(at: oldVault.appendingPathComponent(name), to: mine.appendingPathComponent(name))
    }
    try? fm.moveItem(at: Paths.root.appendingPathComponent("config.json"), to: Paths.home(for: getuid()).appendingPathComponent("config.json"))
    try? fm.removeItem(at: oldVault)
    log("folded the earlier shared vault into this login's area")
}
log("helper started, version=\(AppVersion.installed) root=\(Paths.root.path) uid=\(getuid()) service=\(ServiceConfig.baseURL)")

// Keeps this Mac on the current version: a few minutes after starting, then every six hours.
// Only the installed, Developer ID signed helper does this; see Updater for what a package must pass.
if getuid() == 0 {
    Task {
        let updater = Updater()
        var refused = "" // a version that failed its checks is not downloaded again and again
        try? await Task.sleep(nanoseconds: 180 * 1_000_000_000)
        while true {
            do {
                if let release = try await updater.available(), release.version != refused {
                    log("version \(release.version) is available (this is \(AppVersion.installed)); downloading")
                    do {
                        let installed = try await updater.install(release)
                        log("installed version \(installed)") // the installer restarts the helper right after
                    } catch {
                        refused = release.version
                        log("update to \(release.version) not installed: \(error.localizedDescription)")
                    }
                }
            } catch {
                log("could not check for updates: \(error.localizedDescription)")
            }
            try? await Task.sleep(nanoseconds: 6 * 3600 * 1_000_000_000)
        }
    }
}

// Make sure every login that already has an area can read it (see Paths.prepareHome).
for uid in Paths.knownUsers { Paths.prepareHome(for: uid) }
if let problem = Paths.lastGrantProblem { log("could not open a login's area to it: \(problem)") }

/// What the helper remembers about one Mac login between passes.
struct LoginState {
    var identity: SiteSync.Identity?
    var linkProblem: String?
    var lastUploadAt: Date?
    var lastError: String?
    var checked = false
}

nonisolated(unsafe) var lastReport = Date.distantPast

/// Writes what the app shows for the login being worked on: linked or not, whose it is, how much is waiting.
func report(_ state: LoginState, _ vault: Vault) {
    var status = HelperStatus(linked: SiteSync.config() != nil, account: state.identity?.account, memberName: state.identity?.member,
                              memberKind: state.identity?.kind, deviceName: state.identity?.device,
                              linkProblem: state.linkProblem, pending: vault.pendingItems().count,
                              lastUploadAt: state.lastUploadAt, lastError: state.lastError)
    status.profiles = state.identity?.member.isEmpty == true ? state.identity?.profiles : nil
    if let data = try? JSONCoding.encoder.encode(status) {
        try? data.write(to: Paths.status, options: .atomic)
        chmod(Paths.status.path, 0o644)
    }
    lastReport = Date()
}

Task {
    var pass = 0
    var states: [uid_t: LoginState] = [:]

    while true {
        let stored = Vault.ingest(prepare: Paths.prepareHome(for:))
        let requests = sync.ingest()
        for (uid, count) in stored where count > 0 { log("stored \(count) new file(s) for \(Paths.loginName(uid))") }
        if let problem = Paths.lastGrantProblem { log("could not open a login's area to it: \(problem)"); Paths.lastGrantProblem = nil }
        for uid in requests.keys where states[uid] == nil { log("first heard from login \(Paths.loginName(uid))") }
        let service = SiteSync.config()

        for uid in Paths.knownUsers {
            Paths.uid = uid // every per-login path and the login name sent to the service now refer to this login
            var state = states[uid] ?? LoginState()
            let vault = Vault(uid: uid)
            let gotRequests = requests[uid] != nil
            let gotRecords = (stored[uid] ?? 0) > 0

            // A code typed, or a profile picked, in this login.
            if gotRequests || pass % 4 == 0 {
                let before = SiteSync.config() == nil
                await sync.pairIfRequested()
                if before != (SiteSync.config() == nil) || gotRequests { state.checked = false } // look again at once
            }

            if let service = service ?? SiteSync.config() {
                do {
                    if !state.checked || pass % 120 == 0 {
                        // Once a minute: whose login this is, their settings and website decisions.
                        let identity = try await sync.fetchSettings(service)
                        (state.identity, state.linkProblem, state.checked) = (identity, nil, true)
                        // Tell the app at once whose login this is, before the (possibly long) uploads below:
                        // right after a code is entered, this is what turns the link form into the linked card.
                        report(state, vault)
                        if !identity.member.isEmpty { try await sync.refresh(service) }
                    }
                    // Nothing is sent for a login until someone has said whose it is.
                    if state.linkProblem == nil, state.identity?.member.isEmpty == false {
                        if gotRequests || pass % 120 == 0, sync.pendingCount > 0 { _ = await sync.drain(service) }
                        if gotRecords || pass % 40 == 0 {
                            for item in vault.pendingItems() {
                                guard try await sync.upload(item, service) else { break } // busy or down: try again shortly
                                vault.markUploaded(item)
                                state.lastUploadAt = Date()
                                state.lastError = nil
                                // A long queue (the first upload after linking) takes minutes. Keep telling the app
                                // the helper is alive and how much is left, or it would report the helper as gone.
                                if Date().timeIntervalSince(lastReport) > 5 { report(state, vault) }
                            }
                        }
                    }
                } catch ServiceError.notLinked {
                    if state.linkProblem == nil { log("the service no longer accepts this computer") }
                    state.linkProblem = "This computer was removed on the website. Unlink it here, then link it again with a new code."
                    state.checked = true
                } catch ServiceError.unassigned {
                    state.identity?.member = ""
                    state.checked = false // ask again shortly: an admin may have assigned or changed it
                } catch {
                    let message = error.localizedDescription
                    if message != state.lastError { log("paused for \(Paths.loginName(uid)): \(message)") }
                    state.lastError = message
                }
            } else {
                state = LoginState() // the computer is not linked: everything simply stays queued
            }

            if pass % 4 == 0 || gotRequests { report(state, vault) }
            if pass % 7200 == 0 { vault.prune(keepDays: ParentConfig.load().keepLocalDays) }
            states[uid] = state
        }
        pass += 1
        try? await Task.sleep(nanoseconds: 500_000_000)
    }
}

dispatchMain()
