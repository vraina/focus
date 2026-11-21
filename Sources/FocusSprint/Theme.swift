import AppKit
import SwiftUI

/// One place for the app's look: colours, type and the handful of shared building blocks.
enum Theme {
    // Each colour is given as dark, then light, and follows the Mac's appearance.
    static let canvas = dyn(0x0b0c10, 0xf6f7f9)      // window
    static let surface = dyn(0x14161d, 0xffffff)     // card
    static let raised = dyn(0x1b1e27, 0xeceef2)
    static let hairline = dyn(0x262a36, 0xe2e4ea)
    static let outline = dyn(0x343947, 0xc9ccd5)     // edges of fields and outlined buttons
    static let ink = dyn(0xf2f3f7, 0x16171b)         // text
    static let soft = dyn(0xa2a7b5, 0x5f636e)        // muted text
    static let brand = dyn(0x7c75ff, 0x5e57f0)       // accent
    static let onBrand = dyn(0x0b0c10, 0xffffff)     // text on accent
    static let brandText = dyn(0xa5a0ff, 0x4a43d6)
    static let brandTint = dyn(0x1f2030, 0xecebfd)
    static let ticked = dyn(0x2f2b6b, 0xdcd9fc)      // a ticked app
    static let onTicked = dyn(0xd6d3ff, 0x352fb0)
    static let good = dyn(0x3ddc97, 0x2aa876)        // on task
    static let goodText = dyn(0x3ddc97, 0x157a4f)
    static let goodTint = dyn(0x123326, 0xe3f4ec)
    static let warn = dyn(0xffb547, 0xf08a00)        // off task
    static let warnText = dyn(0xffb547, 0xc2410c)
    static let warnTint = dyn(0x3a2c10, 0xfdeedc)
    static let bad = dyn(0xff6b6b, 0xcf3740)         // distraction
    static let badText = dyn(0xff8585, 0xb3262e)
    static let badTint = dyn(0x3d1c1f, 0xfbe6e7)
    static let badFill = dyn(0xd9434a, 0xcf3740)     // solid red behind white text
    static let track = dyn(0x262a36, 0xe2e4ea)       // the unused part of a circle or bar

    /// Only the app icon still uses this.
    static let gradient = LinearGradient(colors: [Color(red: 0.37, green: 0.34, blue: 0.94), Color(red: 0.16, green: 0.68, blue: 0.86)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)

    static func title(_ size: CGFloat) -> Font { .system(size: size, weight: .bold) }
    static func number(_ size: CGFloat) -> Font { .system(size: size, weight: .bold).monospacedDigit() }

    /// Readable text in a tint's colour, and the pale fill that goes behind it.
    static func text(for tint: Color) -> Color {
        tint == good ? goodText : tint == warn ? warnText : tint == bad ? badText : tint == brand ? brandText : tint
    }
    static func fill(for tint: Color) -> Color {
        tint == good ? goodTint : tint == warn ? warnTint : tint == bad ? badTint : tint == brand ? brandTint : tint.opacity(0.14)
    }

    private static func dyn(_ dark: Int, _ light: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                           blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        })
    }
}

/// Green while distraction is negligible, amber when it is noticeable, red beyond that.
func levelColor(_ fraction: Double) -> Color {
    if fraction < 0.05 { return Theme.good }
    if fraction < 0.15 { return Theme.warn }
    return Theme.bad
}

extension View {
    /// The standard raised panel.
    func card(padding: CGFloat = 16, radius: CGFloat = 18) -> some View {
        self.padding(padding)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.hairline))
    }

    /// The box around something typed into: card colour, with an accent edge while it has the keyboard.
    func field(focused: Bool, radius: CGFloat = 12) -> some View {
        self.background(Theme.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(focused ? Theme.brand : Theme.outline, lineWidth: 1.5))
    }
}

struct SectionLabel: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.soft)
    }
}

struct Pill: View {
    var text: String
    var tint: Color
    var icon: String?

    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.system(size: 10, weight: .bold)) }
            Text(text).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(Theme.text(for: tint))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Theme.fill(for: tint), in: Capsule(style: .continuous))
    }
}

/// A circular progress ring. `tint == nil` uses the accent colour.
struct Ring: View {
    var progress: Double
    var lineWidth: CGFloat
    var tint: Color?

    var body: some View {
        ZStack {
            Circle().stroke(Theme.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0, min(1, progress)))
                .stroke(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(Theme.brand),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .opacity(progress > 0 ? 1 : 0) // no stray dot on an empty ring
        }
    }
}

struct StatTile: View {
    var title: String
    var value: String
    var color: Color = .primary
    var icon: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: 11, weight: .semibold)) }
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(.secondary)
            Text(value).font(Theme.number(26)).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .card(padding: 14)
    }
}

/// A selectable pill.
struct Chip: View {
    var title: String
    var selected: Bool
    var icon: NSImage?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(nsImage: icon).resizable().frame(width: 18, height: 18) }
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if selected, icon != nil { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)) }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .foregroundStyle(selected ? Theme.onBrand : Theme.ink)
            .background(selected ? Theme.brand : Theme.raised, in: Capsule(style: .continuous))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// One control for picking one of a few choices: a pill-shaped track with the chosen part filled.
struct Segments<Value: Hashable>: View {
    var label: String
    var options: [(value: Value, title: String)]
    @Binding var selection: Value
    var height: CGFloat = 36

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let on = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.title).font(.system(size: 14, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                        .padding(.horizontal, 6)
                        .frame(maxWidth: .infinity).frame(height: height)
                        .foregroundStyle(on ? Theme.onBrand : Theme.soft)
                        .background(on ? Theme.brand : Color.clear, in: Capsule(style: .continuous))
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: height / 2 + 4))
        .overlay(RoundedRectangle(cornerRadius: height / 2 + 4).strokeBorder(Theme.hairline))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// The main call to action: a solid accent pill. `wide` stretches it across the space it is given.
struct PrimaryButtonStyle: ButtonStyle {
    var wide = true
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .bold))
            .lineLimit(1)
            .foregroundStyle(enabled ? Theme.onBrand : Theme.soft)
            .padding(.horizontal, 30)
            .frame(maxWidth: wide ? .infinity : nil)
            .frame(height: 50)
            .background(enabled ? Theme.brand : Theme.track, in: Capsule(style: .continuous))
            .contentShape(Capsule(style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// A quieter button: an outlined pill.
struct OutlineButtonStyle: ButtonStyle {
    var tint: Color = Theme.ink
    var height: CGFloat = 40

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .bold))
            .lineLimit(1)
            .foregroundStyle(tint)
            .padding(.horizontal, 20)
            .frame(height: height)
            .overlay(RoundedRectangle(cornerRadius: height / 2).strokeBorder(Theme.outline, lineWidth: 1.5))
            .contentShape(Capsule(style: .continuous))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Lays children out left to right, wrapping to a new row when one does not fit. With `fillLast`, the last
/// child takes whatever is left of its row (or a whole new row when less than `lastMinimum` is left).
struct Flow: Layout {
    var spacing: CGFloat = 6
    var fillLast = false
    var lastMinimum: CGFloat = 200

    private func frames(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for (index, view) in subviews.enumerated() {
            var size = view.sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            let isFiller = fillLast && index == subviews.count - 1
            let needed = isFiller ? min(lastMinimum, width) : size.width
            if x > 0, x + needed > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            if isFiller { size.width = width - x }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return frames
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 480
        return CGSize(width: width, height: frames(subviews, width: width).map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, frame) in zip(subviews, frames(subviews, width: bounds.width)) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                       proposal: ProposedViewSize(frame.size))
        }
    }
}

struct Notice: View {
    var text: String
    var tint: Color
    var icon = "exclamationmark.triangle.fill"

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon).foregroundStyle(Theme.text(for: tint))
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(Theme.fill(for: tint), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(bundleId: String) -> NSImage? {
        if let hit = cache[bundleId] { return hit }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleId] = image
        return image
    }
}
