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
    @State private var selection: String?
    @State private var message: String?
    @State private var syncing = false
    private let refreshTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                Picker("", selection: $source) {
                    ForEach(HistorySource.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().padding(10)
                if let message { Text(message).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10) }
                List(selection: $selection) {
                    ForEach(records) { record in
                        SprintRow(record: record).tag(record.id)
                    }
                }
            }
            .frame(minWidth: 250, idealWidth: 280, maxWidth: 340)

            Group {
                if let record = records.first(where: { $0.id == selection }) {
                    SprintDetail(record: record, source: source, sites: sites)
                } else {
                    Text(records.isEmpty ? "No sprints yet" : "Select a sprint").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 520)
        }
        .onAppear(perform: reload)
        .onChange(of: source) { _, _ in reload() }
        .onChange(of: engine.phase) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: reload)
        }
        .onReceive(refreshTimer) { _ in if source == .local { reload() } }
    }

    private func reload() {
        switch source {
        case .local:
            message = nil
            show(SprintReader.listForDisplay(in: Paths.vault.appendingPathComponent("sprints")))
        case .cloud:
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
        records = list
        if selection == nil || !list.contains(where: { $0.id == selection }) { selection = list.first?.id }
    }
}

struct SprintRow: View {
    var record: SprintRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(record.start.task, systemImage: record.isAmbient ? "sun.max" : "timer").font(.headline).lineLimit(1)
            Text(record.isAmbient ? record.start.startedAt.formatted(date: .complete, time: .omitted)
                                  : record.start.startedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(record.isAmbient ? "\(100 - record.focusPercent)% distracted" : "\(record.focusPercent)% focused").bold()
                    .foregroundStyle(levelColor(1 - Double(record.focusPercent) / 100))
                Text("· \(record.events.count) \(record.isAmbient ? "visits" : "switches")").foregroundStyle(.secondary)
                if record.interrupted { Text("· interrupted").foregroundStyle(.red) }
            }
            .font(.caption)
        }
        .padding(.vertical, 3)
    }
}

struct SprintDetail: View {
    var record: SprintRecord
    var source: HistorySource
    var sites = SiteBook()

    /// Visits to sites that have since been approved (by the reviewer or a parent) or relabelled productive.
    private var underReview: [DistractionEvent] {
        record.events.filter { $0.host.map(sites.isCleared) == true }
    }

    private var statusText: String {
        if let end = record.end { return end.status == .completed ? "Completed" : "Ended early" }
        return record.interrupted ? "Interrupted — the app was quit mid-sprint" : "In progress"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.start.task).font(.title.bold())
                    if record.isAmbient {
                        Text("\(record.start.startedAt.formatted(date: .complete, time: .omitted)) · visits to known distractions while no sprint was running")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("\(record.start.startedAt.formatted(date: .complete, time: .shortened)) · \(record.start.plannedSeconds / 60) min planned · \(statusText)")
                            .foregroundStyle(record.interrupted ? .red : .secondary)
                    }
                    Text("\(record.start.user) on \(record.start.device)").font(.caption).foregroundStyle(.secondary)
                }
                if record.isAmbient {
                    HStack(spacing: 12) {
                        StatTile(title: "Distracted", value: "\(100 - record.focusPercent)%", color: levelColor(1 - Double(record.focusPercent) / 100))
                        StatTile(title: "Visits", value: "\(record.events.count)")
                        StatTile(title: "Time on distractions", value: Format.duration(record.awaySeconds))
                        StatTile(title: "Mac in use", value: Format.duration(record.elapsedSeconds))
                    }
                } else {
                    HStack(spacing: 12) {
                        StatTile(title: "Focused", value: "\(record.focusPercent)%", color: levelColor(1 - Double(record.focusPercent) / 100))
                        StatTile(title: "Switches away", value: "\(record.events.count)")
                        StatTile(title: "Time away", value: Format.duration(record.awaySeconds))
                        StatTile(title: "Longest focus", value: Format.duration(record.longestFocusSeconds))
                    }
                    TimelineBar(record: record)
                }
                if !underReview.isEmpty {
                    let away = max(0, record.awaySeconds - underReview.reduce(0) { $0 + $1.durationSeconds })
                    let percent = Int((away / record.elapsedSeconds * 100).rounded())
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Leaving out \(underReview.count) visit\(underReview.count == 1 ? "" : "s") to sites approved since",
                              systemImage: "checkmark.circle")
                            .font(.headline)
                        Text("\(percent)% distracted · \(Format.duration(away)) away · \(record.events.count - underReview.count) switches")
                            .font(.title3.bold()).monospacedDigit()
                        Text("The numbers above count every visit as it was recorded. These leave out sites that a \"needed for work\" request or a parent has approved since.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
                if record.events.isEmpty {
                    Label(record.isAmbient ? "No visits to known distractions." : "No switches away during this sprint.",
                          systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                } else {
                    Text(record.isAmbient ? "Every visit" : "Every switch away").font(.title3.bold())
                    ForEach(record.events) { event in
                        // A combined day spans several stored sessions, so each event's files are looked up by its own session.
                        EventCard(event: event,
                                  directory: record.directory.deletingLastPathComponent().appendingPathComponent(event.sprintId),
                                  source: source, cleared: event.host.map(sites.isCleared) == true)
                    }
                }
            }
            .padding(20)
        }
    }
}

/// The whole sprint as one bar: green is on task, red and orange are the visits away.
struct TimelineBar: View {
    var record: SprintRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.green.opacity(0.55))
                    ForEach(record.events) { event in
                        let x = event.startedAt.timeIntervalSince(record.start.startedAt) / record.elapsedSeconds
                        let w = event.durationSeconds / record.elapsedSeconds
                        Rectangle()
                            .fill(event.category == .distraction ? Color.red : Color.orange)
                            .frame(width: max(2, geo.size.width * w))
                            .offset(x: geo.size.width * min(1, max(0, x)))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .frame(height: 18)
            HStack {
                Text(Format.clock(record.start.startedAt))
                Spacer()
                Text(Format.clock(record.start.startedAt.addingTimeInterval(record.elapsedSeconds)))
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct EventCard: View {
    var event: DistractionEvent
    var directory: URL
    var source: HistorySource
    var cleared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("STARTED").font(.caption2).foregroundStyle(.secondary)
                    Text(Format.clock(event.startedAt)).font(.system(size: 22, weight: .heavy)).monospacedDigit()
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("AWAY FOR").font(.caption2).foregroundStyle(.secondary)
                    Text(Format.duration(event.durationSeconds)).font(.system(size: 22, weight: .heavy)).monospacedDigit()
                        .foregroundStyle(event.category == .distraction ? .red : .orange)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("ENDED").font(.caption2).foregroundStyle(.secondary)
                    Text(Format.clock(event.endedAt)).font(.system(size: 22, weight: .heavy)).monospacedDigit()
                }
                Spacer()
                if cleared {
                    Text("Approved since")
                        .font(.caption.bold())
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.green.opacity(0.18), in: Capsule())
                }
                Text(event.category == .distraction ? "Distraction" : "Off task")
                    .font(.caption.bold())
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background((event.category == .distraction ? Color.red : Color.orange).opacity(0.18), in: Capsule())
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(event.host.map { "\($0) — \(event.appName)" } ?? event.appName).font(.headline)
                if !event.title.isEmpty { Text(event.title).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            if event.media.isEmpty {
                Text("No picture was captured for this switch.").font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(event.media, id: \.self) { ref in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(ref.role == .start ? "First seconds" : "Last seconds").font(.caption.bold())
                            MediaView(ref: ref, sprintId: event.sprintId, directory: directory, source: source)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct MediaView: View {
    var ref: MediaRef
    var sprintId: String
    var directory: URL
    var source: HistorySource
    @State private var ready = false
    @State private var failed = false

    private var url: URL { directory.appendingPathComponent(ref.file) }

    var body: some View {
        Group {
            if ready {
                if ref.kind == .video {
                    VideoPlayer(player: AVPlayer(url: url))
                } else if let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                        .onTapGesture { NSWorkspace.shared.open(url) }
                        .help("Click to open full size")
                }
            } else {
                RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08))
                    .overlay(Text(failed ? "Not available yet" : "Loading…").font(.caption).foregroundStyle(.secondary))
            }
        }
        .frame(maxWidth: 380)
        .frame(height: 230)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: url) { await load() }
    }

    private func load() async {
        ready = FileManager.default.fileExists(atPath: url.path)
        failed = false
        guard !ready else { return }
        guard source == .cloud, let store = CloudCache.store else { failed = true; return }
        if let data = try? await store.media(sprintId: sprintId, file: ref.file), (try? data.write(to: url, options: .atomic)) != nil {
            ready = true
        } else {
            failed = true
        }
    }
}
