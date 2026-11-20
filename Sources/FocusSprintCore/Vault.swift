import Foundation

/// App side: hand a finished file to the helper. Written under a temporary name and renamed,
/// so the helper never sees a half-written file.
public enum Inbox {
    public static func drop(sprintId: String, file: String, data: Data) throws {
        let name = "\(sprintId)__\(file)"
        guard Vault.isValid(name: name) else { throw CocoaError(.fileWriteInvalidFileName) }
        let tmp = Paths.inbox.appendingPathComponent(".tmp-\(UUID().uuidString)")
        try data.write(to: tmp)
        try FileManager.default.moveItem(at: tmp, to: Paths.inbox.appendingPathComponent(name))
    }
}

public struct PendingItem: Sendable {
    public var sprintId: String
    public var file: String
    public var marker: URL
    public var source: URL
}

/// Helper side. Runs as root: copies inbox files into the vault (root-owned, so a Standard
/// account cannot delete or alter them) and keeps a marker per file until it is uploaded.
public final class Vault {
    public static let maxFileBytes = 12 * 1024 * 1024
    public let root: URL
    public var inbox: URL { root.appendingPathComponent("inbox", isDirectory: true) }
    public var vault: URL { root.appendingPathComponent("vault", isDirectory: true) }
    public var sprints: URL { vault.appendingPathComponent("sprints", isDirectory: true) }
    public var pending: URL { vault.appendingPathComponent("pending", isDirectory: true) }
    private let fm = FileManager.default

    public init(root: URL = Paths.root) { self.root = root }

    public func ensureDirectories() throws {
        for (url, mode) in [(root, 0o755), (inbox, 0o1777), (vault, 0o755), (sprints, 0o755), (pending, 0o755)] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            chmod(url.path, mode_t(mode))
        }
    }

    /// `<sprintId>__<file>` with a conservative character set: no slashes, no leading dots.
    public static func isValid(name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9][A-Za-z0-9-]{0,63}__[A-Za-z0-9][A-Za-z0-9-]{0,63}\.(json|jpg|mp4)$"#,
                   options: .regularExpression) != nil
    }

    static func split(_ name: String) -> (sprintId: String, file: String)? {
        guard let r = name.range(of: "__") else { return nil }
        return (String(name[..<r.lowerBound]), String(name[r.upperBound...]))
    }

    /// Moves everything waiting in the inbox into the vault. Returns how many files were accepted.
    @discardableResult
    public func ingestInbox() -> Int {
        guard let names = try? fm.contentsOfDirectory(atPath: inbox.path) else { return 0 }
        var accepted = 0
        for name in names {
            let src = inbox.appendingPathComponent(name)
            if name.hasPrefix(".tmp-") {
                // Leftover temp file from an app that died mid-write.
                if let date = (try? fm.attributesOfItem(atPath: src.path))?[.modificationDate] as? Date,
                   Date().timeIntervalSince(date) > 3600 { unlink(src.path) }
                continue
            }
            guard Vault.isValid(name: name), let parts = Vault.split(name), let data = readRegularFile(src) else {
                unlink(src.path)
                continue
            }
            let dir = sprints.appendingPathComponent(parts.sprintId, isDirectory: true)
            let dest = dir.appendingPathComponent(parts.file)
            // Append-only: a record that already exists is never replaced.
            if !fm.fileExists(atPath: dest.path) {
                do {
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                    chmod(dir.path, 0o755)
                    try data.write(to: dest, options: .atomic)
                    chmod(dest.path, 0o644)
                    fm.createFile(atPath: pending.appendingPathComponent(name).path, contents: nil)
                    accepted += 1
                } catch {
                    continue // disk problem: leave the file in the inbox and retry on the next pass
                }
            }
            unlink(src.path)
        }
        return accepted
    }

    /// Reads without following symlinks, so the inbox cannot be used to make root read another file.
    private func readRegularFile(_ url: URL) -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size > 0, st.st_size <= Vault.maxFileBytes else { return nil }
        return try? handle.readToEnd()
    }

    public func pendingItems() -> [PendingItem] {
        let names = ((try? fm.contentsOfDirectory(atPath: pending.path)) ?? []).sorted()
        return names.compactMap { name in
            guard let parts = Vault.split(name) else { return nil }
            return PendingItem(sprintId: parts.sprintId, file: parts.file,
                               marker: pending.appendingPathComponent(name),
                               source: sprints.appendingPathComponent(parts.sprintId).appendingPathComponent(parts.file))
        }
    }

    public func markUploaded(_ item: PendingItem) {
        unlink(item.marker.path)
    }

    /// Frees disk space: removes sprints older than `keepDays`, but only once everything in them is uploaded.
    public func prune(keepDays: Int) {
        let waiting = Set(pendingItems().map(\.sprintId))
        let cutoff = Date().addingTimeInterval(-Double(keepDays) * 86400)
        for name in (try? fm.contentsOfDirectory(atPath: sprints.path)) ?? [] where !waiting.contains(name) {
            let dir = sprints.appendingPathComponent(name)
            if let date = (try? fm.attributesOfItem(atPath: dir.path))?[.modificationDate] as? Date, date < cutoff {
                try? fm.removeItem(at: dir)
            }
        }
    }
}

/// One sprint as shown in the dashboard, read from the vault or from a cloud cache with the same layout.
public struct SprintRecord: Identifiable, Sendable {
    public var start: SprintStart
    public var end: SprintEnd?
    public var events: [DistractionEvent]
    public var directory: URL
    /// Set on the one-per-day record that combines all the all-day tracking stretches of that day.
    public var merged: (id: String, elapsed: Double, away: Double)?
    public var id: String { merged?.id ?? start.id }
    public var isAmbient: Bool { start.isAmbient }

    public var plannedEnd: Date { start.startedAt.addingTimeInterval(Double(start.plannedSeconds)) }
    /// No end record and the planned time has passed: the app was quit or killed mid-sprint.
    public var interrupted: Bool { !isAmbient && end == nil && Date() > plannedEnd.addingTimeInterval(15) }
    public var awaySeconds: Double { merged?.away ?? end?.awaySeconds ?? events.reduce(0) { $0 + $1.durationSeconds } }
    public var elapsedSeconds: Double {
        if let merged { return max(1, merged.elapsed) }
        if isAmbient {
            // Screen-in-use time. Without an end record (app killed, or still running) fall back to what the events show.
            if let active = end?.activeSeconds { return max(1, active) }
            let span = (events.last?.endedAt ?? start.startedAt).timeIntervalSince(start.startedAt)
            return max(1, span, events.reduce(0) { $0 + $1.durationSeconds })
        }
        if let end { return max(1, end.endedAt.timeIntervalSince(start.startedAt)) }
        if interrupted { return max(1, (events.last?.endedAt ?? start.startedAt).timeIntervalSince(start.startedAt)) }
        return max(1, Date().timeIntervalSince(start.startedAt))
    }
    public var focusPercent: Int { Int((max(0, elapsedSeconds - awaySeconds) / elapsedSeconds * 100).rounded()) }
    public var longestFocusSeconds: Double {
        var best = 0.0, cursor = start.startedAt
        for e in events {
            best = max(best, e.startedAt.timeIntervalSince(cursor))
            cursor = e.endedAt
        }
        return max(best, start.startedAt.addingTimeInterval(elapsedSeconds).timeIntervalSince(cursor))
    }
}

public enum SprintReader {
    public static func list(in sprintsDir: URL) -> [SprintRecord] {
        let fm = FileManager.default
        let dec = JSONCoding.decoder
        var out: [SprintRecord] = []
        for name in (try? fm.contentsOfDirectory(atPath: sprintsDir.path)) ?? [] {
            let dir = sprintsDir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("start.json")),
                  let start = try? dec.decode(SprintStart.self, from: data) else { continue }
            let end = (try? Data(contentsOf: dir.appendingPathComponent("end.json")))
                .flatMap { try? dec.decode(SprintEnd.self, from: $0) }
            let events = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { $0.range(of: #"^e\d+\.json$"#, options: .regularExpression) != nil }
                .compactMap { try? Data(contentsOf: dir.appendingPathComponent($0)) }
                .compactMap { try? dec.decode(DistractionEvent.self, from: $0) }
                .sorted { $0.seq < $1.seq }
            out.append(SprintRecord(start: start, end: end, events: events, directory: dir))
        }
        return out.sorted { $0.start.startedAt > $1.start.startedAt }
    }

    /// Sprints as they are, plus one combined "All day" record per calendar day of outside-sprint tracking.
    public static func listForDisplay(in sprintsDir: URL) -> [SprintRecord] {
        let all = list(in: sprintsDir)
        var out = all.filter { !$0.isAmbient }
        let calendar = Calendar.current
        let byDay = Dictionary(grouping: all.filter(\.isAmbient)) { calendar.startOfDay(for: $0.start.startedAt) }
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd"
        for (day, parts) in byDay {
            let ordered = parts.sorted { $0.start.startedAt < $1.start.startedAt }
            var record = ordered[ordered.count - 1]
            record.start.task = "All day, outside sprints"
            record.end = nil
            record.events = ordered.flatMap(\.events).sorted { $0.startedAt < $1.startedAt }
            record.merged = ("day-" + stamp.string(from: day),
                             ordered.reduce(0) { $0 + $1.elapsedSeconds }, ordered.reduce(0) { $0 + $1.awaySeconds })
            out.append(record)
        }
        return out.sorted { $0.start.startedAt > $1.start.startedAt }
    }
}
