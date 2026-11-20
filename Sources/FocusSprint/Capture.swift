import AppKit
import ScreenCaptureKit
import FocusSprintCore

actor ScreenCapturer {
    private var displays: [CGDirectDisplayID: SCDisplay] = [:]

    func capture(displayID: CGDirectDisplayID, maxWidth: Int = 1440) async -> CGImage? {
        do {
            if displays[displayID] == nil {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                displays = Dictionary(uniqueKeysWithValues: content.displays.map { ($0.displayID, $0) })
            }
            guard let display = displays[displayID] ?? displays[CGMainDisplayID()] ?? displays.values.first else { return nil }
            let config = SCStreamConfiguration()
            let scale = min(1.0, Double(maxWidth) / Double(display.width))
            config.width = Int(Double(display.width) * scale) & ~1
            config.height = Int(Double(display.height) * scale) & ~1
            config.showsCursor = true
            let filter = SCContentFilter(display: display, excludingWindows: [])
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            displays = [:] // display unplugged or permission missing: look again next time
            return nil
        }
    }
}

/// Captures frames for one visit away from the task. Keeps only the first few seconds and the
/// last few seconds, however long the visit lasts.
@MainActor
final class EventRecorder {
    static let videoFPS = 2
    let mode: CaptureMode
    private let capacity: Int
    private let interval: Double
    private(set) var head: [CGImage] = []
    private(set) var tail: [CGImage] = []
    private var stopped = false
    private var task: Task<Void, Never>?

    init(mode: CaptureMode, clipSeconds: Int) {
        self.mode = mode
        capacity = mode == .video ? clipSeconds * EventRecorder.videoFPS : 1
        interval = mode == .video ? 1.0 / Double(EventRecorder.videoFPS) : 1.0
    }

    func start(capturer: ScreenCapturer, display: @escaping @MainActor () -> CGDirectDisplayID) {
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !self.stopped else { return }
                if let image = await capturer.capture(displayID: display()), !self.stopped {
                    self.add(image)
                }
                try? await Task.sleep(nanoseconds: UInt64(self.interval * 1_000_000_000))
            }
        }
    }

    private func add(_ image: CGImage) {
        if head.count < capacity {
            head.append(image)
        } else {
            tail.append(image)
            if tail.count > capacity { tail.removeFirst() }
        }
    }

    /// Frames that arrive after this are dropped: they would show the screen the teen came back to.
    func stop() {
        stopped = true
        task?.cancel()
    }
}

/// Turns a finished visit into files and hands them to the vault helper.
enum EventPersister {
    struct Job: @unchecked Sendable {
        var event: DistractionEvent
        var head: [CGImage]
        var tail: [CGImage]
        var mode: CaptureMode
    }

    static func captions(for event: DistractionEvent) -> (start: String, end: String) {
        let away = "AWAY \(Format.duration(event.durationSeconds))"
        return ("START \(Format.clock(event.startedAt))  ·  \(away)  ·  \(event.label)",
                "END \(Format.clock(event.endedAt))  ·  \(away)  ·  \(event.label)")
    }

    static func persist(_ job: Job) async {
        var event = job.event
        let text = captions(for: event)
        for (role, frames, caption) in [(MediaRef.Role.start, job.head, text.start), (.end, job.tail, text.end)] {
            guard let first = frames.first else { continue }
            let size = CGSize(width: first.width, height: first.height)
            let base = "e\(event.seq)-\(role.rawValue)"
            if job.mode == .video, frames.count >= 2 {
                let captioned = frames.map { MediaWriter.caption($0, text: caption, canvas: size) }
                if let data = try? await MediaWriter.mp4(frames: captioned, fps: EventRecorder.videoFPS),
                   (try? Inbox.drop(sprintId: event.sprintId, file: base + ".mp4", data: data)) != nil {
                    event.media.append(MediaRef(role: role, kind: .video, file: base + ".mp4"))
                    continue
                }
            }
            // Screenshot mode, a visit too short for a clip, or a failed encode: keep a still.
            let still = role == .start ? first : frames[frames.count - 1]
            if let data = MediaWriter.jpeg(MediaWriter.caption(still, text: caption)),
               (try? Inbox.drop(sprintId: event.sprintId, file: base + ".jpg", data: data)) != nil {
                event.media.append(MediaRef(role: role, kind: .image, file: base + ".jpg"))
            }
        }
        writeRecord(event)
    }

    /// Used when the app is quitting and there is no time to encode video.
    static func persistStills(_ job: Job) {
        var event = job.event
        let text = captions(for: event)
        for (role, image, caption) in [(MediaRef.Role.start, job.head.first, text.start), (.end, job.tail.last, text.end)] {
            guard let image, let data = MediaWriter.jpeg(MediaWriter.caption(image, text: caption)) else { continue }
            let file = "e\(event.seq)-\(role.rawValue).jpg"
            if (try? Inbox.drop(sprintId: event.sprintId, file: file, data: data)) != nil {
                event.media.append(MediaRef(role: role, kind: .image, file: file))
            }
        }
        writeRecord(event)
    }

    private static func writeRecord(_ event: DistractionEvent) {
        do {
            try Inbox.drop(sprintId: event.sprintId, file: "e\(event.seq).json", data: JSONCoding.encoder.encode(event))
        } catch {
            NSLog("FocusSprint: could not store event \(event.id): \(error)")
        }
    }
}
