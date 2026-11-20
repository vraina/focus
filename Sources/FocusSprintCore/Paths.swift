import Foundation

/// Everything lives under one root-owned directory.
///   config.json   root 644  the parent's settings, fetched from their account (teen can read, not change)
///   service.json  root 600  this Mac's own token for the family service (teen cannot read)
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
    public static var inbox: URL { root.appendingPathComponent("inbox", isDirectory: true) }
    public static var vault: URL { root.appendingPathComponent("vault", isDirectory: true) }
    public static var status: URL { vault.appendingPathComponent("status.json") }

    public static var helperInstalled: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: inbox.path, isDirectory: &isDir) && isDir.boolValue
    }
}

/// Written by the helper so the app can show how things stand. It never contains the Mac's token.
public struct HelperStatus: Codable, Sendable {
    /// True once this Mac has been linked to a household member with a pairing code.
    public var linked: Bool
    /// The account's address with most of it hidden, e.g. "m•••@example.com".
    public var account: String?
    /// Who this Mac belongs to in the household, and whether they are a kid or an adult.
    public var memberName: String?
    public var memberKind: String?
    public var isAdult: Bool { memberKind == "adult" }
    /// The name the parent sees for this computer.
    public var deviceName: String?
    /// Set when the service refuses this Mac (for example it was removed on the website).
    public var linkProblem: String?
    /// Records and pictures still waiting on this Mac to be sent.
    public var pending: Int
    public var lastUploadAt: Date?
    public var lastError: String?
    public var updatedAt: Date

    public init(linked: Bool, account: String? = nil, memberName: String? = nil, memberKind: String? = nil,
                deviceName: String? = nil, linkProblem: String? = nil,
                pending: Int, lastUploadAt: Date? = nil, lastError: String? = nil, updatedAt: Date = Date()) {
        self.linked = linked; self.account = account; self.deviceName = deviceName; self.linkProblem = linkProblem
        self.memberName = memberName; self.memberKind = memberKind
        self.pending = pending; self.lastUploadAt = lastUploadAt; self.lastError = lastError; self.updatedAt = updatedAt
    }

    public static func load() -> HelperStatus? {
        guard let data = try? Data(contentsOf: Paths.status) else { return nil }
        return try? JSONCoding.decoder.decode(HelperStatus.self, from: data)
    }

    /// The helper rewrites its status every few seconds; a stale file means it is not running.
    public var isFresh: Bool { Date().timeIntervalSince(updatedAt) < 30 }
}
