import Foundation

/// A snapshot of what is in front of the user right now.
public struct ActivityContext: Equatable, Sendable {
    public var bundleId: String
    public var appName: String
    public var title: String
    public var url: String?
    public var isBrowser: Bool
    public var isSelf: Bool

    public init(bundleId: String, appName: String, title: String, url: String?, isBrowser: Bool, isSelf: Bool) {
        self.bundleId = bundleId; self.appName = appName; self.title = title
        self.url = url; self.isBrowser = isBrowser; self.isSelf = isSelf
    }

    public var host: String? {
        guard let url, let comps = URLComponents(string: url), let scheme = comps.scheme?.lowercased(),
              scheme == "http" || scheme == "https", var host = comps.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    /// Two contexts with the same key count as the same visit.
    public var key: String {
        if isBrowser { return "web:" + (host ?? title.lowercased()) }
        return "app:" + bundleId
    }
}

public enum Verdict: Equatable, Sendable {
    case onTask
    case offTask(EventCategory)
    /// Blank tabs and the timer's own window: neither starts nor ends a visit.
    case neutral
}

public struct FocusRules: Sendable {
    public var allowedBundleIds: Set<String>
    public var allowedDomains: [String]
    public var distractionDomains: [String]
    public var distractionApps: [String]

    public init(allowedBundleIds: Set<String>, allowedDomains: [String], distractionDomains: [String], distractionApps: [String]) {
        self.allowedBundleIds = allowedBundleIds
        self.allowedDomains = allowedDomains.map(FocusRules.normalize).filter { !$0.isEmpty }
        self.distractionDomains = distractionDomains.map(FocusRules.normalize).filter { !$0.isEmpty }
        self.distractionApps = distractionApps.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// "https://www.Khanacademy.org/math" -> "khanacademy.org"
    public static func normalize(_ raw: String) -> String {
        var s = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        return s
    }

    public static func parseList(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == " " })
            .map { normalize(String($0)) }.filter { !$0.isEmpty }
    }

    static func matches(_ host: String, _ domains: [String]) -> Bool {
        domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// macOS's own prompts and overlays (permission dialogs, password sheets, Spotlight, Control Centre).
    /// They are not something the teen chose to switch to, so they neither start nor end a visit.
    public static let systemOverlays: Set<String> = [
        "com.apple.UserNotificationCenter", "com.apple.notificationcenterui", "com.apple.controlcenter",
        "com.apple.SecurityAgent", "com.apple.Spotlight", "com.apple.dock", "com.apple.systemuiserver",
        "com.apple.coreservices.uiagent", "com.apple.LocalAuthentication.UIAgent",
    ]

    /// How a website is judged, in order of authority: the parent's decision on that site, an approved
    /// "needed for work" window, the parent's own list, then the AI label. `nil` means nothing is known yet.
    public func siteCountsAsDistraction(_ host: String, sites: SiteBook) -> Bool? {
        let state = sites.state(for: host)
        if let state, state.parentDecided { return state.countsAsDistraction }
        if sites.isApproved(host) { return false }
        if FocusRules.matches(host, distractionDomains) { return true }
        return state?.countsAsDistraction
    }

    /// Outside a sprint there is no allowed list, so only known distractions count.
    public func isKnownDistraction(_ ctx: ActivityContext, sites: SiteBook = SiteBook()) -> Bool {
        if ctx.isSelf || FocusRules.systemOverlays.contains(ctx.bundleId) { return false }
        if ctx.isBrowser {
            if let host = ctx.host { return siteCountsAsDistraction(host, sites: sites) ?? false }
            let title = ctx.title.lowercased()
            guard ctx.url == nil, !title.isEmpty else { return false }
            return distractionDomains.contains { title.contains(String($0.split(separator: ".").first ?? "")) }
        }
        return distractionApps.contains(ctx.appName.lowercased())
    }

    /// `awaitingLabel`: a label for this site has just been requested, so hold the verdict for a moment
    /// instead of recording a site that is about to turn out fine.
    public func classify(_ ctx: ActivityContext, sites: SiteBook = SiteBook(), awaitingLabel: Bool = false) -> Verdict {
        if ctx.isSelf || FocusRules.systemOverlays.contains(ctx.bundleId) { return .neutral }
        if ctx.isBrowser {
            if let host = ctx.host {
                if FocusRules.matches(host, allowedDomains) { return .onTask }
                switch siteCountsAsDistraction(host, sites: sites) {
                case true?: return .offTask(.distraction)
                case false?: return .onTask // labelled productive, or allowed by the parent
                case nil: return awaitingLabel ? .neutral : .offTask(.offTask)
                }
            }
            // The URL could not be read (Firefox, or Automation permission denied): fall back to the tab title.
            let title = ctx.title.lowercased()
            if ctx.url == nil, !title.isEmpty {
                let names = { (d: String) in String(d.split(separator: ".").first ?? "") }
                if distractionDomains.contains(where: { title.contains(names($0)) }) { return .offTask(.distraction) }
                if allowedDomains.contains(where: { title.contains(names($0)) }) { return .onTask }
                return .offTask(.offTask)
            }
            return .neutral // blank / new-tab page
        }
        if allowedBundleIds.contains(ctx.bundleId) { return .onTask }
        let name = ctx.appName.lowercased()
        return .offTask(distractionApps.contains(name) ? .distraction : .offTask)
    }
}
