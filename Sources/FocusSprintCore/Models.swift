import Foundation

public enum CaptureMode: String, Codable, CaseIterable, Sendable {
    case screenshot, video
}

/// Parent-controlled settings. Stored root-owned, so a Standard account cannot change them.
public struct ParentConfig: Codable, Equatable, Sendable {
    public var captureMode: CaptureMode = .screenshot
    /// Length of the "first few seconds" / "last few seconds" clip in video mode.
    public var clipSeconds: Int = 5
    public var distractionDomains: [String] = ParentConfig.defaultDomains
    public var distractionApps: [String] = ParentConfig.defaultApps
    /// Uploaded sprints older than this are removed from the local vault (they stay in the cloud).
    public var keepLocalDays: Int = 90
    /// Outside sprints, keep recording visits to the known distractions above so the day has a total.
    public var trackAllDay: Bool = true

    public static let defaultDomains = [
        "instagram.com", "youtube.com", "youtu.be", "tiktok.com", "espn.com", "nba.com", "nfl.com",
        "bleacherreport.com", "twitch.tv", "netflix.com", "reddit.com", "x.com", "twitter.com",
        "facebook.com", "snapchat.com", "discord.com", "hotstar.com", "cricbuzz.com", "espncricinfo.com",
    ]
    public static let defaultApps = ["Instagram", "TikTok", "Discord", "Steam", "Messages", "TV", "Music", "Spotify"]

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        captureMode = try c.decodeIfPresent(CaptureMode.self, forKey: .captureMode) ?? .screenshot
        clipSeconds = min(15, max(2, try c.decodeIfPresent(Int.self, forKey: .clipSeconds) ?? 5))
        distractionDomains = try c.decodeIfPresent([String].self, forKey: .distractionDomains) ?? ParentConfig.defaultDomains
        distractionApps = try c.decodeIfPresent([String].self, forKey: .distractionApps) ?? ParentConfig.defaultApps
        keepLocalDays = max(1, try c.decodeIfPresent(Int.self, forKey: .keepLocalDays) ?? 90)
        trackAllDay = try c.decodeIfPresent(Bool.self, forKey: .trackAllDay) ?? true
    }

    public static func load() -> ParentConfig {
        guard let data = try? Data(contentsOf: Paths.config),
              let cfg = try? JSONCoding.decoder.decode(ParentConfig.self, from: data) else { return ParentConfig() }
        return cfg
    }
}

public struct SprintStart: Codable, Identifiable, Sendable {
    public var id: String
    public var device: String
    public var user: String
    public var task: String
    public var plannedSeconds: Int
    public var startedAt: Date
    public var allowedApps: [String]
    public var allowedBundleIds: [String]
    public var allowedDomains: [String]
    public var captureMode: CaptureMode
    /// nil / "sprint" = a timed sprint. "ambient" = a stretch of all-day tracking outside sprints.
    public var kind: String?
    /// Apps ticked for this sprint that are not Work apps on the person's list, and Work apps that were unticked.
    public var addedApps: [String]?
    public var removedApps: [String]?
    public var isAmbient: Bool { kind == "ambient" }

    enum CodingKeys: String, CodingKey {
        case id = "_id", device, user, task, plannedSeconds, startedAt, allowedApps, allowedBundleIds, allowedDomains, captureMode, kind, addedApps, removedApps
    }

    public init(id: String, device: String, user: String, task: String, plannedSeconds: Int, startedAt: Date,
                allowedApps: [String], allowedBundleIds: [String], allowedDomains: [String], captureMode: CaptureMode,
                kind: String? = nil) {
        self.kind = kind
        self.id = id; self.device = device; self.user = user; self.task = task
        self.plannedSeconds = plannedSeconds; self.startedAt = startedAt
        self.allowedApps = allowedApps; self.allowedBundleIds = allowedBundleIds
        self.allowedDomains = allowedDomains; self.captureMode = captureMode
    }
}

public enum SprintStatus: String, Codable, Sendable {
    case completed, endedEarly
}

public struct SprintEnd: Codable, Identifiable, Sendable {
    public var id: String
    public var endedAt: Date
    public var status: SprintStatus
    public var focusedSeconds: Double
    public var awaySeconds: Double
    public var switchCount: Int
    /// All-day tracking only: seconds the Mac was actually in use (not idle, locked or asleep).
    public var activeSeconds: Double?

    enum CodingKeys: String, CodingKey {
        case id = "_id", endedAt, status, focusedSeconds, awaySeconds, switchCount, activeSeconds
    }

    public init(id: String, endedAt: Date, status: SprintStatus, focusedSeconds: Double, awaySeconds: Double, switchCount: Int,
                activeSeconds: Double? = nil) {
        self.activeSeconds = activeSeconds
        self.id = id; self.endedAt = endedAt; self.status = status
        self.focusedSeconds = focusedSeconds; self.awaySeconds = awaySeconds; self.switchCount = switchCount
    }
}

public enum EventCategory: String, Codable, Sendable {
    /// Matches the parent's list of known distractions.
    case distraction
    /// Not on the sprint's allowed list, but not a known distraction either.
    case offTask
}

public struct MediaRef: Codable, Hashable, Sendable {
    public enum Role: String, Codable, Sendable { case start, end }
    public enum Kind: String, Codable, Sendable { case image, video }
    public var role: Role
    public var kind: Kind
    public var file: String
    public init(role: Role, kind: Kind, file: String) {
        self.role = role; self.kind = kind; self.file = file
    }
}

public struct DistractionEvent: Codable, Identifiable, Sendable {
    public var id: String
    public var sprintId: String
    public var seq: Int
    public var startedAt: Date
    public var endedAt: Date
    public var durationSeconds: Double
    public var appName: String
    public var bundleId: String
    public var title: String
    public var url: String?
    public var host: String?
    public var category: EventCategory
    public var media: [MediaRef]

    enum CodingKeys: String, CodingKey {
        case id = "_id", sprintId, seq, startedAt, endedAt, durationSeconds, appName, bundleId, title, url, host, category, media
    }

    public init(id: String, sprintId: String, seq: Int, startedAt: Date, endedAt: Date, durationSeconds: Double,
                appName: String, bundleId: String, title: String, url: String?, host: String?,
                category: EventCategory, media: [MediaRef]) {
        self.id = id; self.sprintId = sprintId; self.seq = seq; self.startedAt = startedAt; self.endedAt = endedAt
        self.durationSeconds = durationSeconds; self.appName = appName; self.bundleId = bundleId; self.title = title
        self.url = url; self.host = host; self.category = category; self.media = media
    }

    /// What the teen switched to, in the shortest useful form.
    public var label: String { host ?? appName }
}

public enum JSONCoding {
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return e
    }
    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

public enum Format {
    public static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(String(format: "%02d", s % 60))s" }
        return "\(s / 3600)h \(String(format: "%02d", (s % 3600) / 60))m"
    }

    public static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm:ss a"
        return f.string(from: date)
    }

    public static func newSprintId(now: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        let suffix = UUID().uuidString.prefix(6).lowercased()
        return "\(f.string(from: now))-\(suffix)"
    }
}
