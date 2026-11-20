import Foundation

/// How time in one app counts for the person using this login. The label comes from the service
/// (Claude the first time an app is seen; a person can change it on the website).
public struct AppEntry: Codable, Sendable, Identifiable, Hashable {
    public var bundleId: String
    public var name: String
    /// "work", "distraction" or "neutral" (does not count).
    public var state: String
    public var reason: String?
    public var id: String { bundleId.lowercased() }

    public init(bundleId: String, name: String, state: String, reason: String? = nil) {
        self.bundleId = bundleId; self.name = name; self.state = state; self.reason = reason
    }
}

/// What the helper keeps in `apps.json`, as the service sent it.
public struct AppList: Codable, Sendable {
    /// This login's own list (for a kid, the household's kids' list).
    public var apps: [AppEntry]
    /// Only for a household admin or co-admin: the kids' list, which they manage.
    public var kids: [AppEntry]?
    /// True when this login may change its own list (an adult). A kid's list is changed by an admin.
    public var canEdit: Bool?
    public init(apps: [AppEntry], kids: [AppEntry]? = nil, canEdit: Bool? = nil) { self.apps = apps; self.kids = kids; self.canEdit = canEdit }

    public static func load(_ file: URL = Paths.apps) -> AppList {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(AppList.self, from: $0) } ?? AppList(apps: [])
    }
}

/// Read-only view of the app labels the helper keeps in the vault.
public struct AppBook: Sendable {
    public private(set) var entries: [String: AppEntry] = [:]

    public init() {}
    public init(entries: [AppEntry]) {
        for e in entries { self.entries[e.id] = e }
    }
    public init(file: URL) {
        let list = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(AppList.self, from: $0) }
        self.init(entries: list?.apps ?? [])
    }

    public func state(for bundleId: String) -> String? { entries[bundleId.lowercased()]?.state }
    public func isWork(_ bundleId: String) -> Bool { state(for: bundleId) == "work" }
    public var sorted: [AppEntry] { entries.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }
    /// Bundle id -> label, in the form the rules use.
    public var labels: [String: String] { entries.mapValues(\.state) }
}

public extension Paths {
    static var apps: URL { vault.appendingPathComponent("apps.json") }
}

public extension SiteRequest {
    /// "This app has been seen in use: what does it count as?" Sent once per app.
    /// A label changed in the app by an adult (their own list) or a household admin (also the kids' list).
    /// The service decides whether this login may; the helper says which login it is.
    static func appLabel(bundleId: String, state: String, kidsList: Bool) -> SiteRequest {
        var request = SiteRequest(kind: "applabel", host: "app.youngwonks.app", id: UUID().uuidString.lowercased())
        request.bundleId = bundleId
        request.label = state
        request.list = kidsList ? "kids" : "mine"
        return request
    }

    static func app(bundleId: String, name: String) -> SiteRequest? {
        guard bundleId.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{1,150}$"#, options: .regularExpression) != nil, !name.isEmpty else { return nil }
        // The id becomes part of a file name, which only allows lowercase letters, digits, dots and dashes.
        let id = String(bundleId.lowercased().map { $0.isLetter && $0.isASCII || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "-" })
        var request = SiteRequest(kind: "app", host: "app.youngwonks.app", id: id)
        request.bundleId = bundleId
        request.appName = String(name.prefix(80))
        return request
    }
}

/// What a sprint's ticked apps changed, compared with the Work apps that were ticked to begin with.
public enum SprintApps {
    public static func changes(defaults: Set<String>, chosen: [(bundleId: String, name: String)],
                               names: [String: String]) -> (added: [String], removed: [String]) {
        let picked = Set(chosen.map { $0.bundleId.lowercased() })
        let added = chosen.filter { !defaults.contains($0.bundleId.lowercased()) }.map(\.name).sorted()
        let removed = defaults.subtracting(picked).compactMap { names[$0] }.sorted()
        return (added, removed)
    }
}
