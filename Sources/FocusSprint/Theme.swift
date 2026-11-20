import AppKit
import SwiftUI

/// One place for the app's look: colours, type and the handful of shared building blocks.
enum Theme {
    static let brand = Color(red: 0.37, green: 0.34, blue: 0.94)
    static let brandAlt = Color(red: 0.16, green: 0.68, blue: 0.86)
    static let good = Color(red: 0.13, green: 0.68, blue: 0.44)
    static let warn = Color(red: 0.94, green: 0.60, blue: 0.13)
    static let bad = Color(red: 0.90, green: 0.28, blue: 0.30)

    static let gradient = LinearGradient(colors: [brand, brandAlt], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let hairline = Color.primary.opacity(0.08)

    static func title(_ size: CGFloat) -> Font { .system(size: size, weight: .bold, design: .rounded) }
    static func number(_ size: CGFloat) -> Font { .system(size: size, weight: .bold, design: .rounded).monospacedDigit() }
}

/// Green while distraction is negligible, amber when it is noticeable, red beyond that.
func levelColor(_ fraction: Double) -> Color {
    if fraction < 0.05 { return Theme.good }
    if fraction < 0.15 { return Theme.warn }
    return Theme.bad
}

extension View {
    /// The standard raised panel.
    func card(padding: CGFloat = 16, radius: CGFloat = 14) -> some View {
        self.padding(padding)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.hairline))
            .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
    }
}

struct SectionLabel: View {
    var text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .kerning(0.6)
            .foregroundStyle(.secondary)
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
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(tint.opacity(0.14), in: Capsule())
    }
}

/// A circular progress ring. `tint == nil` uses the brand gradient.
struct Ring: View {
    var progress: Double
    var lineWidth: CGFloat
    var tint: Color?

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0, min(1, progress)))
                .stroke(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(Theme.gradient),
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

/// A selectable capsule, used for sprint lengths and the list of apps.
struct Chip: View {
    var title: String
    var selected: Bool
    var icon: NSImage?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(nsImage: icon).resizable().frame(width: 18, height: 18) }
                Text(title).font(.system(size: 13, weight: selected ? .semibold : .regular)).lineLimit(1)
                if selected, icon != nil { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)) }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(selected ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Color.primary.opacity(0.06)),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The main call to action.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(enabled ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.primary.opacity(0.18)),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
    }
}

struct Notice: View {
    var text: String
    var tint: Color
    var icon = "exclamationmark.triangle.fill"

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(0.25)))
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
