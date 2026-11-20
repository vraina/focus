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
        var tint: Color
    }
    private let groups = [
        Group(id: "distraction", title: "Distraction", detail: "Counts towards distraction all day, and during a sprint.", tint: Theme.bad),
        Group(id: "work", title: "Work", detail: "Ticked by default when a sprint is set up.", tint: Theme.good),
        Group(id: "neutral", title: "Doesn't count", detail: "Ignored all day. During a sprint it counts as away unless it is ticked.", tint: .secondary),
    ]
    private static let labels = [("work", "Work"), ("distraction", "Distraction"), ("neutral", "Doesn't count")]

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
                    Text("How time in each app counts. Nothing is ever blocked.")
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
                ForEach(groups) { group in
                    let list = entries.filter { $0.state == group.id }
                    if !list.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(group.title).font(.system(size: 15, weight: .bold)).foregroundStyle(group.tint)
                                Text("\(list.count)").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                            }
                            Text(group.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                            ForEach(list) { app in row(app) }
                        }
                        .card()
                    }
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
                Picker("", selection: Binding(get: { app.state }, set: { change(app, to: $0) })) {
                    ForEach(AppsView.labels, id: \.0) { Text($0.1).tag($0.0) }
                }
                .labelsHidden()
                .frame(width: 140)
                .accessibilityLabel("How \(app.name) counts")
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
