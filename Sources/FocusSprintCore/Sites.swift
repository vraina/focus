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
    public var siteState: SiteState? { SiteState(rawValue: state) }

    public func approved(at moment: Date = Date()) -> Bool {
        guard let allowedUntil, let end = ISO8601DateFormatter().date(from: allowedUntil) else { return false }
        return end > moment
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
    /// Root-only: address and token of the family service.
    static var service: URL { root.appendingPathComponent("service.json") }
}

public struct ServiceConfig: Codable, Sendable {
    public var serviceURL: String
    public var deviceToken: String
    public init(serviceURL: String, deviceToken: String) {
        self.serviceURL = serviceURL; self.deviceToken = deviceToken
    }
}

public struct SiteRequest: Codable, Sendable {
    public var kind: String // "classify" or "dispute"
    public var host: String
    public var reason: String?
    public var user: String?
    public var device: String?
    public var id: String?
    public var minutes: Int?
    public var permanent: Bool?
    public var onParentList: Bool?

    public init(kind: String, host: String, reason: String? = nil, user: String? = nil, device: String? = nil,
                id: String? = nil, minutes: Int? = nil, permanent: Bool? = nil, onParentList: Bool? = nil) {
        self.kind = kind; self.host = host; self.reason = reason; self.user = user; self.device = device
        self.id = id; self.minutes = minutes; self.permanent = permanent; self.onParentList = onParentList
    }

    public static func isValidHost(_ host: String) -> Bool {
        host.range(of: #"^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$"#, options: .regularExpression) != nil
    }

    /// App side. The helper picks the file up, so the app never needs the service token.
    public func drop() throws {
        guard SiteRequest.isValidHost(host) else { throw CocoaError(.fileWriteInvalidFileName) }
        let name = kind == "classify" ? "classify-\(host).json" : "dispute-\(id ?? UUID().uuidString.lowercased()).json"
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
        try? fm.createDirectory(at: Paths.outbox, withIntermediateDirectories: true)
        chmod(Paths.outbox.path, 0o755)
    }

    public static func config() -> ServiceConfig? {
        guard let data = try? Data(contentsOf: Paths.service),
              let cfg = try? JSONDecoder().decode(ServiceConfig.self, from: data),
              URL(string: cfg.serviceURL)?.scheme?.hasPrefix("http") == true, !cfg.deviceToken.isEmpty else { return nil }
        return cfg
    }

    /// Returns how many new requests were accepted.
    @discardableResult
    public func ingest() -> Int {
        var accepted = 0
        for name in (try? fm.contentsOfDirectory(atPath: Paths.requests.path)) ?? [] {
            let src = Paths.requests.appendingPathComponent(name)
            if name.hasPrefix(".tmp-") { continue }
            defer { unlink(src.path) }
            guard name.range(of: #"^(classify|dispute)-[a-z0-9.-]{1,260}\.json$"#, options: .regularExpression) != nil else { continue }
            let fd = open(src.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { continue }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            var st = stat()
            guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size > 0, st.st_size < 8192,
                  let data = try? handle.readToEnd(), let req = try? JSONDecoder().decode(SiteRequest.self, from: data),
                  SiteRequest.isValidHost(req.host), req.kind == "classify" || req.kind == "dispute" else { continue }
            let dest = Paths.outbox.appendingPathComponent(name)
            if !fm.fileExists(atPath: dest.path), (try? data.write(to: dest, options: .atomic)) != nil {
                chmod(dest.path, 0o644)
                accepted += 1
            }
        }
        return accepted
    }

    public var pendingCount: Int { ((try? fm.contentsOfDirectory(atPath: Paths.outbox.path)) ?? []).count }

    /// Sends everything waiting. Stops at the first network failure and leaves the rest queued.
    public func drain(_ config: ServiceConfig) async -> String? {
        for name in ((try? fm.contentsOfDirectory(atPath: Paths.outbox.path)) ?? []).sorted() {
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
        let (data, status) = try await call(config, path: "/api/\(req.kind)", json: body)
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
        if status == 503 { return .retryLater }
        throw URLError(status == 401 ? .userAuthenticationRequired : .badServerResponse)
    }

    /// Pulls every label, which is how the parent's decisions reach the Mac.
    public func refresh(_ config: ServiceConfig) async throws {
        let (data, status) = try await call(config, path: "/api/sites", json: nil)
        guard status == 200 else { throw URLError(.badServerResponse) }
        let list = try JSONDecoder().decode(SiteList.self, from: data)
        write(SiteBook(entries: list.sites))
    }

    private func call(_ config: ServiceConfig, path: String, json: [String: Any]?) async throws -> (Data, Int) {
        guard let url = URL(string: config.serviceURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) + path) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(config.deviceToken)", forHTTPHeaderField: "Authorization")
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
