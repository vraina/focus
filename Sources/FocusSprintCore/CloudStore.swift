import Foundation
import MongoKitten
import NIOCore

public enum CloudError: Error, CustomStringConvertible {
    case timeout
    case rejected(String)
    public var description: String {
        switch self {
        case .timeout: return "Timed out talking to MongoDB"
        case .rejected(let m): return "MongoDB rejected the write: \(m)"
        }
    }
}

/// MongoDB Atlas, used append-only: the helper's database user needs `insert` only, the viewer `find` only.
/// Every document has a deterministic _id, so re-sending after a dropped connection can never duplicate.
public actor CloudStore {
    public static let defaultDatabase = "focussprint"
    private let uri: String
    private var db: MongoDatabase?

    public init(uri: String, database: String? = nil) {
        self.uri = CloudStore.uri(uri, withDatabase: database ?? CloudStore.defaultDatabase)
    }

    /// Atlas hands out URIs without a database ("...mongodb.net/?retryWrites=true"); the driver needs one.
    public static func uri(_ raw: String, withDatabase database: String) -> String {
        let uri = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let scheme = uri.range(of: "://") else { return uri }
        let rest = uri[scheme.upperBound...]
        let query = rest.firstIndex(of: "?")
        let authorityEnd = rest[..<(query ?? rest.endIndex)].firstIndex(of: "/")
        if let slash = authorityEnd {
            let path = rest[rest.index(after: slash)..<(query ?? rest.endIndex)]
            if !path.isEmpty { return uri }
            return String(uri[..<rest.index(after: slash)]) + database + String(rest[(query ?? rest.endIndex)...])
        }
        let hostEnd = query ?? rest.endIndex
        return String(uri[..<hostEnd]) + "/" + database + String(rest[hostEnd...])
    }

    private func database() async throws -> MongoDatabase {
        if let db { return db }
        let uri = self.uri
        let connected = try await withTimeout(seconds: 20) { try await MongoDatabase.connect(to: uri) }
        db = connected
        return connected
    }

    public static func collection(for file: String) -> String {
        if file == "start.json" { return "sprintStarts" }
        if file == "end.json" { return "sprintEnds" }
        if file.hasSuffix(".json") { return "events" }
        return "media"
    }

    // MARK: Upload (helper)

    public func upload(sprintId: String, file: String, data: Data) async throws {
        let db = try await database()
        let name = CloudStore.collection(for: file)
        var doc: Document
        if name == "media" {
            var buffer = ByteBufferAllocator().buffer(capacity: data.count)
            buffer.writeBytes(data)
            doc = [
                "_id": "\(sprintId)/\(file)", "sprintId": sprintId, "file": file,
                "contentType": file.hasSuffix(".mp4") ? "video/mp4" : "image/jpeg",
                "size": data.count, "data": Binary(buffer: buffer),
            ]
        } else {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CloudError.rejected("\(file) is not a JSON object")
            }
            doc = BSONBridge.document(from: object)
            if doc["_id"] == nil { doc["_id"] = "\(sprintId)/\(file)" }
        }
        let collection = db[name]
        let payload = doc
        let reply: InsertReply
        do {
            reply = try await withTimeout(seconds: 60) { try await collection.insert(payload) }
        } catch let failed as InsertReply {
            reply = failed
        }
        // 11000 = duplicate key: this exact record is already stored, which is what we want.
        if let errors = reply.writeErrors, let real = errors.first(where: { $0.code != 11000 }) {
            throw CloudError.rejected(real.message)
        }
    }

    // MARK: Read (dashboard "Cloud" view)

    /// Mirrors the cloud records into `cacheSprints`, using the same layout as the local vault.
    public func pull(into cacheSprints: URL, limit: Int = 300) async throws {
        let db = try await database()
        let fm = FileManager.default
        func save(_ docs: [Document], file: (Document) -> String?, sprint: (Document) -> String?) throws {
            for doc in docs {
                guard let sid = sprint(doc), let name = file(doc), Vault.isValid(name: "\(sid)__\(name)") else { continue }
                let dir = cacheSprints.appendingPathComponent(sid, isDirectory: true)
                let dest = dir.appendingPathComponent(name)
                if fm.fileExists(atPath: dest.path) { continue }
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let json = try JSONSerialization.data(withJSONObject: BSONBridge.json(from: doc), options: [.sortedKeys])
                try json.write(to: dest, options: .atomic)
            }
        }
        let starts = try await db["sprintStarts"].find().sort(["startedAt": -1]).limit(limit).drain()
        try save(starts, file: { _ in "start.json" }, sprint: { $0["_id"] as? String })
        let ends = try await db["sprintEnds"].find().sort(["endedAt": -1]).limit(limit).drain()
        try save(ends, file: { _ in "end.json" }, sprint: { $0["_id"] as? String })
        let events = try await db["events"].find().sort(["startedAt": -1]).limit(limit * 40).drain()
        // Site labels and parent decisions, so the cloud view can show the "under review" totals too.
        let sites = try await db["sites"].find().limit(5000).drain().compactMap { doc -> SiteEntry? in
            guard let host = doc["_id"] as? String, let state = doc["state"] as? String else { return nil }
            return SiteEntry(host: host, state: state, reason: doc["reason"] as? String, category: nil, updatedAt: nil,
                             allowedUntil: doc["allowedUntil"] as? String)
        }
        try fm.createDirectory(at: cacheSprints, withIntermediateDirectories: true)
        try JSONEncoder().encode(SiteList(sites: sites))
            .write(to: cacheSprints.deletingLastPathComponent().appendingPathComponent("sites.json"), options: .atomic)
        // Labelled searches (distraction text only; the service never stores the rest).
        let found = try await db["searches"].find().sort(["at": -1]).limit(3000).drain().compactMap { doc -> SearchEntry? in
            guard let id = doc["_id"] as? String, let at = doc["at"] as? String, let label = doc["label"] as? String else { return nil }
            return SearchEntry(id: id, at: at, label: label, engine: doc["engine"] as? String,
                               reason: doc["reason"] as? String, text: doc["text"] as? String)
        }
        try JSONEncoder().encode(SearchLog(searches: found.reversed()))
            .write(to: cacheSprints.deletingLastPathComponent().appendingPathComponent("searches.json"), options: .atomic)
        try save(events, file: { ($0["seq"] as? Int).map { "e\($0).json" } ?? ($0["seq"] as? Int32).map { "e\($0).json" } },
                 sprint: { $0["sprintId"] as? String })
    }

    public func media(sprintId: String, file: String) async throws -> Data? {
        let db = try await database()
        guard let doc = try await db["media"].findOne(["_id": "\(sprintId)/\(file)"]),
              let binary = doc["data"] as? Binary else { return nil }
        return binary.data
    }

    public func ping() async throws {
        let db = try await database()
        _ = try await withTimeout(seconds: 20) { try await db["sprintStarts"].find().limit(1).drain() }
    }
}

func withTimeout<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw CloudError.timeout
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

/// Plain JSON <-> BSON. Dates stay ISO-8601 strings, which sort correctly.
public enum BSONBridge {
    public static func document(from object: [String: Any]) -> Document {
        var doc = Document()
        for (key, value) in object.sorted(by: { $0.key < $1.key }) { doc[key] = primitive(from: value) }
        return doc
    }

    static func primitive(from value: Any) -> Primitive {
        switch value {
        case let s as String: return s
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
            if CFNumberIsFloatType(n) { return n.doubleValue }
            return n.intValue
        case let a as [Any]:
            var array = Document(isArray: true)
            for element in a { array.append(primitive(from: element)) }
            return array
        case let o as [String: Any]: return document(from: o)
        default: return Null()
        }
    }

    public static func json(from doc: Document) -> Any {
        if doc.isArray { return doc.values.map(jsonValue) }
        var out: [String: Any] = [:]
        for key in doc.keys { if let v = doc[key] { out[key] = jsonValue(v) } }
        return out
    }

    static func jsonValue(_ p: Primitive) -> Any {
        switch p {
        case let s as String: return s
        case let i as Int: return i
        case let i as Int32: return Int(i)
        case let d as Double: return d
        case let b as Bool: return b
        case let d as Document: return json(from: d)
        case let d as Date: return ISO8601DateFormatter().string(from: d)
        case let o as ObjectId: return o.hexString
        default: return NSNull()
        }
    }
}
