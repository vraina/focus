import AppKit
import AVKit
import SwiftUI
import FocusSprintCore

enum HistorySource: String, CaseIterable, Identifiable {
    case local = "This Mac"
    case cloud = "Cloud"
    var id: String { rawValue }
}

enum CloudCache {
    static var sprints: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FocusSprint/cloud/sprints", isDirectory: true)
    }
    static var store: CloudStore? {
        guard let uri = Keychain.get("viewerURI"), !uri.isEmpty else { return nil }
        return CloudStore(uri: uri)
    }
}

struct HistoryView: View {
    @EnvironmentObject var engine: SprintEngine
    @State private var source: HistorySource = .local
    @State private var records: [SprintRecord] = []
    @State private var sites = SiteBook()
    @State private var searches: [SearchEntry] = []
    @State private var selection: String?
    @State private var message: String?
    @State private var syncing = false
    @State private var fingerprint = 0
    private let refreshTimer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 10) {
                Picker("", selection: $source) {
                    ForEach(HistorySource.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                if let message { Text(message).font(.system(size: 11)).foregroundStyle(.secondary) }
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(records) { record in
                            SprintRow(record: record, selected: record.id == selection)
                                .onTapGesture { selection = record.id }
                        }
                    }
                }
            }
            .padding(12)
            .frame(width: 280)

            Rectangle().fill(Theme.hairline).frame(width: 1)

            Group {
                if let record = records.first(where: { $0.id == selection }) {
                    SprintDetail(record: record, source: source, sites: sites, searches: searches)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "chart.bar.xaxis").font(.system(size: 38)).foregroundStyle(.tertiary)
                        Text(records.isEmpty ? "No sprints yet" : "Select a sprint").font(Theme.title(17))
                        if records.isEmpty {
                            Text("Finish a sprint and it shows up here.").font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 440, maxWidth: .infinity)
        }
        .onAppear(perform: reload)
        .onChange(of: source) { _, _ in reload() }
        .onChange(of: engine.phase) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: reload)
        }
        // A visit was just saved: the helper files it within half a second, then it shows here.
        .onChange(of: engine.savedVisits) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: reload)
        }
        .onReceive(refreshTimer) { _ in if source == .local { reload() } }
    }

    private func reload() {
        switch source {
        case .local:
            message = nil
            let folder = Paths.vault.appendingPathComponent("sprints")
            let known = fingerprint
            // Reading and decoding happens off the main thread, and only when something on disk changed.
            Task.detached(priority: .userInitiated) {
                // Labels and searches live in their own files, so their change times count too.
                var hasher = Hasher()
                hasher.combine(SprintReader.fingerprint(of: folder))
                for file in [Paths.searches, Paths.sites] {
                    hasher.combine(((try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date)?.timeIntervalSince1970)
                }
                let current = hasher.finalize()
                guard current != known else { return }
                let list = SprintReader.listForDisplay(in: folder)
                await MainActor.run {
                    guard source == .local else { return }
                    fingerprint = current
                    show(list)
                }
            }
        case .cloud:
            fingerprint = 0
            show(SprintReader.listForDisplay(in: CloudCache.sprints))
            guard let store = CloudCache.store else {
                message = "Add a read-only Atlas connection string under Parent settings to view cloud history."
                return
            }
            guard !syncing else { return }
            syncing = true
            message = "Syncing…"
            Task {
                do {
                    try await store.pull(into: CloudCache.sprints)
                    message = nil
                } catch {
                    message = "Could not reach the cloud: \(error)"
                }
                syncing = false
                if source == .cloud { show(SprintReader.listForDisplay(in: CloudCache.sprints)) }
            }
        }
    }

    private func show(_ list: [SprintRecord]) {
        sites = SiteBook(file: source == .local ? Paths.sites
                                                : CloudCache.sprints.deletingLastPathComponent().appendingPathComponent("sites.json"))
        searches = SearchLog.load(from: source == .local ? Paths.searches
            : CloudCache.sprints.deletingLastPathComponent().appendingPathComponent("searches.json"))
        records = list
        if selection == nil || !list.contains(where: { $0.id == selection }) { selection = list.first?.id }
    }
}

struct SprintRow: View {
    var record: SprintRecord
    var selected = false

    var body: some View {
        let distracted = 1 - Double(record.focusPercent) / 100
        HStack(spacing: 11) {
            ZStack {
                Ring(progress: Double(record.focusPercent) / 100, lineWidth: 4.5, tint: levelColor(distracted))
                Image(systemName: record.isAmbient ? "sun.max.fill" : "timer")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            }
            .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.start.task).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(record.isAmbient ? record.start.startedAt.formatted(date: .abbreviated, time: .omitted)
                                      : record.start.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    Text(record.isAmbient ? "\(100 - record.focusPercent)% distracted" : "\(record.focusPercent)% focused")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(levelColor(distracted))
                    Text("· \(record.events.count) switches")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    if record.interrupted { Text("· interrupted").font(.system(size: 11)).foregroundStyle(Theme.bad) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(selected ? Theme.brand.opacity(0.12) : Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(selected ? Theme.brand.opacity(0.5) : Theme.hairline, lineWidth: selected ? 1.5 : 1))
        .contentShape(Rectangle())
    }
}

struct SprintDetail: View {
    var record: SprintRecord
    var source: HistorySource
    var sites = SiteBook()
    var searches: [SearchEntry] = []
    @EnvironmentObject private var engine: SprintEngine

    /// The visit that is still going on, if it belongs on this page (today's summary, or the running sprint).
    private var liveVisit: (label: String, since: Date)? {
        guard source == .local, let away = engine.awayNow else { return nil }
        let today = Calendar.current.isDateInToday(record.start.startedAt)
        let mine = record.isAmbient ? today : (record.end == nil && !record.interrupted && engine.phase == .running)
        return mine ? (away.label, away.since) : nil
    }

    /// Searches made during this sprint, or on this day for the all-day record.
    private var ownSearches: [SearchEntry] {
        let from = record.isAmbient ? Calendar.current.startOfDay(for: record.start.startedAt) : record.start.startedAt
        let to = record.isAmbient ? from.addingTimeInterval(86400) : record.start.startedAt.addingTimeInterval(record.elapsedSeconds)
        return searches.filter { entry in entry.date.map { $0 >= from && $0 <= to } ?? false }
    }

    /// Visits to sites that have since been approved (by the reviewer or a parent) or relabelled productive.
    private var approvedSince: [DistractionEvent] {
        record.events.filter { $0.host.map(sites.isCleared) == true }
    }

    private var status: (text: String, tint: Color) {
        if record.isAmbient { return ("All-day tracking", Theme.brand) }
        if let end = record.end { return end.status == .completed ? ("Completed", Theme.good) : ("Ended early", Theme.warn) }
        return record.interrupted ? ("Interrupted", Theme.bad) : ("In progress", Theme.brand)
    }

    var body: some View {
        let distracted = 1 - Double(record.focusPercent) / 100
        ScrollView {
            // Lazy: cards and their pictures are only built as they scroll into view.
            LazyVStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Text(record.start.task).font(Theme.title(26))
                        Pill(text: status.text, tint: status.tint)
                    }
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                }

                // Four across when there is room, two by two in a narrow window, so titles are never cut off.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { ForEach(tiles.indices, id: \.self) { tiles[$0].frame(minWidth: 116) } }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) {
                        ForEach(tiles.indices, id: \.self) { tiles[$0] }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)

                if !record.isAmbient {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(text: "Timeline")
                        TimelineBar(record: record)
                    }
                    .card()
                }

                if !approvedSince.isEmpty {
                    let away = max(0, record.awaySeconds - approvedSince.reduce(0) { $0 + $1.durationSeconds })
                    let percent = Int((away / record.elapsedSeconds * 100).rounded())
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "checkmark.seal.fill").font(.system(size: 20)).foregroundStyle(Theme.good)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Leaving out \(approvedSince.count) visit\(approvedSince.count == 1 ? "" : "s") to sites approved since")
                                .font(.system(size: 13, weight: .semibold))
                            Text("\(percent)% distracted · \(Format.duration(away)) away · \(record.events.count - approvedSince.count) switches")
                                .font(Theme.number(17))
                            Text("The numbers above count every visit as it was recorded.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .card()
                }

                if !ownSearches.isEmpty { SearchCard(entries: ownSearches) }

                if let live = liveVisit {
                    let _ = engine.pulse
                    HStack(spacing: 10) {
                        Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Happening now: \(live.label)").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                            Text("It is added to the list below as soon as you leave it.").font(.system(size: 12)).foregroundStyle(.white.opacity(0.85))
                        }
                        Spacer()
                        Text(SprintEngine.clock(Date().timeIntervalSince(live.since))).font(Theme.number(20)).foregroundStyle(.white)
                    }
                    .padding(14)
                    .background(Theme.bad, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                if record.events.isEmpty && liveVisit == nil {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.seal.fill").font(.system(size: 20)).foregroundStyle(Theme.good)
                        Text(record.isAmbient ? "No distractions recorded this day." : "No switches away during this sprint. Nice work.")
                            .font(.system(size: 14, weight: .medium))
                        Spacer()
                    }
                    .card()
                } else if !record.events.isEmpty {
                    SectionLabel(text: record.isAmbient ? "Every switch away, all day · newest first" : "Every switch away · newest first")
                        .padding(.top, 4)
                    ForEach(record.events.reversed()) { event in
                        // A combined day spans several stored sessions, so each event's files are looked up by its own session.
                        EventCard(event: event,
                                  directory: record.directory.deletingLastPathComponent().appendingPathComponent(event.sprintId),
                                  source: source, cleared: event.host.map(sites.isCleared) == true)
                    }
                }
            }
            .padding(24)
        }
    }

    private var tiles: [StatTile] {
        let distracted = 1 - Double(record.focusPercent) / 100
        if record.isAmbient {
            return [StatTile(title: "Distracted", value: "\(100 - record.focusPercent)%", color: levelColor(distracted), icon: "gauge.medium"),
                    StatTile(title: "Switches", value: "\(record.events.count)", icon: "arrow.left.arrow.right"),
                    StatTile(title: "Time away", value: Format.duration(record.awaySeconds), icon: "clock"),
                    StatTile(title: "Tracked", value: Format.duration(record.elapsedSeconds), icon: "desktopcomputer")]
        }
        return [StatTile(title: "Focused", value: "\(record.focusPercent)%", color: levelColor(distracted), icon: "scope"),
                StatTile(title: "Switches", value: "\(record.events.count)", icon: "arrow.left.arrow.right"),
                StatTile(title: "Time away", value: Format.duration(record.awaySeconds), icon: "clock"),
                StatTile(title: "Best streak", value: Format.duration(record.longestFocusSeconds), icon: "flame")]
    }

    private var subtitle: String {
        if record.isAmbient {
            return "\(record.start.startedAt.formatted(date: .complete, time: .omitted)) · the whole day: sprints, and time outside them"
        }
        let base = "\(record.start.startedAt.formatted(date: .complete, time: .shortened)) · \(record.start.plannedSeconds / 60) min planned · \(record.start.user) on \(record.start.device)"
        return record.interrupted ? base + " · the app was quit mid-sprint" : base
    }
}

/// Web searches: how many of each kind, and the words of the distraction ones only.
struct SearchCard: View {
    var entries: [SearchEntry]

    var body: some View {
        let counts = SearchLog.counts(entries)
        let offTopic = Array(entries.filter { $0.label == "distraction" }.reversed()) // newest first
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                SectionLabel(text: "Web searches")
                Spacer()
                Pill(text: "\(counts.work) work", tint: Theme.good)
                Pill(text: "\(counts.distraction) distraction", tint: counts.distraction > 0 ? Theme.bad : .secondary)
                if counts.personal > 0 { Pill(text: "\(counts.personal) private", tint: .secondary, icon: "lock.fill") }
            }
            ForEach(offTopic) { entry in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.bad)
                        .frame(width: 26, height: 26)
                        .background(Theme.bad.opacity(0.13), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.text ?? "").font(.system(size: 14, weight: .semibold))
                        if let reason = entry.reason, !reason.isEmpty {
                            Text(reason).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    if let date = entry.date {
                        Text(date.formatted(date: .omitted, time: .shortened)).font(Theme.number(12)).foregroundStyle(.secondary)
                    }
                }
            }
            Text(offTopic.isEmpty ? "No distraction searches. Work searches are only counted, and private topics are never recorded."
                                  : "Only distraction searches are listed. Work searches are counted, and private topics are never recorded.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .card()
    }
}

/// The whole sprint as one bar: green is on task, red and amber are the visits away.
struct TimelineBar: View {
    var record: SprintRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.good.opacity(0.75))
                    ForEach(record.events) { event in
                        let x = event.startedAt.timeIntervalSince(record.start.startedAt) / record.elapsedSeconds
                        let w = event.durationSeconds / record.elapsedSeconds
                        Rectangle()
                            .fill(event.category == .distraction ? Theme.bad : Theme.warn)
                            .frame(width: max(2, geo.size.width * w))
                            .offset(x: geo.size.width * min(1, max(0, x)))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 14)
            HStack(spacing: 14) {
                Text(Format.clock(record.start.startedAt))
                Spacer()
                legend("On task", Theme.good)
                legend("Distraction", Theme.bad)
                legend("Off task", Theme.warn)
                Spacer()
                Text(Format.clock(record.start.startedAt.addingTimeInterval(record.elapsedSeconds)))
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func legend(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
        }
    }
}

struct EventCard: View {
    var event: DistractionEvent
    var directory: URL
    var source: HistorySource
    var cleared = false

    var body: some View {
        let tint = event.category == .distraction ? Theme.bad : Theme.warn
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: event.host != nil ? "globe" : "app.dashed")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 32, height: 32)
                    .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.host ?? event.appName).font(.system(size: 15, weight: .semibold))
                    Text(event.host != nil ? (event.title.isEmpty ? event.appName : "\(event.appName) · \(event.title)")
                                           : (event.title.isEmpty ? "App" : event.title))
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if cleared { Pill(text: "Approved since", tint: Theme.good, icon: "checkmark") }
                Pill(text: event.category == .distraction ? "Distraction" : "Off task", tint: tint)
            }

            HStack(spacing: 0) {
                figure("Started", Format.clock(event.startedAt), .primary)
                Divider().frame(height: 34).padding(.horizontal, 16)
                figure("Away for", Format.duration(event.durationSeconds), tint)
                Divider().frame(height: 34).padding(.horizontal, 16)
                figure("Ended", Format.clock(event.endedAt), .primary)
                Spacer()
            }

            if event.media.isEmpty {
                Text("No picture was captured for this switch.").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(event.media, id: \.self) { ref in
                        VStack(alignment: .leading, spacing: 5) {
                            SectionLabel(text: ref.role == .start ? "First seconds" : "Last seconds")
                            MediaView(ref: ref, sprintId: event.sprintId, directory: directory, source: source)
                        }
                    }
                }
            }
        }
        .card()
    }

    private func figure(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            SectionLabel(text: label)
            Text(value).font(Theme.number(22)).foregroundStyle(color)
        }
    }
}

/// Small versions of the captured pictures. A full-size screenshot is several megabytes once decoded;
/// History only needs a preview, made once off the main thread and then kept in memory.
enum Thumbnails {
    private static let cache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 300
        return cache
    }()

    static func cached(_ url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }

    static func load(_ url: URL, maxPixels: Int = 900) async -> NSImage? {
        if let hit = cached(url) { return hit }
        return await Task.detached(priority: .userInitiated) { () -> NSImage? in
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                                            kCGImageSourceCreateThumbnailWithTransform: true]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            let result = NSImage(cgImage: image, size: NSSize(width: image.width / 2, height: image.height / 2))
            cache.setObject(result, forKey: url as NSURL)
            return result
        }.value
    }
}

struct MediaView: View {
    var ref: MediaRef
    var sprintId: String
    var directory: URL
    var source: HistorySource
    @State private var ready = false
    @State private var failed = false
    @State private var preview: NSImage?

    private var url: URL { directory.appendingPathComponent(ref.file) }

    var body: some View {
        Group {
            if ready, ref.kind == .video {
                VideoPlayer(player: AVPlayer(url: url))
            } else if let preview {
                Image(nsImage: preview).resizable().aspectRatio(contentMode: .fit)
                    .onTapGesture { NSWorkspace.shared.open(url) }
                    .help("Click to open full size")
            } else {
                RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06))
                    .overlay(Text(failed ? "Not available yet" : "Loading…").font(.system(size: 12)).foregroundStyle(.secondary))
            }
        }
        .frame(maxWidth: 380)
        // Pictures keep their own shape; clips and placeholders get a fixed box.
        .frame(height: preview != nil && ref.kind == .image ? nil : 220)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))
        .task(id: url) { await load() }
    }

    private func load() async {
        preview = Thumbnails.cached(url)
        ready = FileManager.default.fileExists(atPath: url.path)
        failed = false
        if !ready {
            guard source == .cloud, let store = CloudCache.store else { failed = true; return }
            guard let data = try? await store.media(sprintId: sprintId, file: ref.file),
                  (try? data.write(to: url, options: .atomic)) != nil else { failed = true; return }
            ready = true
        }
        if ref.kind == .image, preview == nil {
            preview = await Thumbnails.load(url)
            failed = preview == nil
        }
    }
}
