import Foundation
import FocusSprintCore

// Background helper. Installed as a LaunchDaemon so it runs as root:
//   1. copies finished records from the inbox into the root-owned vault
//   2. uploads them to MongoDB Atlas, retrying until the server confirms
// Nothing leaves the vault's pending list until Atlas has acknowledged it.

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
log("vault helper started, root=\(vault.root.path) uid=\(getuid())")

actor Uploader {
    private var cloud: CloudStore?
    private var cloudURI: String?
    private(set) var lastUploadAt: Date?
    private(set) var lastError: String?
    private(set) var configured = false

    func drain(_ vault: Vault) async {
        guard let data = try? Data(contentsOf: Paths.secrets),
              let secrets = try? JSONDecoder().decode(Secrets.self, from: data),
              !secrets.mongoURI.trimmingCharacters(in: .whitespaces).isEmpty else {
            configured = false
            cloud = nil
            return // no connection string yet: everything simply stays queued
        }
        configured = true
        if cloud == nil || cloudURI != secrets.mongoURI {
            cloud = CloudStore(uri: secrets.mongoURI, database: secrets.database)
            cloudURI = secrets.mongoURI
        }
        for item in vault.pendingItems() {
            guard let cloud else { return }
            guard let payload = try? Data(contentsOf: item.source) else {
                vault.markUploaded(item) // marker without a file: nothing to send
                continue
            }
            do {
                try await cloud.upload(sprintId: item.sprintId, file: item.file, data: payload)
                vault.markUploaded(item)
                lastUploadAt = Date()
                lastError = nil
            } catch {
                // Offline or server trouble: keep the item, reconnect on the next pass.
                let message = String(describing: error)
                if message != lastError { log("upload paused: \(message)") }
                lastError = message
                self.cloud = nil
                return
            }
        }
    }

    func status(pending: Int) -> HelperStatus {
        HelperStatus(mongoConfigured: configured, pending: pending, lastUploadAt: lastUploadAt,
                     lastError: lastError, updatedAt: Date())
    }
}

let uploader = Uploader()
let siteSync = SiteSync()
siteSync.ensureDirectories()

Task {
    var pass = 0
    while true {
        let accepted = vault.ingestInbox()
        if accepted > 0 { log("stored \(accepted) new file(s)") }
        let waiting = vault.pendingItems().count
        // Upload right after new files arrive, otherwise retry every 20 seconds.
        if waiting > 0 && (accepted > 0 || pass % 40 == 0) {
            await uploader.drain(vault)
        }
        if pass % 6 == 0 {
            let status = await uploader.status(pending: vault.pendingItems().count)
            if let data = try? JSONCoding.encoder.encode(status) {
                try? data.write(to: Paths.status, options: .atomic)
                chmod(Paths.status.path, 0o644)
            }
        }
        // Site labels: send new requests straight away, retry the queue and pull parent decisions once a minute.
        let newRequests = siteSync.ingest()
        if let service = SiteSync.config(), newRequests > 0 || pass % 120 == 0 {
            if siteSync.pendingCount > 0, let problem = await siteSync.drain(service) {
                if pass % 1200 == 0 { log("family service unreachable: \(problem)") }
            }
            if pass % 120 == 0 { try? await siteSync.refresh(service) }
        }
        if pass % 7200 == 0 { vault.prune(keepDays: ParentConfig.load().keepLocalDays) }
        pass += 1
        try? await Task.sleep(nanoseconds: 500_000_000)
    }
}

dispatchMain()
