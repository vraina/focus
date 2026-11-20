import AppKit
import AVKit
import SwiftUI
import FocusSprintCore

/// One picture or clip, with everything needed to label it.
struct ViewerItem: Identifiable, Equatable {
    var id: String { event.id + "/" + ref.file }
    var event: DistractionEvent
    var ref: MediaRef
    var directory: URL
    var source: HistorySource
    var url: URL { directory.appendingPathComponent(ref.file) }

    static func == (a: ViewerItem, b: ViewerItem) -> Bool { a.id == b.id }
}

/// The in-app viewer's state: which set of pictures is open and which one is showing.
@MainActor
final class MediaViewer: ObservableObject {
    static let shared = MediaViewer()
    @Published private(set) var items: [ViewerItem] = []
    @Published private(set) var index = 0

    var current: ViewerItem? { items.indices.contains(index) ? items[index] : nil }
    var isOpen: Bool { !items.isEmpty }
    var hasPrevious: Bool { index > 0 }
    var hasNext: Bool { index < items.count - 1 }

    func open(_ items: [ViewerItem], at id: String) {
        self.items = items
        index = items.firstIndex { $0.id == id } ?? 0
    }
    func close() { items = [] }
    func next() { if hasNext { index += 1 } }
    func previous() { if hasPrevious { index -= 1 } }
}

/// Fills the app window: the picture large, its details labelled, and previous / next.
struct MediaViewerOverlay: View {
    @ObservedObject var viewer: MediaViewer
    @State private var image: NSImage?
    @State private var player: AVPlayer?
    @State private var failed = false

    var body: some View {
        if let item = viewer.current {
            ZStack {
                Color.black.opacity(0.92).ignoresSafeArea().onTapGesture { viewer.close() }
                VStack(spacing: 14) {
                    header(item)
                    HStack(spacing: 14) {
                        arrow("chevron.left", enabled: viewer.hasPrevious, help: "Previous (left arrow)") { viewer.previous() }
                        media(item).frame(maxWidth: .infinity, maxHeight: .infinity)
                        arrow("chevron.right", enabled: viewer.hasNext, help: "Next (right arrow)") { viewer.next() }
                    }
                    details(item)
                }
                .padding(20)
                keyboard
            }
            .task(id: item.id) { await load(item) }
            .transition(.opacity)
        }
    }

    private func header(_ item: ViewerItem) -> some View {
        let tint = item.event.category == .distraction ? Theme.bad : Theme.warn
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(item.event.host ?? item.event.appName).font(Theme.title(20)).foregroundStyle(.white)
                    Text(item.event.category == .distraction ? "Distraction" : "Off task")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 9).padding(.vertical, 4).background(tint, in: Capsule())
                    Text(item.ref.role == .start ? "First seconds" : "Last seconds")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 9).padding(.vertical, 4).background(.white.opacity(0.18), in: Capsule())
                }
                Text(item.event.host != nil && !item.event.title.isEmpty ? "\(item.event.appName) · \(item.event.title)" : item.event.appName)
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            }
            Spacer()
            Text("\(viewer.index + 1) of \(viewer.items.count)").font(Theme.number(14)).foregroundStyle(.white.opacity(0.8))
            Button { NSWorkspace.shared.open(item.url) } label: {
                Image(systemName: "arrow.up.forward.app").font(.system(size: 15, weight: .semibold))
            }
            .buttonStyle(ViewerIconButton()).help("Open the file in its own app")
            Button { viewer.close() } label: { Image(systemName: "xmark").font(.system(size: 15, weight: .bold)) }
                .buttonStyle(ViewerIconButton()).help("Close (Esc)")
        }
    }

    @ViewBuilder
    private func media(_ item: ViewerItem) -> some View {
        if item.ref.kind == .video, let player {
            VideoPlayer(player: player).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else if let image {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.5), radius: 20)
        } else {
            Text(failed ? "This picture is not available." : "Loading…").font(.system(size: 14)).foregroundStyle(.white.opacity(0.7))
        }
    }

    /// Date, start, time away and end, spelled out under the picture.
    private func details(_ item: ViewerItem) -> some View {
        let tint = item.event.category == .distraction ? Theme.bad : Theme.warn
        return HStack(spacing: 0) {
            field("Date", item.event.startedAt.formatted(date: .complete, time: .omitted), .white)
            divider
            field("Started", Format.clock(item.event.startedAt), .white)
            divider
            field("Away for", Format.duration(item.event.durationSeconds), tint)
            divider
            field("Ended", Format.clock(item.event.endedAt), .white)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var divider: some View { Rectangle().fill(.white.opacity(0.18)).frame(width: 1, height: 32).padding(.horizontal, 18) }

    private func field(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(.system(size: 10, weight: .semibold)).kerning(0.6).foregroundStyle(.white.opacity(0.6))
            Text(value).font(Theme.number(18)).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.7)
        }
    }

    private func arrow(_ symbol: String, enabled: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 18, weight: .bold)) }
            .buttonStyle(ViewerIconButton(size: 44))
            .opacity(enabled ? 1 : 0.25)
            .disabled(!enabled)
            .help(help)
    }

    /// Invisible buttons that give the viewer its keyboard shortcuts.
    private var keyboard: some View {
        Group {
            Button("") { viewer.previous() }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { viewer.next() }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("") { viewer.close() }.keyboardShortcut(.cancelAction)
        }
        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }

    private func load(_ item: ViewerItem) async {
        image = Thumbnails.cached(item.url) // show the preview at once, then sharpen
        player = nil
        failed = false
        guard FileManager.default.fileExists(atPath: item.url.path) else { failed = true; return }
        if item.ref.kind == .video {
            let made = AVPlayer(url: item.url)
            player = made
            made.play()
            return
        }
        let url = item.url
        let full = await Task.detached(priority: .userInitiated) { NSImage(contentsOf: url) }.value
        guard viewer.current?.id == item.id else { return } // moved on while this was loading
        if let full { image = full } else if image == nil { failed = true }
    }
}

struct ViewerIconButton: ButtonStyle {
    var size: CGFloat = 34
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(.white.opacity(configuration.isPressed ? 0.30 : 0.16), in: Circle())
            .contentShape(Circle())
    }
}
