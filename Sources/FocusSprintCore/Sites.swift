import Foundation

/// What is known about one website. Labels come from Claude (via the family service), from the
/// parent's own list, or from the parent's decision on a "needed for work" request.
public enum SiteState: String, Codable, Sendable {
    case productive   // AI: fine for study time
    case distraction  // AI: a distraction
    case review       // older records only: waiting for a parent
    case allowed      // parent: always allow
    case locked       // parent: always a distraction; "needed for work" requests are turned down

    public var countsAsDistraction: Bool { self == .distraction || self == .review || self == .locked }
    public var parentDecided: Bool { self == .allowed || self == .locked }
}

public struct SiteEntry: Codable, Sendable {
    public var host: String
    public var state: String
    public var reason: String?
    public var category: String?
    public var updatedAt: String?
    /// End of an approved "needed for work" window (ISO 8601, UTC). Until then the site is not a distraction.
    public var allowedUntil: String? = nil
    /// Approved windows per child, keyed by Mac login name. An approval one child earned does not
    /// carry over to another child, on this Mac or any other.
    public var approvedFor: [String: String]? = nil
    public var siteState: SiteState? { SiteState(rawValue: state) }

    /// The service stores login names with dots and dollar signs replaced, so look them up the same way.
    public static func childKey(_ user: String) -> String {
        let cleaned = String(user.trimmingCharacters(in: .whitespaces).map { ".$\0".contains($0) ? "_" : $0 }.prefix(60))
        return cleaned.isEmpty ? "unknown" : cleaned
    }

    public func approved(at moment: Date = Date(), user: String = NSUserName()) -> Bool {
        let stamps = [approvedFor?[SiteEntry.childKey(user)], allowedUntil].compactMap { $0 }
        return stamps.contains { ISO8601DateFormatter().date(from: $0).map { $0 > moment } ?? false }
    }
    /// Not a distraction right now: labelled productive, allowed by the parent, or inside an approved window.
    public var cleared: Bool { siteState == .productive || siteState == .allowed || approved() }
}

/// The reviewer's answer to one "needed for work" request, shown to the student.
public struct RequestAnswer: Codable, Sendable, Identifiable {
    public var id: String
    public var host: String
    public var decision: String // approve_temporary | approve_permanent | deny
    public var minutes: Int
    public var explanation: String
    public var allowedUntil: String?
    public var approved: Bool { decision != "deny" }

    public init(id: String, host: String, decision: String, minutes: Int, explanation: String, allowedUntil: String?) {
        self.id = id; self.host = host; self.decision = decision
        self.minutes = minutes; self.explanation = explanation; self.allowedUntil = allowedUntil
    }
}

public struct AnswerList: Codable, Sendable {
    public var answers: [RequestAnswer]
    public static func load() -> [RequestAnswer] {
        guard let data = try? Data(contentsOf: Paths.answers) else { return [] }
        return (try? JSONDecoder().decode(AnswerList.self, from: data))?.answers ?? []
    }
}

public struct SiteList: Codable, Sendable {
    public var sites: [SiteEntry]
    public init(sites: [SiteEntry]) { self.sites = sites }
}

/// Read-only view of the site labels the helper keeps in the vault.
public struct SiteBook: Sendable {
    public private(set) var entries: [String: SiteEntry] = [:]

    public init() {}
    public init(entries: [SiteEntry]) {
        for e in entries { self.entries[e.host] = e }
    }
    public init(file: URL) {
        let list = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(SiteList.self, from: $0) }
        self.init(entries: list?.sites ?? [])
    }

    /// An exact match wins. Otherwise a parent's decision or an approved window on a parent domain
    /// applies ("youtube.com" covers "m.youtube.com"); a plain AI label never spreads to other subdomains.
    public func entry(for host: String) -> SiteEntry? {
        if let exact = entries[host] { return exact }
        var labels = host.split(separator: ".")
        while labels.count > 2 {
            labels.removeFirst()
            if let parent = entries[labels.joined(separator: ".")],
               parent.siteState?.parentDecided == true || parent.approved() { return parent }
        }
        return nil
    }

    public func state(for host: String) -> SiteState? { entry(for: host)?.siteState }
    public func isApproved(_ host: String) -> Bool { entry(for: host)?.approved() ?? false }
    public func isCleared(_ host: String) -> Bool { entry(for: host)?.cleared ?? false }
}

public extension Paths {
    /// Where the app leaves "label this site" and "needed for work" requests for the helper.
    static var requests: URL { root.appendingPathComponent("requests", isDirectory: true) }
    static var outbox: URL { vault.appendingPathComponent("outbox", isDirectory: true) }
    static var sites: URL { vault.appendingPathComponent("sites.json") }
    static var answers: URL { vault.appendingPathComponent("answers.json") }
    /// Root-only: this computer's token for the service. Its presence is what "linked" means.
    static var service: URL { root.appendingPathComponent("service.json") }
    /// The answer to the latest pairing attempt, for the app to show.
    static var pairing: URL { vault.appendingPathComponent("pairing.json") }
}

public struct ServiceConfig: Codable, Sendable {
    public var serviceURL: String
    public var deviceToken: String
    public init(serviceURL: String, deviceToken: String) {
        self.serviceURL = serviceURL; self.deviceToken = deviceToken
    }

    /// Where the family service lives. Built in, so nobody has to type an address; a developer can
    /// point a test build elsewhere with FOCUSSPRINT_SERVICE_URL or a `service-url` file.
    public static var baseURL: String {
        if let override = ProcessInfo.processInfo.environment["FOCUSSPRINT_SERVICE_URL"], !override.isEmpty { return override }
        if let file = try? String(contentsOf: Paths.root.appendingPathComponent("service-url"), encoding: .utf8) {
            let trimmed = file.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("http") { return trimmed }
        }
        return "https://focus-c0tf.onrender.com"
    }
}

/// What came back from a pairing attempt.
public struct PairingResult: Codable, Sendable {
    public var id: String
    public var ok: Bool
    public var message: String

    public static func load() -> PairingResult? {
        (try? Data(contentsOf: Paths.pairing)).flatMap { try? JSONDecoder().decode(PairingResult.self, from: $0) }
    }
}

public enum ServiceError: Error {
    /// The service does not accept this computer's token (it was removed on the website, or the link is broken).
    case notLinked
    /// The computer is linked, but nobody has said whose this Mac login is yet. Its records wait.
    case unassigned
}

public struct SiteRequest: Codable, Sendable {
    public var kind: String // "classify", "dispute", "search", "pair", "claim" or "hello"
    public var host: String
    public var reason: String?
    public var user: String?
    public var device: String?
    public var id: String?
    public var minutes: Int?
    public var permanent: Bool?
    public var onParentList: Bool?
    /// Searches only: the search words, and the sprint task they were made during (if any).
    public var query: String?
    public var task: String?
    /// Pairing only: the one-time code from the website.
    public var code: String?
    /// Picking a profile only: the kid profile chosen for this login.
    public var member: String?

    public init(kind: String, host: String, reason: String? = nil, user: String? = nil, device: String? = nil,
                id: String? = nil, minutes: Int? = nil, permanent: Bool? = nil, onParentList: Bool? = nil,
                query: String? = nil, task: String? = nil, code: String? = nil) {
        self.kind = kind; self.host = host; self.reason = reason; self.user = user; self.device = device
        self.id = id; self.minutes = minutes; self.permanent = permanent; self.onParentList = onParentList
        self.query = query; self.task = task; self.code = code
    }

    /// A kid picking their own profile for this login.
    public static func claim(member: String, id: String) -> SiteRequest {
        var request = SiteRequest(kind: "claim", host: "claim.youngwonks.app", id: id)
        request.member = member
        return request
    }

    /// The app announcing that this login is in use, so the helper sets up its area and status.
    public static func hello() -> SiteRequest {
        SiteRequest(kind: "hello", host: "hello.youngwonks.app", id: UUID().uuidString.lowercased())
    }

    /// A request to link this login. `host` is only a placeholder that satisfies the file-name rules.
    public static func pairing(code: String, deviceName: String, id: String) -> SiteRequest {
        SiteRequest(kind: "pair", host: "pair.youngwonks.app", device: deviceName, id: id, code: code)
    }

    public static func isValidHost(_ host: String) -> Bool {
        host.range(of: #"^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$"#, options: .regularExpression) != nil
    }

    /// App side. The helper picks the file up, so the app never needs the service token.
    public func drop() throws {
        guard SiteRequest.isValidHost(host) else { throw CocoaError(.fileWriteInvalidFileName) }
        let name = kind == "classify" ? "classify-\(host).json" : "\(kind)-\(id ?? UUID().uuidString.lowercased()).json"
        let tmp = Paths.requests.appendingPathComponent(".tmp-\(UUID().uuidString)")
        try JSONEncoder().encode(self).write(to: tmp)
        try FileManager.default.moveItem(at: tmp, to: Paths.requests.appendingPathComponent(name))
    }
}

/// Helper side: moves requests into the root-owned outbox (so they cannot be withdrawn), sends
/// them to the family service, and keeps `sites.json` current.
public final class SiteSync {
    public enum Outcome { case done, retryLater, rejected }
    private let fm = FileManager.default
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 40
        session = URLSession(configuration: config)
    }

    public func ensureDirectories() {
        try? fm.createDirectory(at: Paths.requests, withIntermediateDirectories: true)
        chmod(Paths.requests.path, 0o1777)
    }

    public static func config() -> ServiceConfig? {
        guard let data = try? Data(contentsOf: Paths.service),
              let cfg = try? JSONDecoder().decode(ServiceConfig.self, from: data),
              URL(string: cfg.serviceURL)?.scheme?.hasPrefix("http") == true, !cfg.deviceToken.isEmpty else { return nil }
        return cfg
    }

    /// Moves new requests into the outbox of the login that owns each file. Returns how many, per login.
    @discardableResult
    public func ingest() -> [uid_t: Int] {
        var accepted: [uid_t: Int] = [:]
        for name in (try? fm.contentsOfDirectory(atPath: Paths.requests.path)) ?? [] {
            let src = Paths.requests.appendingPathComponent(name)
            if name.hasPrefix(".tmp-") { continue }
            defer { unlink(src.path) }
            guard name.range(of: #"^(classify|dispute|search|pair|claim|hello)-[a-z0-9.-]{1,260}\.json$"#, options: .regularExpression) != nil,
                  let (data, owner) = Vault.readRegularFile(src, limit: 8192),
                  let req = try? JSONDecoder().decode(SiteRequest.self, from: data),
                  SiteRequest.isValidHost(req.host), ["classify", "dispute", "search", "pair", "claim", "hello"].contains(req.kind) else { continue }
            Paths.prepareHome(for: owner)
            accepted[owner, default: 0] += 0
            if req.kind == "hello" { continue } // nothing to send: the area and its status now exist
            let dest = Paths.home(for: owner).appendingPathComponent("vault/outbox/\(name)")
            if !fm.fileExists(atPath: dest.path), (try? data.write(to: dest, options: .atomic)) != nil {
                chmod(dest.path, 0o600)
                accepted[owner, default: 0] += 1
            }
        }
        return accepted
    }

    public var pendingCount: Int {
        ((try? fm.contentsOfDirectory(atPath: Paths.outbox.path)) ?? []).filter { !$0.hasPrefix("pair-") && !$0.hasPrefix("claim-") }.count
    }

    // MARK: Linking this Mac to a parent's account

    /// Handles a waiting request to link, if there is one, for the login being worked on:
    /// - a code typed on a computer that is not linked yet links the computer to that household;
    /// - a code typed in a login on a linked computer says that login is the code's person (how an adult claims theirs);
    /// - a kid picking their profile in the app says the same for a kid.
    /// A login that already belongs to someone is never changed from the Mac: only the website can do that.
    public func pairIfRequested() async {
        let waiting = ((try? fm.contentsOfDirectory(atPath: Paths.outbox.path)) ?? [])
            .filter { $0.hasPrefix("pair-") || $0.hasPrefix("claim-") }.sorted()
        guard let name = waiting.last else { return }
        for other in waiting { if other != name { unlink(Paths.outbox.appendingPathComponent(other).path) } }
        let file = Paths.outbox.appendingPathComponent(name)
        defer { unlink(file.path) }
        guard let data = try? Data(contentsOf: file), let req = try? JSONDecoder().decode(SiteRequest.self, from: data) else { return }
        let id = req.id ?? name
        do {
            let reply: Data, status: Int
            if let linked = SiteSync.config() {
                let body: [String: Any] = req.kind == "claim" ? ["member": req.member ?? ""] : ["code": req.code ?? ""]
                (reply, status) = try await call(linked, path: "/api/claim", json: body)
            } else if req.kind == "pair" {
                // The login name comes from the system, not from the request, so it cannot be made up.
                let open = ServiceConfig(serviceURL: ServiceConfig.baseURL, deviceToken: "")
                (reply, status) = try await call(open, path: "/api/pair", json: [
                    "code": req.code ?? "", "name": req.device ?? "Mac", "login": Paths.loginName(Paths.uid)])
            } else {
                report(PairingResult(id: id, ok: false, message: "This computer is not linked to a household yet."))
                return
            }
            let object = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any]
            guard status == 200 else {
                report(PairingResult(id: id, ok: false, message: (object?["error"] as? String) ?? "That was not accepted."))
                return
            }
            if let token = object?["token"] as? String, !token.isEmpty {
                let saved = try JSONEncoder().encode(ServiceConfig(serviceURL: ServiceConfig.baseURL, deviceToken: token))
                try saved.write(to: Paths.service, options: .atomic)
                chmod(Paths.service.path, 0o600)
            }
            let member = (object?["member"] as? [String: Any])?["name"] as? String
            report(PairingResult(id: id, ok: true, message: "This login is now \(member ?? "linked")."))
        } catch {
            report(PairingResult(id: id, ok: false, message: "Could not reach the service. Check the internet connection and try again."))
        }
    }

    private func report(_ result: PairingResult) {
        guard let data = try? JSONEncoder().encode(result) else { return }
        try? data.write(to: Paths.pairing, options: .atomic)
        chmod(Paths.pairing.path, 0o644)
    }

    // MARK: Sending records and fetching the parent's settings

    /// Sends one stored record or picture. Returns false when it should be tried again later.
    public func upload(_ item: PendingItem, _ config: ServiceConfig) async throws -> Bool {
        guard let payload = try? Data(contentsOf: item.source) else { return true } // nothing to send
        guard let url = URL(string: config.serviceURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
                            + "/api/upload/\(item.sprintId)/\(item.file)") else { return true }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(config.deviceToken)", forHTTPHeaderField: "Authorization")
        request.setValue(Paths.loginName(Paths.uid), forHTTPHeaderField: "X-Login")
        request.setValue(item.file.hasSuffix(".json") ? "application/json" : "application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await session.upload(for: request, from: payload)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: return true
        case 401: throw ServiceError.notLinked
        case 409: throw ServiceError.unassigned
        case 400, 409, 413: return true // the service will never accept this file: do not block the queue behind it
        default: return false
        }
    }

    public struct Identity: Sendable {
        public var account: String
        public var device: String
        /// Empty when nobody has been assigned to this login yet.
        public var member: String
        public var kind: String
        public var profiles: [HelperStatus.Profile]
    }

    /// Asks the service who this login belongs to. For an assigned login it also writes the settings that
    /// apply where the app reads them; for an unassigned one it returns the kid profiles that may be picked.
    public func fetchSettings(_ config: ServiceConfig) async throws -> Identity {
        let (data, status) = try await call(config, path: "/api/config", json: nil)
        if status == 401 { throw ServiceError.notLinked }
        guard status == 200, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw URLError(.badServerResponse)
        }
        if let settings = object["settings"] as? [String: Any],
           let encoded = try? JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys, .prettyPrinted]),
           (try? JSONCoding.decoder.decode(ParentConfig.self, from: encoded)) != nil {
            try? encoded.write(to: Paths.config, options: .atomic)
            chmod(Paths.config.path, 0o644)
        }
        let member = object["member"] as? [String: Any]
        let profiles = ((object["profiles"] as? [[String: Any]]) ?? []).compactMap { entry -> HelperStatus.Profile? in
            guard let id = entry["id"] as? String, let name = entry["name"] as? String else { return nil }
            return HelperStatus.Profile(id: id, name: name)
        }
        return Identity(account: (object["account"] as? String) ?? "", device: (object["device"] as? String) ?? "",
                        member: (member?["name"] as? String) ?? "", kind: (member?["kind"] as? String) ?? "", profiles: profiles)
    }

    /// Sends everything waiting. Stops at the first network failure and leaves the rest queued.
    public func drain(_ config: ServiceConfig) async -> String? {
        for name in ((try? fm.contentsOfDirectory(atPath: Paths.outbox.path)) ?? []).sorted()
        where !name.hasPrefix("pair-") && !name.hasPrefix("claim-") {
            let file = Paths.outbox.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: file), let req = try? JSONDecoder().decode(SiteRequest.self, from: data) else {
                unlink(file.path)
                continue
            }
            do {
                switch try await send(req, config) {
                case .done, .rejected: unlink(file.path)
                case .retryLater: continue // the service has no label yet (Claude unavailable): try again next round
                }
            } catch {
                return error.localizedDescription
            }
        }
        return nil
    }

    private func send(_ req: SiteRequest, _ config: ServiceConfig) async throws -> Outcome {
        var body: [String: Any] = ["host": req.host]
        if req.kind == "dispute" {
            body["reason"] = req.reason ?? ""
            body["user"] = req.user ?? ""
            body["device"] = req.device ?? ""
            body["id"] = req.id ?? ""
            body["minutes"] = req.minutes ?? 30
            body["permanent"] = req.permanent ?? false
            body["onParentList"] = req.onParentList ?? false
        }
        if req.kind == "search" {
            body = ["id": req.id ?? "", "query": req.query ?? "", "engine": req.host, "task": req.task ?? "",
                    "user": req.user ?? "", "device": req.device ?? ""]
        }
        let (data, status) = try await call(config, path: "/api/\(req.kind)", json: body)
        if status == 200, req.kind == "search" {
            guard var entry = try? JSONDecoder().decode(SearchEntry.self, from: data) else { throw URLError(.cannotParseResponse) }
            if entry.text?.isEmpty == true { entry.text = nil }
            record(entry)
            return .done
        }
        if status == 200, req.kind == "dispute" {
            struct Reply: Decodable { var site: SiteEntry; var answer: RequestAnswer }
            guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else { throw URLError(.cannotParseResponse) }
            merge([reply.site])
            record(reply.answer)
            return .done
        }
        if status == 200, let entry = try? JSONDecoder().decode(SiteEntry.self, from: data) {
            merge([entry])
            return .done
        }
        if status == 400 || status == 404 { return .rejected }
        // 429: the family's daily allowance of AI calls is used up. A search is dropped; the rest wait for tomorrow.
        if status == 429 { return req.kind == "search" ? .rejected : .retryLater }
        if status == 503 { return .retryLater }
        if status == 401 { throw ServiceError.notLinked }
        if status == 409 { throw ServiceError.unassigned }
        throw URLError(.badServerResponse)
    }

    /// Pulls every label, which is how the parent's decisions reach the Mac.
    public func refresh(_ config: ServiceConfig) async throws {
        let (data, status) = try await call(config, path: "/api/sites", json: nil)
        if status == 401 { throw ServiceError.notLinked }
        if status == 409 { throw ServiceError.unassigned }
        guard status == 200 else { throw URLError(.badServerResponse) }
        let list = try JSONDecoder().decode(SiteList.self, from: data)
        write(SiteBook(entries: list.sites))
    }

    private func call(_ config: ServiceConfig, path: String, json: [String: Any]?) async throws -> (Data, Int) {
        guard let url = URL(string: config.serviceURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) + path) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        if !config.deviceToken.isEmpty {
            request.setValue("Bearer \(config.deviceToken)", forHTTPHeaderField: "Authorization")
            // Which Mac login this is about. The helper takes it from the system, not from the app.
            request.setValue(Paths.loginName(Paths.uid), forHTTPHeaderField: "X-Login")
        }
        if let json {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// Keeps the latest answers where the app can read them, so the student sees the decision.
    private func record(_ answer: RequestAnswer) {
        var answers = AnswerList.load().filter { $0.id != answer.id }
        answers.append(answer)
        guard let data = try? JSONEncoder().encode(AnswerList(answers: Array(answers.suffix(50)))) else { return }
        try? data.write(to: Paths.answers, options: .atomic)
        chmod(Paths.answers.path, 0o644)
    }

    /// The labelled search, for History and the widget. The words are already gone unless it was a distraction.
    private func record(_ entry: SearchEntry) {
        var all = SearchLog.load().filter { $0.id != entry.id }
        all.append(entry)
        guard let data = try? JSONEncoder().encode(SearchLog(searches: Array(all.suffix(3000)))) else { return }
        try? data.write(to: Paths.searches, options: .atomic)
        chmod(Paths.searches.path, 0o644)
    }

    private func merge(_ entries: [SiteEntry]) {
        var book = SiteBook(file: Paths.sites)
        var all = book.entries
        for e in entries { all[e.host] = e }
        book = SiteBook(entries: Array(all.values))
        write(book)
    }

    private func write(_ book: SiteBook) {
        let list = SiteList(sites: book.entries.values.sorted { $0.host < $1.host })
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: Paths.sites, options: .atomic)
        chmod(Paths.sites.path, 0o644)
    }
}
