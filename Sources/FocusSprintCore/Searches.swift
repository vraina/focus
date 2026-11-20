import Foundation

/// Finds the search words in a browser tab's address, for the common search engines.
public enum SearchQuery {
    /// (host test, path prefix, query parameter)
    private static let engines: [(match: (String) -> Bool, path: String, param: String, name: String)] = [
        ({ $0 == "google.com" || $0.hasPrefix("google.") }, "/search", "q", "google.com"),
        ({ $0 == "bing.com" }, "/search", "q", "bing.com"),
        ({ $0 == "duckduckgo.com" }, "/", "q", "duckduckgo.com"),
        ({ $0 == "search.yahoo.com" }, "/search", "p", "yahoo.com"),
        ({ $0 == "search.brave.com" }, "/search", "q", "brave.com"),
        ({ $0 == "ecosia.org" }, "/search", "q", "ecosia.org"),
    ]

    public static func parse(_ address: String) -> (engine: String, query: String)? {
        guard let parts = URLComponents(string: address), var host = parts.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        for engine in engines where engine.match(host) && (parts.path.isEmpty ? "/" : parts.path).hasPrefix(engine.path) {
            guard let raw = parts.queryItems?.first(where: { $0.name == engine.param })?.value else { return nil }
            let query = raw.replacingOccurrences(of: "+", with: " ")
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return query.isEmpty ? nil : (engine.name, String(query.prefix(300)))
        }
        return nil
    }
}

/// One labelled search. `text` is present only for distraction searches; work searches are just
/// counted, and private ones are counted with no words and no hint of the topic.
public struct SearchEntry: Codable, Sendable, Identifiable {
    public var id: String
    public var at: String
    public var label: String // work | distraction | personal
    public var engine: String?
    public var reason: String?
    public var text: String?

    public var date: Date? { ISO8601DateFormatter().date(from: at) }

    public init(id: String, at: String, label: String, engine: String? = nil, reason: String? = nil, text: String? = nil) {
        self.id = id; self.at = at; self.label = label; self.engine = engine; self.reason = reason; self.text = text
    }
}

public struct SearchLog: Codable, Sendable {
    public var searches: [SearchEntry]

    public static func load(from file: URL = Paths.searches) -> [SearchEntry] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode(SearchLog.self, from: data))?.searches ?? []
    }

    public static func counts(_ entries: [SearchEntry]) -> (work: Int, distraction: Int, personal: Int) {
        (entries.filter { $0.label == "work" }.count, entries.filter { $0.label == "distraction" }.count,
         entries.filter { $0.label == "personal" }.count)
    }
}

public extension Paths {
    static var searches: URL { vault.appendingPathComponent("searches.json") }
}
