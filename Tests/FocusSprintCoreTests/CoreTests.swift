import XCTest
import CoreGraphics
@testable import FocusSprintCore

final class CoreTests: XCTestCase {
    func ctx(_ bundle: String, _ name: String, url: String? = nil, title: String = "", browser: Bool = false) -> ActivityContext {
        ActivityContext(bundleId: bundle, appName: name, title: title, url: url, isBrowser: browser, isSelf: false)
    }

    func testClassifier() {
        let rules = FocusRules(allowedBundleIds: ["com.apple.dt.Xcode"], allowedDomains: ["https://www.KhanAcademy.org/math"],
                               distractionDomains: ["instagram.com", "youtube.com"], distractionApps: ["Discord"])
        XCTAssertEqual(rules.classify(ctx("com.apple.dt.Xcode", "Xcode")), .onTask)
        XCTAssertEqual(rules.classify(ctx("com.hnc.Discord", "Discord")), .offTask(.distraction))
        XCTAssertEqual(rules.classify(ctx("com.apple.Notes", "Notes")), .offTask(.offTask))
        let chrome = "com.google.Chrome"
        XCTAssertEqual(rules.classify(ctx(chrome, "Chrome", url: "https://www.khanacademy.org/x", browser: true)), .onTask)
        XCTAssertEqual(rules.classify(ctx(chrome, "Chrome", url: "https://www.instagram.com/reels", browser: true)), .offTask(.distraction))
        XCTAssertEqual(rules.classify(ctx(chrome, "Chrome", url: "https://m.youtube.com/watch", browser: true)), .offTask(.distraction))
        XCTAssertEqual(rules.classify(ctx(chrome, "Chrome", url: "https://notkhanacademy.org", browser: true)), .offTask(.offTask))
        XCTAssertEqual(rules.classify(ctx(chrome, "Chrome", url: "chrome://newtab/", browser: true)), .neutral)
        // No URL available (Firefox): judged by the tab title.
        XCTAssertEqual(rules.classify(ctx("org.mozilla.firefox", "Firefox", title: "Reels - Instagram", browser: true)), .offTask(.distraction))
        XCTAssertEqual(rules.classify(ctx("org.mozilla.firefox", "Firefox", title: "Algebra | Khanacademy", browser: true)), .onTask)
        XCTAssertEqual(rules.classify(ctx("com.apple.UserNotificationCenter", "UserNotificationCenter")), .neutral)
        var me = ctx("x", "FocusSprint"); me.isSelf = true
        XCTAssertEqual(rules.classify(me), .neutral)
    }

    func testKnownDistractionOutsideSprints() {
        let rules = FocusRules(allowedBundleIds: [], allowedDomains: [], distractionDomains: ["instagram.com"], distractionApps: ["Discord"])
        XCTAssertTrue(rules.isKnownDistraction(ctx("c", "Chrome", url: "https://www.instagram.com/reels", browser: true)))
        XCTAssertFalse(rules.isKnownDistraction(ctx("c", "Chrome", url: "https://docs.google.com", browser: true)))
        XCTAssertTrue(rules.isKnownDistraction(ctx("d", "Discord")))
        XCTAssertFalse(rules.isKnownDistraction(ctx("n", "Notes")))
        XCTAssertTrue(rules.isKnownDistraction(ctx("org.mozilla.firefox", "Firefox", title: "Instagram", browser: true)))
    }

    func testSiteLabelsDriveTheVerdict() {
        let rules = FocusRules(allowedBundleIds: [], allowedDomains: ["khanacademy.org"], distractionDomains: ["espn.com"], distractionApps: [])
        func entry(_ host: String, _ state: String, until: TimeInterval? = nil) -> SiteEntry {
            SiteEntry(host: host, state: state, reason: nil, category: nil, updatedAt: nil,
                      allowedUntil: until.map { ISO8601DateFormatter().string(from: Date().addingTimeInterval($0)) })
        }
        let sites = SiteBook(entries: [entry("coolmathgames.com", "distraction"), entry("wikipedia.org", "productive"),
                                       entry("youtube.com", "distraction"), entry("espn.com", "allowed"), entry("reddit.com", "locked"),
                                       entry("twitch.tv", "distraction", until: 1800), entry("tiktok.com", "distraction", until: -60)])
        func web(_ url: String) -> ActivityContext { ctx("c", "Chrome", url: url, browser: true) }
        XCTAssertEqual(rules.classify(web("https://coolmathgames.com"), sites: sites), .offTask(.distraction))
        XCTAssertEqual(rules.classify(web("https://wikipedia.org/wiki/Cell"), sites: sites), .onTask)
        XCTAssertEqual(rules.classify(web("https://youtube.com/watch"), sites: sites), .offTask(.distraction))
        // Inside an approved "needed for work" window the site is fine, on subdomains too; once it ends it counts again.
        XCTAssertEqual(rules.classify(web("https://twitch.tv/lecture"), sites: sites), .onTask)
        XCTAssertEqual(rules.classify(web("https://clips.twitch.tv/x"), sites: sites), .onTask)
        XCTAssertEqual(rules.classify(web("https://tiktok.com"), sites: sites), .offTask(.distraction))
        XCTAssertTrue(sites.isCleared("twitch.tv") && sites.isCleared("wikipedia.org") && !sites.isCleared("tiktok.com"))
        // An approved window also beats the parent's list, but a parent's "always a distraction" beats everything.
        let espnWindow = SiteBook(entries: [entry("espn.com", "distraction", until: 600), entry("reddit.com", "locked", until: 600)])
        XCTAssertEqual(rules.classify(web("https://espn.com"), sites: espnWindow), .onTask)
        XCTAssertEqual(rules.classify(web("https://reddit.com"), sites: espnWindow), .offTask(.distraction))
        // A parent's "always allow" beats the parent's own list; an AI label does not spread to subdomains.
        XCTAssertEqual(rules.classify(web("https://espn.com/nba"), sites: sites), .onTask)
        XCTAssertEqual(rules.classify(web("https://en.wikipedia.org"), sites: sites, awaitingLabel: true), .neutral)
        XCTAssertEqual(rules.classify(web("https://en.wikipedia.org"), sites: sites), .offTask(.offTask))
        XCTAssertTrue(rules.isKnownDistraction(web("https://reddit.com/r/nba"), sites: sites))
        XCTAssertFalse(rules.isKnownDistraction(web("https://espn.com"), sites: sites))
        XCTAssertFalse(rules.isKnownDistraction(web("https://unknown.example.org"), sites: sites))
        XCTAssertFalse(SiteRequest.isValidHost("../etc") || SiteRequest.isValidHost("localhost"))
    }

    func testContextKey() {
        let a = ctx("c", "Chrome", url: "https://www.instagram.com/a", browser: true)
        let b = ctx("c", "Chrome", url: "https://instagram.com/b", browser: true)
        XCTAssertEqual(a.key, b.key)
        XCTAssertNotEqual(a.key, ctx("c", "Chrome", url: "https://espn.com", browser: true).key)
    }

    func testMongoURIDatabase() {
        XCTAssertEqual(CloudStore.uri("mongodb+srv://u:p@c.x.mongodb.net/?retryWrites=true", withDatabase: "fs"),
                       "mongodb+srv://u:p@c.x.mongodb.net/fs?retryWrites=true")
        XCTAssertEqual(CloudStore.uri("mongodb+srv://u:p@c.x.mongodb.net", withDatabase: "fs"), "mongodb+srv://u:p@c.x.mongodb.net/fs")
        XCTAssertEqual(CloudStore.uri("mongodb://localhost:27017?x=1", withDatabase: "fs"), "mongodb://localhost:27017/fs?x=1")
        XCTAssertEqual(CloudStore.uri("mongodb://localhost/mine?x=1", withDatabase: "fs"), "mongodb://localhost/mine?x=1")
        XCTAssertEqual(CloudStore.uri("mongodb://localhost/", withDatabase: "fs"), "mongodb://localhost/fs")
    }

    func testVaultIngestIsAppendOnlyAndStrict() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fs-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = Vault(root: root)
        try vault.ensureDirectories()
        func put(_ name: String, _ text: String) { try! Data(text.utf8).write(to: vault.inbox.appendingPathComponent(name)) }

        put("20260101-100000-abc123__start.json", "first")
        put("20260101-100000-abc123__e1-start.jpg", "img")
        put("..__evil.json", "x")
        put("abc__..%2Fescape.json", "x")
        put("abc__notes.txt", "x")
        put(".tmp-half-written", "x")
        try FileManager.default.createSymbolicLink(at: vault.inbox.appendingPathComponent("abc__link.json"),
                                                   withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        XCTAssertEqual(vault.ingestInbox(), 2)

        let stored = vault.sprints.appendingPathComponent("20260101-100000-abc123/start.json")
        XCTAssertEqual(try String(contentsOf: stored), "first")
        XCTAssertEqual(vault.pendingItems().map(\.file).sorted(), ["e1-start.jpg", "start.json"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.sprints.appendingPathComponent("abc").path))
        // Only the fresh temp file is left alone; rejected files are removed from the inbox.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: vault.inbox.path), [".tmp-half-written"])

        // A second write with the same name must not replace the stored record.
        put("20260101-100000-abc123__start.json", "tampered")
        XCTAssertEqual(vault.ingestInbox(), 0)
        XCTAssertEqual(try String(contentsOf: stored), "first")

        vault.markUploaded(vault.pendingItems()[0])
        XCTAssertEqual(vault.pendingItems().count, 1)
    }

    func testRecordRoundTripThroughBSON() throws {
        let event = DistractionEvent(id: "s1-e2", sprintId: "s1", seq: 2, startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                     endedAt: Date(timeIntervalSince1970: 1_800_000_192), durationSeconds: 192.5,
                                     appName: "Chrome", bundleId: "com.google.Chrome", title: "Reels", url: "https://instagram.com/reels",
                                     host: "instagram.com", category: .distraction,
                                     media: [MediaRef(role: .start, kind: .image, file: "e2-start.jpg")])
        let json = try JSONCoding.encoder.encode(event)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        let doc = BSONBridge.document(from: object)
        XCTAssertEqual(doc["_id"] as? String, "s1-e2")
        let back = try JSONSerialization.data(withJSONObject: BSONBridge.json(from: doc))
        let decoded = try JSONCoding.decoder.decode(DistractionEvent.self, from: back)
        XCTAssertEqual(decoded.durationSeconds, 192.5)
        XCTAssertEqual(decoded.seq, 2)
        XCTAssertEqual(decoded.media, event.media)
        XCTAssertEqual(decoded.startedAt, event.startedAt)
    }

    func frame(_ gray: CGFloat, width: Int = 640, height: Int = 400) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
        ctx.setFillColor(CGColor(gray: gray, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    func testCaptionAndMedia() async throws {
        let captioned = MediaWriter.caption(frame(0.8), text: "START 2:03:22 PM  ·  AWAY 3m 12s  ·  instagram.com")
        XCTAssertEqual(captioned.width, 640)
        XCTAssertEqual(captioned.height, 440)
        let jpeg = try XCTUnwrap(MediaWriter.jpeg(captioned))
        XCTAssertEqual(jpeg.prefix(2), Data([0xFF, 0xD8]))
        if let out = ProcessInfo.processInfo.environment["FOCUSSPRINT_TEST_OUT"] {
            try jpeg.write(to: URL(fileURLWithPath: out).appendingPathComponent("caption.jpg"))
        }

        let frames = (0..<10).map { MediaWriter.caption(frame(CGFloat($0) / 10), text: "END 2:06:34 PM  ·  AWAY 3m 12s") }
        let mp4 = try await MediaWriter.mp4(frames: frames, fps: 2)
        XCTAssertGreaterThan(mp4.count, 500)
        XCTAssertEqual(String(data: mp4[4..<8], encoding: .ascii), "ftyp")
    }

    func testSprintStats() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let start = SprintStart(id: "s", device: "d", user: "u", task: "t", plannedSeconds: 1500, startedAt: t0,
                                allowedApps: [], allowedBundleIds: [], allowedDomains: [], captureMode: .screenshot)
        func ev(_ n: Int, _ from: Double, _ len: Double) -> DistractionEvent {
            DistractionEvent(id: "s-e\(n)", sprintId: "s", seq: n, startedAt: t0.addingTimeInterval(from),
                             endedAt: t0.addingTimeInterval(from + len), durationSeconds: len, appName: "A", bundleId: "a",
                             title: "", url: nil, host: nil, category: .offTask, media: [])
        }
        let end = SprintEnd(id: "s", endedAt: t0.addingTimeInterval(1000), status: .completed, focusedSeconds: 750, awaySeconds: 250, switchCount: 2)
        let record = SprintRecord(start: start, end: end, events: [ev(1, 100, 50), ev(2, 400, 200)], directory: URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(record.focusPercent, 75)
        XCTAssertEqual(record.longestFocusSeconds, 400) // 600 -> 1000
        XCTAssertFalse(record.interrupted)
        XCTAssertEqual(Format.duration(192), "3m 12s")
        XCTAssertEqual(Format.duration(8), "8s")
    }
}

/// Runs only when FOCUSSPRINT_TEST_MONGO points at a database that already holds uploaded sprints.
final class CloudReadTests: XCTestCase {
    func testPullAndMedia() async throws {
        guard let uri = ProcessInfo.processInfo.environment["FOCUSSPRINT_TEST_MONGO"] else { throw XCTSkip("no test database") }
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("fs-cloud-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }
        let store = CloudStore(uri: uri)
        try await store.ping()
        try await store.pull(into: cache)
        let records = SprintReader.list(in: cache)
        XCTAssertGreaterThanOrEqual(records.count, 2)
        let seeded = try XCTUnwrap(records.first { $0.id == "20261119-133000-abc123" })
        XCTAssertEqual(seeded.events.first?.host, "instagram.com")
        XCTAssertEqual(seeded.events.first?.durationSeconds, 192.4)
        let media = try await store.media(sprintId: seeded.id, file: "e1-start.jpg")
        XCTAssertEqual(media?.prefix(2), Data([0xFF, 0xD8]))
        // Re-sending an already stored record must be accepted silently (retry after a dropped connection).
        try await store.upload(sprintId: seeded.id, file: "e1-start.jpg", data: try XCTUnwrap(media))
        let live = try XCTUnwrap(records.first { $0.start.task == "Dev test sprint" })
        XCTAssertGreaterThanOrEqual(live.events.count, 4)
        XCTAssertNotNil(live.end)
    }
}
