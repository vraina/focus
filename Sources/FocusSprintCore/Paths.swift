import Foundation

/// Everything lives under one root-owned directory.
///   config.json   root 644  parent settings (teen can read, not change)
///   secrets.json  root 600  Atlas connection string (teen cannot read)
///   inbox/        1777      the app drops finished records here
///   vault/        root 755  the helper copies them here; teen can read, not delete
public enum Paths {
    public static var root: URL {
        if let override = ProcessInfo.processInfo.environment["FOCUSSPRINT_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return URL(fileURLWithPath: "/Library/Application Support/FocusSprint", isDirectory: true)
    }
    public static var config: URL { root.appendingPathComponent("config.json") }
    public static var secrets: URL { root.appendingPathComponent("secrets.json") }
    public static var inbox: URL { root.appendingPathComponent("inbox", isDirectory: true) }
    public static var vault: URL { root.appendingPathComponent("vault", isDirectory: true) }
    public static var status: URL { vault.appendingPathComponent("status.json") }

    public static var helperInstalled: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: inbox.path, isDirectory: &isDir) && isDir.boolValue
    }
}

/// Written by the helper so the app can show upload progress without reading secrets.
public struct HelperStatus: Codable, Sendable {
    public var mongoConfigured: Bool
    public var pending: Int
    public var lastUploadAt: Date?
    public var lastError: String?
    public var updatedAt: Date

    public init(mongoConfigured: Bool, pending: Int, lastUploadAt: Date?, lastError: String?, updatedAt: Date) {
        self.mongoConfigured = mongoConfigured; self.pending = pending
        self.lastUploadAt = lastUploadAt; self.lastError = lastError; self.updatedAt = updatedAt
    }

    public static func load() -> HelperStatus? {
        guard let data = try? Data(contentsOf: Paths.status) else { return nil }
        return try? JSONCoding.decoder.decode(HelperStatus.self, from: data)
    }

    /// The helper rewrites its status every few seconds; a stale file means it is not running.
    public var isFresh: Bool { Date().timeIntervalSince(updatedAt) < 30 }
}
