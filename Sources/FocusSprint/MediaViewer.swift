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
                Theme.viewerCanvas.ignoresSafeArea().onTapGesture { viewer.close() }
                VStack(spacing: 12) {
                    header(item)
                    HStack(spacing: 12) {
                        arrow("chevron.left", enabled: viewer.hasPrevious, help: "Previous (left arrow)") { viewer.previous() }
                        media(item).frame(maxWidth: .infinity, maxHeight: .infinity)
                        arrow("chevron.right", enabled: viewer.hasNext, help: "Next (right arrow)") { viewer.next() }
                    }
                    details(item)
                }
                .padding(EdgeInsets(top: 46, leading: 16, bottom: 16, trailing: 16))
                keyboard
            }
            .task(id: item.id) { await load(item) }
            .transition(.opacity)
        }
    }

    private func header(_ item: ViewerItem) -> some View {
        HStack(spacing: 10) {
            Text(item.event.host ?? item.event.appName).font(Theme.title(20)).foregroundStyle(.white).lineLimit(1)
            tag(item.event.category == .distraction ? "Distraction" : "Off task")
            tag(item.ref.role == .start ? "First seconds" : "Last seconds")
            Text(item.event.host != nil && !item.event.title.isEmpty ? "\(item.event.appName) · \(item.event.title)" : item.event.appName)
                .font(.system(size: 13)).foregroundStyle(Theme.viewerSoft).lineLimit(1)
            Spacer(minLength: 8)
            Text("\(viewer.index + 1) of \(viewer.items.count)").font(Theme.number(14)).foregroundStyle(Theme.viewerSoft)
                .fixedSize()
            Button("Open the file in its own app") { NSWorkspace.shared.open(item.url) }
                .buttonStyle(ViewerTextButton())
            Button { viewer.close() } label: { Image(systemName: "xmark").font(.system(size: 14, weight: .bold)) }
                .buttonStyle(ViewerIconButton(size: 44)).help("Close (Esc)").accessibilityLabel("Close")
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text).font(.system(size: 11.5, weight: .bold)).foregroundStyle(.white).fixedSize()
            .padding(.horizontal, 10).padding(.vertical, 3).background(Theme.viewerControl, in: PillShape())
    }

    @ViewBuilder
    private func media(_ item: ViewerItem) -> some View {
        if item.ref.kind == .video, let player {
            VideoPlayer(player: player).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else if let image {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.viewerPanel)
                .overlay(Text(failed ? "This picture is not available." : "Loading…").font(.system(size: 14)).foregroundStyle(Theme.viewerSoft))
        }
    }

    /// Date, start, time away and end, spelled out under the picture.
    private func details(_ item: ViewerItem) -> some View {
        HStack(spacing: 32) {
            field("Date", item.event.startedAt.formatted(date: .complete, time: .omitted), .white)
            field("Started", Format.clock(item.event.startedAt), .white)
            field("Away for", Format.duration(item.event.durationSeconds), Theme.viewerAway)
            field("Ended", Format.clock(item.event.endedAt), .white)
            Spacer(minLength: 0)
            Text("Left and right arrow keys move between pictures · Esc closes")
                .font(.system(size: 12)).foregroundStyle(Theme.viewerSoft).lineLimit(2).multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(Theme.viewerPanel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func field(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.viewerSoft)
            Text(value).font(Theme.number(18)).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.7)
        }
    }

    private func arrow(_ symbol: String, enabled: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 15, weight: .bold)) }
            .buttonStyle(ViewerIconButton(size: 44))
            .disabled(!enabled)
            .help(help)
            .accessibilityLabel(symbol == "chevron.left" ? "Previous" : "Next")
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
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(enabled ? Color.white : Color(white: 0.5))
            .frame(width: size, height: size)
            .background(enabled ? Theme.viewerControl : Theme.viewerPanel, in: Circle())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Circle())
    }
}

struct ViewerTextButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1).fixedSize()
            .padding(.horizontal, 14).frame(height: 40)
            .background(Theme.viewerControl, in: PillShape())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(PillShape())
    }
}
