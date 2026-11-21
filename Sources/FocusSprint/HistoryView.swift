import AppKit
import AVKit
import SwiftUI
import FocusSprintCore

/// Where History reads from. The Mac only shows what it recorded itself; the parent website shows every computer.
enum HistorySource { case local }

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
    /// When the Mac was being tracked on each day (sprints and all-day stretches), for the all-day circle and bar.
    @State private var tracked: [Date: [DateInterval]] = [:]
    private let refreshTimer = Ticker.every3

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 10) {
                if let message { Text(message).font(.system(size: 11)).foregroundStyle(Theme.soft) }
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(records) { record in
                            Button { selection = record.id } label: {
                                SprintRow(record: record, shape: RecordShape(record, tracked: tracked), selected: record.id == selection)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(record.id == selection ? .isSelected : [])
                        }
                    }
                }
            }
            .padding(EdgeInsets(top: 44, leading: 10, bottom: 12, trailing: 10))
            .frame(width: 256)

            Rectangle().fill(Theme.hairline).frame(width: 1)

            Group {
                if let record = records.first(where: { $0.id == selection }) {
                    SprintDetail(record: record, shape: RecordShape(record, tracked: tracked), source: source, sites: sites, searches: searches)
                } else {
                    VStack(spacing: 8) {
                        Text(records.isEmpty ? "No sprints yet" : "Select a sprint").font(Theme.title(22)).foregroundStyle(Theme.ink)
                        if records.isEmpty {
                            Text("Finish a sprint and it shows up here.").font(.system(size: 14)).foregroundStyle(Theme.soft)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 440, maxWidth: .infinity)
        }
        .onAppear(perform: reload)
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
                let calendar = Calendar.current
                var stretches: [Date: [DateInterval]] = [:]
                for part in SprintReader.list(in: folder) {
                    stretches[calendar.startOfDay(for: part.start.startedAt), default: []]
                        .append(DateInterval(start: part.start.startedAt, duration: part.elapsedSeconds))
                }
                let days = stretches
                await MainActor.run {
                    fingerprint = current
                    tracked = days
                    show(list)
                }
            }
        }
    }

    private func show(_ list: [SprintRecord]) {
        sites = SiteBook(file: Paths.sites)
        searches = SearchLog.load()
        records = list
        if selection == nil || !list.contains(where: { $0.id == selection }) { selection = list.first?.id }
    }
}

/// What a record's circle and bar are drawn from: the whole stretch of time it covers, when in it the Mac
/// was being tracked, and the visits away. A sprint is tracked from start to end. The all-day record runs
/// from the day's first tracked moment to its last, with gaps where the Mac was not in use.
struct RecordShape {
    var from: Date
    var to: Date
    var spans: [DateInterval]
    var events: [DistractionEvent]

    init(_ record: SprintRecord, tracked: [Date: [DateInterval]]) {
        events = record.events
        if record.isAmbient {
            let day = Calendar.current.startOfDay(for: record.start.startedAt)
            var parts = tracked[day] ?? []
            // A visit is tracked time too, even where its stretch's own times fall short of it.
            parts += record.events.map { DateInterval(start: $0.startedAt, end: max($0.startedAt, $0.endedAt)) }
            from = parts.map(\.start).min() ?? day
            to = max(parts.map(\.end).max() ?? day, from.addingTimeInterval(1))
            spans = parts
        } else {
            from = record.start.startedAt
            to = from.addingTimeInterval(record.elapsedSeconds)
            spans = [DateInterval(start: from, end: to)]
        }
    }

    private func fraction(_ date: Date) -> Double {
        min(1, max(0, date.timeIntervalSince(from) / max(1, to.timeIntervalSince(from))))
    }

    /// Green where tracked and on task, then red and amber over it for the visits away. The rest stays grey.
    var arcs: [RingArc] {
        spans.map { RingArc(from: fraction($0.start), to: fraction($0.end), color: Theme.good) }
            + events.map { RingArc(from: fraction($0.startedAt), to: fraction($0.endedAt),
                                   color: $0.category == .distraction ? Theme.bad : Theme.warn) }
    }
}

struct SprintRow: View {
    var record: SprintRecord
    var shape: RecordShape
    var selected = false

    var body: some View {
        let tone = Theme.text(for: levelColor(1 - Double(record.focusPercent) / 100))
        HStack(spacing: 10) {
            // No least width for green here: a few seconds of tracking should not look like a stretch of the day.
            ArcRing(arcs: shape.arcs, lineWidth: 6, minPoints: 2.5)
                .frame(width: 42, height: 42)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.start.task).font(.system(size: 13.5, weight: .bold)).foregroundStyle(Theme.ink).lineLimit(1)
                Text(record.isAmbient ? record.start.startedAt.formatted(date: .abbreviated, time: .omitted)
                                      : record.start.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 11.5)).foregroundStyle(Theme.soft).lineLimit(1)
                Text((record.isAmbient ? "\(100 - record.focusPercent)% distracted" : "\(record.focusPercent)% focused")
                     + " · \(record.events.count) switches" + (record.interrupted ? " · interrupted" : ""))
                    .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(tone)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(selected ? Theme.brandTint : Color.clear, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(selected ? Theme.brand : Color.clear, lineWidth: 1.5))
        .contentShape(Rectangle())
    }
}

struct SprintDetail: View {
    var record: SprintRecord
    var shape: RecordShape
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

    /// Every picture and clip on this page, in the order shown, for the viewer's previous / next.
    private var gallery: [ViewerItem] {
        record.events.reversed().flatMap { event in
            event.media.map { ref in
                ViewerItem(event: event, ref: ref,
                           directory: record.directory.deletingLastPathComponent().appendingPathComponent(event.sprintId),
                           source: source)
            }
        }
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
        ScrollView {
            // Lazy: cards and their pictures are only built as they scroll into view.
            LazyVStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        Text(record.start.task).font(Theme.title(28)).kerning(-0.6).foregroundStyle(Theme.ink)
                        Pill(text: status.text, tint: status.tint)
                    }
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.soft)
                }

                // Four across when there is room, two by two in a narrow window, so titles are never cut off.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { ForEach(tiles.indices, id: \.self) { tiles[$0].frame(minWidth: 116) } }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
                        ForEach(tiles.indices, id: \.self) { tiles[$0] }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(text: "Timeline")
                    TimelineBar(shape: shape, showsGaps: record.isAmbient)
                    if !approvedSince.isEmpty {
                        let away = max(0, record.awaySeconds - approvedSince.reduce(0) { $0 + $1.durationSeconds })
                        let percent = Int((away / record.elapsedSeconds * 100).rounded())
                        Rectangle().fill(Theme.hairline).frame(height: 1).padding(.top, 2)
                        (Text("Leaving out \(approvedSince.count) visit\(approvedSince.count == 1 ? "" : "s") to sites approved since: ")
                            .fontWeight(.bold).foregroundColor(Theme.ink)
                         + Text("\(percent)% distracted · \(Format.duration(away)) away · \(record.events.count - approvedSince.count) switches. ")
                         + Text("The numbers above count every visit as it was recorded."))
                            .font(.system(size: 12)).foregroundStyle(Theme.soft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .card(padding: 16)

                Ticking { if let live = liveVisit {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Happening now: \(live.label)").font(.system(size: 14, weight: .bold))
                            Text("It is added to the list below as soon as you leave it.").font(.system(size: 12))
                        }
                        Spacer()
                        Text(SprintEngine.clock(Date().timeIntervalSince(live.since))).font(Theme.number(20))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(Theme.badFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                } }

                if !ownSearches.isEmpty { SearchCard(entries: ownSearches) }

                if record.events.isEmpty && liveVisit == nil {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.seal.fill").font(.system(size: 20)).foregroundStyle(Theme.good)
                        Text(record.isAmbient ? "No distractions recorded this day." : "No switches away during this sprint. Nice work.")
                            .font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.ink)
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
                                  source: source, cleared: event.host.map(sites.isCleared) == true,
                                  onOpen: { ref in MediaViewer.shared.open(gallery, at: event.id + "/" + ref.file) })
                    }
                }
            }
            .padding(EdgeInsets(top: 44, leading: 20, bottom: 24, trailing: 20))
        }
    }

    private var tiles: [StatTile] {
        let distracted = Theme.text(for: levelColor(1 - Double(record.focusPercent) / 100))
        if record.isAmbient {
            return [StatTile(title: "Distracted", value: "\(100 - record.focusPercent)%", color: distracted),
                    StatTile(title: "Switches", value: "\(record.events.count)"),
                    StatTile(title: "Time away", value: Format.duration(record.awaySeconds)),
                    StatTile(title: "Tracked", value: Format.duration(record.elapsedSeconds))]
        }
        return [StatTile(title: "Focused", value: "\(record.focusPercent)%", color: distracted),
                StatTile(title: "Switches", value: "\(record.events.count)"),
                StatTile(title: "Time away", value: Format.duration(record.awaySeconds)),
                StatTile(title: "Best streak", value: Format.duration(record.longestFocusSeconds))]
    }

    private var subtitle: String {
        if record.isAmbient {
            return "\(record.start.startedAt.formatted(date: .complete, time: .omitted)) · the whole day: sprints, and time outside them"
        }
        let base = "\(record.start.startedAt.formatted(date: .complete, time: .shortened)) · \(record.start.isOpenEnded ? "until stopped" : "\(record.start.plannedSeconds / 60) min planned") · \(record.start.user) on \(record.start.device)"
        return record.interrupted ? base + " · the app was quit mid-sprint" : base
    }
}

/// Web searches: how many of each kind, and the words of the distraction ones only.
struct SearchCard: View {
    var entries: [SearchEntry]

    var body: some View {
        let counts = SearchLog.counts(entries)
        let offTopic = Array(entries.filter { $0.label == "distraction" }.reversed()) // newest first
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                SectionLabel(text: "Web searches")
                Spacer()
                Pill(text: "\(counts.work) work", tint: Theme.good)
                Pill(text: "\(counts.distraction) distraction", tint: counts.distraction > 0 ? Theme.bad : Theme.soft)
                if counts.personal > 0 { Pill(text: "\(counts.personal) private", tint: Theme.soft, icon: "lock.fill") }
            }
            ForEach(offTopic) { entry in
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.text ?? "").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                        if let reason = entry.reason, !reason.isEmpty {
                            Text(reason).font(.system(size: 12)).foregroundStyle(Theme.soft)
                        }
                    }
                    Spacer(minLength: 8)
                    if let date = entry.date {
                        Text(date.formatted(date: .omitted, time: .shortened)).font(.system(size: 12)).foregroundStyle(Theme.soft)
                    }
                }
            }
            Text(offTopic.isEmpty ? "No distraction searches. Work searches are only counted, and private topics are never recorded."
                                  : "Only distraction searches are listed. Work searches are counted, and private topics are never recorded.")
                .font(.system(size: 12)).foregroundStyle(Theme.soft)
        }
        .card(padding: 16)
    }
}

/// The record as one straight bar: green is on task, red and amber are the visits away, and (for the
/// all-day record) grey is where the Mac was not in use.
struct TimelineBar: View {
    var shape: RecordShape
    var showsGaps = false

    var body: some View {
        let arcs = shape.arcs
        VStack(alignment: .leading, spacing: 8) {
            // One drawing for the whole bar, however many visits the day had.
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.track))
                for arc in arcs {
                    // The same least width as the circles, so a very short switch still shows.
                    let span = ArcRing.span(arc, least: Double(2 / max(1, size.width)))
                    context.fill(Path(CGRect(x: size.width * span.from, y: 0, width: size.width * (span.to - span.from), height: size.height)),
                                 with: .color(arc.color))
                }
            }
            .clipShape(PillShape())
            .frame(height: 22)
            .accessibilityElement()
            .accessibilityLabel("The record as one bar: on task in green, visits away in red and amber")
            HStack(spacing: 14) {
                Text(Format.clock(shape.from)).lineLimit(1).fixedSize()
                Spacer(minLength: 0)
                LegendRow(items: [("On task", Theme.good), ("Distraction", Theme.bad), ("Off task", Theme.warn)]
                                 + (showsGaps ? [("Not in use", Theme.track)] : []))
                Spacer(minLength: 0)
                Text(Format.clock(shape.to)).lineLimit(1).fixedSize()
            }
            .font(.system(size: 11.5)).foregroundStyle(Theme.soft)
        }
    }
}

struct EventCard: View {
    var event: DistractionEvent
    var directory: URL
    var source: HistorySource
    var cleared = false
    var onOpen: (MediaRef) -> Void = { _ in }

    var body: some View {
        let tint = event.category == .distraction ? Theme.bad : Theme.warn
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.host ?? event.appName).font(Theme.title(17)).foregroundStyle(Theme.ink)
                    Text(event.host != nil ? (event.title.isEmpty ? event.appName : "\(event.appName) · \(event.title)")
                                           : (event.title.isEmpty ? "App" : event.title))
                        .font(.system(size: 12)).foregroundStyle(Theme.soft).lineLimit(1)
                }
                Spacer()
                if cleared { Pill(text: "Approved since", tint: Theme.good, icon: "checkmark") }
                Pill(text: event.category == .distraction ? "Distraction" : "Off task", tint: tint)
            }

            HStack(spacing: 22) {
                figure("Started", Format.clock(event.startedAt), Theme.ink)
                figure("Away for", Format.duration(event.durationSeconds), Theme.text(for: tint))
                figure("Ended", Format.clock(event.endedAt), Theme.ink)
                Spacer()
            }

            if event.media.isEmpty {
                Text("No picture was captured for this switch.").font(.system(size: 12)).foregroundStyle(Theme.soft)
            } else {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(event.media, id: \.self) { ref in
                        VStack(alignment: .leading, spacing: 5) {
                            SectionLabel(text: ref.role == .start ? "First seconds" : "Last seconds")
                            MediaView(ref: ref, sprintId: event.sprintId, directory: directory, source: source,
                                      onOpen: { onOpen(ref) })
                        }
                    }
                }
            }
        }
        .card(padding: 16)
    }

    private func figure(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.soft)
            Text(value).font(Theme.number(20)).foregroundStyle(color)
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
    var onOpen: () -> Void = {}
    @State private var ready = false
    @State private var failed = false
    @State private var preview: NSImage?

    private var url: URL { directory.appendingPathComponent(ref.file) }

    var body: some View {
        Group {
            if ready, ref.kind == .video {
                // A still tile with a play mark: the clip itself plays in the viewer.
                RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.85))
                    .overlay(Image(systemName: "play.circle.fill").font(.system(size: 44)).foregroundStyle(.white.opacity(0.9)))
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onOpen)
                    .help("Click to play larger")
            } else if let preview {
                Image(nsImage: preview).resizable().aspectRatio(contentMode: .fit)
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                            .padding(6).background(.black.opacity(0.55), in: Circle()).padding(7)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onOpen)
                    .help("Click to view larger")
            } else {
                RoundedRectangle(cornerRadius: 12).fill(Theme.raised)
                    .overlay(Text(failed ? "Not available yet" : "Loading…").font(.system(size: 12)).foregroundStyle(Theme.soft))
            }
        }
        .frame(maxWidth: 380)
        // Pictures keep their own shape; clips and placeholders get a fixed box.
        .frame(height: preview != nil && ref.kind == .image ? nil : 220)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
        .task(id: url) { await load() }
    }

    private func load() async {
        preview = Thumbnails.cached(url)
        ready = FileManager.default.fileExists(atPath: url.path)
        failed = false
        if !ready { failed = true; return }
        if ref.kind == .image, preview == nil {
            preview = await Thumbnails.load(url)
            failed = preview == nil
        }
    }
}
