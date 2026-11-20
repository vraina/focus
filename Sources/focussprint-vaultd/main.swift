import Foundation
import FocusSprintCore

// Background helper. Installed as a LaunchDaemon so it runs as root:
//   1. copies finished records from the inbox into the root-owned vault
//   2. links this Mac to a household member when given a pairing code, and keeps the token root-only
//   3. sends records, pictures and labelling requests to the family service, retrying until confirmed
//   4. fetches the settings and website decisions that apply to that member
// Nothing leaves the vault's pending list until the service has acknowledged it.

setvbuf(stdout, nil, _IOLBF, 0)
func log(_ message: String) {
    print("\(ISO8601DateFormatter().string(from: Date())) \(message)")
}

let vault = Vault()
do {
    try vault.ensureDirectories()
} catch {
    log("cannot create \(vault.root.path): \(error)")
    exit(1)
}
let sync = SiteSync()
sync.ensureDirectories()
log("helper started, root=\(vault.root.path) uid=\(getuid()) service=\(ServiceConfig.baseURL)")

Task {
    var pass = 0
    var account: String?
    var memberName: String?
    var memberKind: String?
    var deviceName: String?
    var linkProblem: String?
    var lastUploadAt: Date?
    var lastError: String?
    var checked = false

    while true {
        let stored = vault.ingestInbox()
        if stored > 0 { log("stored \(stored) new file(s)") }
        let requests = sync.ingest()

        if let service = SiteSync.config() {
            // Linked. A pairing request now only gets an "already linked" answer.
            await sync.pairIfRequested()
            do {
                if !checked || pass % 120 == 0 {
                    // Once a minute: the parent's settings and website decisions. Also the link check.
                    let who = try await sync.fetchSettings(service)
                    (account, deviceName, linkProblem, checked) = (who.account, who.device, nil, true)
                    (memberName, memberKind) = (who.member, who.kind)
                    try await sync.refresh(service)
                }
                if linkProblem == nil, requests > 0 || pass % 120 == 0, sync.pendingCount > 0 {
                    _ = await sync.drain(service)
                }
                if linkProblem == nil, stored > 0 || pass % 40 == 0 {
                    for item in vault.pendingItems() {
                        guard try await sync.upload(item, service) else { break } // busy or down: try again shortly
                        vault.markUploaded(item)
                        lastUploadAt = Date()
                        lastError = nil
                    }
                }
            } catch ServiceError.notLinked {
                // The parent removed this computer, or the token is no longer valid. Keep everything queued.
                if linkProblem == nil { log("the service no longer accepts this Mac") }
                linkProblem = "This Mac was removed on the website. Unlink it here, then link it again with a new code."
                checked = true
            } catch {
                let message = error.localizedDescription
                if message != lastError { log("paused: \(message)") }
                lastError = message
            }
        } else {
            // Not linked yet: everything simply stays queued on this Mac until a parent links it.
            (account, deviceName, linkProblem, checked) = (nil, nil, nil, false)
            (memberName, memberKind) = (nil, nil)
            if requests > 0 || pass % 4 == 0 { await sync.pairIfRequested() }
        }

        if pass % 4 == 0 {
            let status = HelperStatus(linked: SiteSync.config() != nil, account: account, memberName: memberName,
                                      memberKind: memberKind, deviceName: deviceName,
                                      linkProblem: linkProblem, pending: vault.pendingItems().count,
                                      lastUploadAt: lastUploadAt, lastError: lastError)
            if let data = try? JSONCoding.encoder.encode(status) {
                try? data.write(to: Paths.status, options: .atomic)
                chmod(Paths.status.path, 0o644)
            }
        }
        if pass % 7200 == 0 { vault.prune(keepDays: ParentConfig.load().keepLocalDays) }
        pass += 1
        try? await Task.sleep(nanoseconds: 500_000_000)
    }
}

dispatchMain()
