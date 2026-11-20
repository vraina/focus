import SwiftUI
import FocusSprintCore

/// What each app counts as. A kid sees their list read-only. An adult can change their own list here, and a
/// household admin or co-admin can also switch to the kids' list and change that. A change is handed to the
/// helper, which tells the service which Mac login asked; the service decides whether that login may.
struct AppsView: View {
    @State private var status = HelperStatus.load()
    @State private var lists = AppList.load()
    @State private var showKids = false
    /// Changes made here that the service has not confirmed yet: "kids|bundle" or "mine|bundle" -> label.
    @State private var pending: [String: String] = [:]
    @State private var pendingSince = Date()

    private struct Group: Identifiable {
        var id: String
        var title: String
        var detail: String
        var empty: String
        var tint: Color
    }
    /// Distractions first and always shown, then everything that is not one, split by whether a sprint ticks it.
    private let distractions = Group(
        id: "distraction", title: "Distractions",
        detail: "Time in these apps counts as distraction, all day and during a sprint.",
        empty: "No apps are marked as a distraction yet.", tint: Theme.bad)
    private let notDistractions = [
        Group(id: "work", title: "Work apps",
              detail: "Never a distraction. These are ticked automatically when a sprint is set up.",
              empty: "No apps are marked as work yet.", tint: Theme.good),
        Group(id: "neutral", title: "Other apps",
              detail: "Never a distraction. Utilities and everyday tools that are neither work nor play. They are not ticked for a sprint, so switching to one during a sprint shows as a switch away unless you tick it for that sprint.",
              empty: "No other apps yet.", tint: Theme.brand),
    ]
    private static let labels = [("distraction", "Distraction"), ("work", "Work app"), ("neutral", "Other app")]

    private var managesKids: Bool { lists.kids != nil }
    private var onKids: Bool { managesKids && showKids }
    private var editable: Bool { onKids || lists.canEdit == true }
    private var listKey: String { onKids ? "kids" : "mine" }
    private var entries: [AppEntry] {
        (onKids ? lists.kids ?? [] : lists.apps).map { entry in
            var entry = entry
            if let changed = pending["\(listKey)|\(entry.id)"] { entry.state = changed }
            return entry
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Apps").font(Theme.title(30))
                    Text("Which apps count as a distraction, and which do not. Nothing is ever blocked.")
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                }
                if managesKids {
                    HStack(spacing: 8) {
                        Chip(title: "My own apps", selected: !showKids) { showKids = false }
                        Chip(title: "The kids' apps", selected: showKids) { showKids = true }
                    }
                    .frame(maxWidth: 360)
                }
                if entries.isEmpty {
                    Notice(text: status?.linked == true
                           ? (onKids ? "No apps have been seen on the kids' logins yet. Each app gets a label the first time it is used."
                                     : "No apps have been labelled yet. Each app gets a label the first time you use it.")
                           : "Apps are labelled once this Mac is linked to a household. Until then only a short built-in list of apps counts as distraction.",
                           tint: Theme.warn, icon: "square.grid.2x2")
                }
                if !entries.isEmpty {
                    section(distractions)
                    Text("NOT DISTRACTIONS").font(.system(size: 11, weight: .bold)).kerning(0.8).foregroundStyle(.secondary)
                        .padding(.top, 6)
                    ForEach(notDistractions) { section($0) }
                }
                Text(footnote).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(28)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear(perform: reload)
        .onReceive(Ticker.every1) { _ in reload() }
    }

    private var footnote: String {
        let browsers = " Web browsers are not listed: time on each website is judged separately."
        if onKids { return "Changes here apply to every kid in the household, on all their computers, within a minute or two. The same list is on the website, under Apps." + browsers }
        if editable { return "Only you can see and change your own list. The same list is on the website, under Apps." + browsers }
        return "A label can be changed by a household admin, on the website or in their own app." + browsers
    }

    private func section(_ group: Group) -> some View {
        let list = entries.filter { $0.state == group.id }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(group.title).font(.system(size: 15, weight: .bold)).foregroundStyle(group.tint)
                Text("\(list.count)").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            }
            Text(group.detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if list.isEmpty {
                Text(group.empty).font(.system(size: 13)).foregroundStyle(.tertiary).padding(.vertical, 2)
            }
            ForEach(list) { app in row(app) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func row(_ app: AppEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if let icon = AppIcons.icon(bundleId: app.bundleId) {
                Image(nsImage: icon).resizable().frame(width: 24, height: 24)
            } else {
                Image(systemName: "app").font(.system(size: 18)).frame(width: 24, height: 24).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.system(size: 14, weight: .semibold))
                if let reason = app.reason, !reason.isEmpty {
                    Text(reason).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if editable {
                LabelMenu(state: app.state, name: app.name) { change(app, to: $0) }
            }
        }
    }

    private func change(_ app: AppEntry, to state: String) {
        guard state != app.state else { return }
        try? SiteRequest.appLabel(bundleId: app.bundleId, state: state, kidsList: onKids).drop()
        pending["\(listKey)|\(app.id)"] = state // shown at once; dropped when the service's answer arrives
        pendingSince = Date()
    }

    private func reload() {
        status = HelperStatus.load()
        lists = AppList.load()
        guard !pending.isEmpty else { return }
        // A change is settled once the lists from the service show it. One that is still not there after a
        // while was not accepted (or the Mac is offline): stop pretending and show what the service has.
        let expired = Date().timeIntervalSince(pendingSince) > 30
        for (key, state) in pending {
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            let source = parts[0] == "kids" ? lists.kids ?? [] : lists.apps
            if expired || source.first(where: { $0.id == parts[1] })?.state == state { pending[key] = nil }
        }
    }
}

/// The control that moves an app between groups: a coloured pill showing where it is now. Clicking it opens
/// a small panel with the three choices and what each one means.
private struct LabelMenu: View {
    var state: String
    var name: String
    var choose: (String) -> Void
    @State private var hovering = false
    @State private var open = false

    fileprivate struct Option: Identifiable {
        var id: String
        var title: String
        var detail: String
        var tint: Color
    }
    fileprivate static let options = [
        Option(id: "distraction", title: "Distraction", detail: "Counts as distraction, all day", tint: Theme.bad),
        Option(id: "work", title: "Work app", detail: "Not a distraction · ticked for sprints", tint: Theme.good),
        Option(id: "neutral", title: "Other app", detail: "Not a distraction · not ticked for sprints", tint: Theme.brand),
    ]

    var body: some View {
        let current = LabelMenu.options.first { $0.id == state } ?? LabelMenu.options[2]
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                Circle().fill(current.tint).frame(width: 7, height: 7)
                Text(current.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(current.tint)
                Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .bold)).foregroundStyle(current.tint.opacity(0.7))
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(current.tint.opacity(hovering || open ? 0.20 : 0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(current.tint.opacity(0.25)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityLabel("Group for \(name): \(current.title)")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(LabelMenu.options) { option in
                    LabelChoice(option: option, selected: option.id == state) {
                        open = false
                        choose(option.id)
                    }
                }
            }
            .padding(6)
            .frame(width: 290)
        }
    }
}

private struct LabelChoice: View {
    var option: LabelMenu.Option
    var selected: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Circle().fill(option.tint).frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.title).font(.system(size: 13, weight: .semibold))
                    Text(option.detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if selected { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(option.tint) }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? option.tint.opacity(0.12) : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
