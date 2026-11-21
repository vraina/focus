import SwiftUI
import FocusSprintCore

/// What each app counts as. A kid sees their list read-only. An adult can change their own list here, and a
/// household admin or co-admin can also switch to the kids' list and change that. A change is handed to the
/// helper, which tells the service which Mac login asked; the service decides whether that login may.
struct AppsView: View {
    /// Development snapshots only: made-up lists to draw instead of the ones on disk.
    var sample: AppList?
    @State private var status = HelperStatus.load()
    @State private var lists = AppList.load()
    @State private var listsData: Data?
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

    private var shown: AppList { sample ?? lists }
    private var managesKids: Bool { shown.kids != nil }
    private var onKids: Bool { managesKids && showKids }
    private var editable: Bool { onKids || shown.canEdit == true }
    private var listKey: String { onKids ? "kids" : "mine" }
    private var entries: [AppEntry] {
        (onKids ? shown.kids ?? [] : shown.apps).map { entry in
            var entry = entry
            if let changed = pending["\(listKey)|\(entry.id)"] { entry.state = changed }
            return entry
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Apps").font(Theme.title(34)).kerning(-0.8).foregroundStyle(Theme.ink)
                    Text("Which apps count as a distraction, and which do not. Nothing is ever blocked.")
                        .font(.system(size: 14)).foregroundStyle(Theme.soft)
                }
                if managesKids {
                    Segments(label: "Whose list", options: [(value: false, title: "My own apps"), (value: true, title: "The kids' apps")],
                             selection: $showKids, height: 34)
                        .frame(maxWidth: 320)
                }
                if entries.isEmpty {
                    Notice(text: status?.linked == true || sample != nil
                           ? (onKids ? "No apps have been seen on the kids' logins yet. Each app gets a label the first time it is used."
                                     : "No apps have been labelled yet. Each app gets a label the first time you use it.")
                           : "Apps are labelled once this Mac is linked to a household. Until then only a short built-in list of apps counts as distraction.",
                           tint: Theme.warn, icon: "square.grid.2x2")
                }
                if !entries.isEmpty {
                    section(distractions)
                    Text("Not distractions").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.soft)
                        .padding(.top, 4)
                    ForEach(notDistractions) { section($0) }
                }
                Text(footnote).font(.system(size: 12)).foregroundStyle(Theme.soft)
            }
            .padding(EdgeInsets(top: 44, leading: 30, bottom: 24, trailing: 30))
            .frame(maxWidth: 860, alignment: .leading)
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
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(group.title).font(Theme.title(17)).foregroundStyle(Theme.text(for: group.tint))
                Text("\(list.count)").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.soft)
            }
            Text(group.detail).font(.system(size: 12)).foregroundStyle(Theme.soft).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2).padding(.bottom, 8)
            if list.isEmpty {
                Text(group.empty).font(.system(size: 13)).foregroundStyle(Theme.soft).padding(.bottom, 8)
            }
            ForEach(list) { app in
                Rectangle().fill(Theme.hairline).frame(height: 1)
                row(app).padding(.vertical, 9)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 16, leading: 18, bottom: 6, trailing: 18))
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.hairline))
    }

    private func row(_ app: AppEntry) -> some View {
        HStack(alignment: .center, spacing: 12) {
            if let icon = AppIcons.icon(bundleId: app.bundleId) {
                Image(nsImage: icon).resizable().frame(width: 30, height: 30)
            } else {
                Image(systemName: "app").font(.system(size: 20)).frame(width: 30, height: 30).foregroundStyle(Theme.soft)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                if let reason = app.reason, !reason.isEmpty {
                    Text(reason).font(.system(size: 12)).foregroundStyle(Theme.soft).fixedSize(horizontal: false, vertical: true)
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
        // Assigning redraws the whole list, so only do it when what is on disk has changed.
        let linked = HelperStatus.load()
        if linked?.linked != status?.linked { status = linked }
        let fresh = AppList.load()
        if (try? JSONEncoder().encode(fresh)) != listsData {
            listsData = try? JSONEncoder().encode(fresh)
            lists = fresh
        }
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
            HStack(spacing: 7) {
                Text(current.title).font(.system(size: 12.5, weight: .bold))
                Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .bold))
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
            .foregroundStyle(Theme.text(for: current.tint))
            .padding(.horizontal, 12).frame(height: 32)
            .background(Theme.fill(for: current.tint), in: PillShape())
            .overlay(PillShape().strokeBorder(Theme.text(for: current.tint), lineWidth: 1.5))
            .opacity(hovering || open ? 0.85 : 1)
            .contentShape(PillShape())
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
            .frame(width: 300)
            .background(Theme.surface)
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
                    Text(option.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text(option.detail).font(.system(size: 11.5)).foregroundStyle(Theme.soft)
                }
                Spacer(minLength: 8)
                if selected { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.text(for: option.tint)) }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovering || selected ? Theme.raised : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
