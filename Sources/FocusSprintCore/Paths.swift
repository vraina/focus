import Foundation

/// Everything lives under one root-owned directory. Each Mac login has its own area, because each login
/// is linked to its own household member:
///
///   inbox/, requests/        1777      any login's app drops finished records and requests here
///   service.json             root 600  this computer's token for the service (nobody but root can read it)
///   users/<uid>/             root 700  readable by that login only (through an access-control entry)
///     config.json                      the settings that apply to that login's member
///     vault/                           its records, labels, answers and status; it can read, not delete
///
/// Which login a dropped file belongs to is taken from who owns the file, never from what the file says.
public enum Paths {
    public static var root: URL {
        if let override = ProcessInfo.processInfo.environment["FOCUSSPRINT_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return URL(fileURLWithPath: "/Library/Application Support/FocusSprint", isDirectory: true)
    }

    /// Whose area the per-login paths below point at. In the app this is always the person logged in.
    /// The helper serves every login and sets this to the one it is working on; it handles one at a time.
    public static var uid: uid_t = getuid()

    public static func home(for uid: uid_t) -> URL { root.appendingPathComponent("users/\(uid)", isDirectory: true) }
    public static var home: URL { home(for: uid) }
    public static var users: URL { root.appendingPathComponent("users", isDirectory: true) }
    public static var inbox: URL { root.appendingPathComponent("inbox", isDirectory: true) }

    public static var config: URL { home.appendingPathComponent("config.json") }
    public static var vault: URL { home.appendingPathComponent("vault", isDirectory: true) }
    public static var status: URL { vault.appendingPathComponent("status.json") }

    public static var helperInstalled: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: inbox.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Every login that has an area on this Mac.
    public static var knownUsers: [uid_t] {
        // Never root itself: the installed helper runs as root, and root is not a person with records.
        ((try? FileManager.default.contentsOfDirectory(atPath: users.path)) ?? []).compactMap { uid_t($0) }.filter { $0 != 0 }.sorted()
    }

    /// The Mac login name for a uid, e.g. "mia".
    public static func loginName(_ uid: uid_t) -> String {
        guard let entry = getpwuid(uid), let name = entry.pointee.pw_name else { return "user\(uid)" }
        return String(cString: name)
    }

    /// Creates a login's area. As root it is closed to everyone except that login, who may read it.
    public static func prepareHome(for uid: uid_t) {
        let fm = FileManager.default
        let home = home(for: uid)
        let fresh = !fm.fileExists(atPath: home.path)
        for (url, mode) in [(users, 0o755), (home, getuid() == 0 ? 0o700 : 0o755), (home.appendingPathComponent("vault"), 0o755),
                            (home.appendingPathComponent("vault/sprints"), 0o755), (home.appendingPathComponent("vault/pending"), 0o755),
                            (home.appendingPathComponent("vault/outbox"), 0o755)] {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
            chmod(url.path, mode_t(mode))
        }
        guard getuid() == 0, uid != 0, !opened.contains(uid) else { return }
        // Let that one login look inside; the files themselves are ordinary root-owned, read-only files.
        // Done once per helper run for every login, not only when the area is new, so an area that somehow
        // lost the rule (or was made before it could be set) is repaired the next time the helper starts.
        for arguments in [["-N", home.path],
                          ["+a", "user:\(loginName(uid)) allow list,search,readattr,readextattr,readsecurity", home.path]] {
            let grant = Process()
            grant.executableURL = URL(fileURLWithPath: "/bin/chmod")
            grant.arguments = arguments
            let pipe = Pipe()
            grant.standardError = pipe
            guard (try? grant.run()) != nil else { lastGrantProblem = "could not run chmod"; return }
            let said = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            grant.waitUntilExit()
            if grant.terminationStatus != 0 { lastGrantProblem = "chmod \(arguments[0]) for \(loginName(uid)): \(said.trimmingCharacters(in: .whitespacesAndNewlines))"; return }
        }
        _ = fresh
        opened.insert(uid)
    }
    nonisolated(unsafe) private static var opened = Set<uid_t>()
    /// Why a login could not be given access to its own area, for the helper's log. Nil when all is well.
    nonisolated(unsafe) public static var lastGrantProblem: String?

    /// What the app in the current login can see of the helper, in words, when something is wrong. Nil when fine.
    public static func helperProblem() -> String? {
        if !helperInstalled { return "not installed" }
        if access(home.path, X_OK) != 0 {
            return errno == ENOENT ? "the helper has not set up this login yet" : "this login is not allowed into its own records (\(String(cString: strerror(errno))))"
        }
        guard let status = HelperStatus.load() else {
            return FileManager.default.fileExists(atPath: Paths.status.path) ? "the helper's status cannot be read" : "the helper has not reported for this login yet"
        }
        if !status.isFresh { return "the helper last reported \(Int(Date().timeIntervalSince(status.updatedAt))) seconds ago" }
        return nil
    }
}

/// Written by the helper so the app can show how things stand. It never contains the Mac's token.
public struct HelperStatus: Codable, Sendable {
    /// True once this Mac has been linked to a household member with a pairing code.
    public var linked: Bool
    /// The account's address with most of it hidden, e.g. "m•••@example.com".
    public var account: String?
    /// Who this Mac login belongs to in the household, and whether they are a kid or an adult.
    /// Empty while the computer is linked but nobody has said whose this login is.
    public var memberName: String?
    public var memberKind: String?
    public var isAdult: Bool { memberKind == "adult" }
    /// The computer is linked, but this login still has to be assigned to someone.
    public var needsProfile: Bool { linked && linkProblem == nil && (memberName ?? "").isEmpty }
    /// The kid profiles this login may pick from, when it has not been assigned yet.
    public var profiles: [Profile]?

    public struct Profile: Codable, Sendable, Identifiable, Hashable {
        public var id: String
        public var name: String
        public init(id: String, name: String) { self.id = id; self.name = name }
    }
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
