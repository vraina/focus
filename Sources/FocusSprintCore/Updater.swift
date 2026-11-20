import Foundation

/// The version of the app on this Mac, read from the app the helper was installed with.
public enum AppVersion {
    public static let installed: String = {
        let beside = URL(fileURLWithPath: CommandLine.arguments.first ?? "").deletingLastPathComponent()
            .appendingPathComponent("YoungWonks Focus.app/Contents/Info.plist") // a development build
        for plist in [Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist"), beside,
                      URL(fileURLWithPath: "/Applications/YoungWonks Focus.app/Contents/Info.plist")] {
            if let info = NSDictionary(contentsOf: plist), let version = info["CFBundleShortVersionString"] as? String { return version }
        }
        return ""
    }()

    static func numbers(_ version: String) -> [Int] {
        version.split(whereSeparator: { !$0.isNumber }).prefix(4).compactMap { Int($0) }
    }

    /// Compares as numbers, so 0.10.0 is newer than 0.9.2. Something that is not a version is never newer.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let (a, b) = (numbers(candidate), numbers(current))
        guard !a.isEmpty else { return false }
        for i in 0..<max(a.count, b.count) {
            let (x, y) = (i < a.count ? a[i] : 0, i < b.count ? b[i] : 0)
            if x != y { return x > y }
        }
        return false
    }
}

/// Keeps an installed Mac up to date without anyone doing anything.
///
/// The helper (root) asks the service which version is current, downloads the installer and installs it. The
/// service and the download are not trusted: a package is installed only if macOS itself says Apple notarised it
/// AND it was signed by the same developer team as the helper that is already running, AND it really is a newer
/// version. A development or unsigned build has no team, so it never updates itself.
public struct Updater {
    public enum Failure: Error, LocalizedError, Equatable {
        case notInstalled, noTeam, badAddress, download(Int), notNotarised, wrongTeam(String), notNewer(String), install(String)
        public var errorDescription: String? {
            switch self {
            case .notInstalled: return "updates only run in the installed helper"
            case .noTeam: return "this build is not signed with a Developer ID, so it does not update itself"
            case .badAddress: return "the update address is not a secure GitHub address"
            case .download(let code): return "the download failed (\(code))"
            case .notNotarised: return "the downloaded installer is not notarised by Apple"
            case .wrongTeam(let team): return "the downloaded installer is signed by someone else (\(team))"
            case .notNewer(let version): return "the downloaded installer is version \(version.isEmpty ? "unknown" : version), not newer than this one"
            case .install(let output): return "the installer failed: \(output)"
            }
        }
    }

    public struct Release: Decodable, Equatable {
        public var version: String
        public var url: String
    }

    public init() {}

    // MARK: The checks, as plain functions over what the system tools print

    /// The team of a signed program, from `codesign -dv --verbose=4`. Nil for ad-hoc and development builds.
    public static func team(fromCodesign output: String) -> String? {
        guard let line = output.split(separator: "\n").first(where: { $0.hasPrefix("TeamIdentifier=") }) else { return nil }
        let team = String(line.dropFirst("TeamIdentifier=".count)).trimmingCharacters(in: .whitespaces)
        let developerID = output.contains("Authority=Developer ID Application:")
        return developerID && team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil ? team : nil
    }

    /// The team that signed a package, but only when `spctl --assess --type install -vv` accepted it as notarised.
    public static func notarisedTeam(fromSpctl output: String) -> String? {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.contains(where: { $0.hasSuffix(": accepted") }), lines.contains("source=Notarized Developer ID"),
              let origin = lines.first(where: { $0.hasPrefix("origin=Developer ID Installer:") }),
              let open = origin.lastIndex(of: "("), origin.hasSuffix(")") else { return nil }
        let team = String(origin[origin.index(after: open)..<origin.index(before: origin.endIndex)])
        return team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil ? team : nil
    }

    /// The version a package says it installs, from the Distribution file inside it.
    public static func version(fromDistribution xml: String) -> String {
        guard let range = xml.range(of: #"<pkg-ref id="com\.focussprint\.pkg" version="([0-9.]+)""#, options: .regularExpression) else { return "" }
        return xml[range].split(separator: "\"").last.map(String.init) ?? ""
    }

    /// Only GitHub, only https. The file is checked afterwards anyway; this just keeps the helper from fetching arbitrary addresses.
    public static func allowed(_ address: String) -> URL? {
        guard let url = URL(string: address), url.scheme == "https", url.host == "github.com", url.path.hasSuffix(".pkg") else { return nil }
        return url
    }

    /// Everything that must hold before a downloaded package may be installed.
    public static func approve(spctl: String, distribution: String, ownTeam: String, ownVersion: String) throws -> String {
        guard let team = notarisedTeam(fromSpctl: spctl) else { throw Failure.notNotarised }
        guard team == ownTeam else { throw Failure.wrongTeam(team) }
        let version = Self.version(fromDistribution: distribution)
        guard AppVersion.isNewer(version, than: ownVersion) else { throw Failure.notNewer(version) }
        return version
    }

    // MARK: Doing it

    static func run(_ tool: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    public static func ownTeam() -> String? {
        guard let path = Bundle.main.executablePath else { return nil }
        return team(fromCodesign: run("/usr/bin/codesign", ["-dv", "--verbose=4", path]).output)
    }

    /// Asks the service for the current version. Returns it only when it is newer than what is installed.
    public func available(serviceURL: String = ServiceConfig.baseURL) async throws -> Release? {
        guard let url = URL(string: serviceURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) + "/api/version") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let release = try? JSONDecoder().decode(Release.self, from: data),
              AppVersion.isNewer(release.version, than: AppVersion.installed) else { return nil }
        return release
    }

    /// Downloads, checks and installs. On success the installer restarts the helper, so this usually never returns.
    public func install(_ release: Release) async throws -> String {
        guard getuid() == 0 else { throw Failure.notInstalled }
        guard let ownTeam = Self.ownTeam() else { throw Failure.noTeam }
        guard let url = Self.allowed(release.url) else { throw Failure.badAddress }

        // A folder only root can touch, so nothing can swap the file between the check and the install.
        let folder = Paths.root.appendingPathComponent("update")
        let fm = FileManager.default
        try? fm.removeItem(at: folder)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: folder) }

        let (downloaded, response) = try await URLSession.shared.download(from: url)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw Failure.download(code) }
        let package = folder.appendingPathComponent("YoungWonksFocus.pkg")
        try fm.moveItem(at: downloaded, to: package)

        let assessed = Self.run("/usr/sbin/spctl", ["--assess", "--type", "install", "-vv", package.path]).output
        let expanded = folder.appendingPathComponent("expanded")
        _ = Self.run("/usr/sbin/pkgutil", ["--expand", package.path, expanded.path])
        let distribution = (try? String(contentsOf: expanded.appendingPathComponent("Distribution"), encoding: .utf8)) ?? ""
        let version = try Self.approve(spctl: assessed, distribution: distribution, ownTeam: ownTeam, ownVersion: AppVersion.installed)

        let result = Self.run("/usr/sbin/installer", ["-pkg", package.path, "-target", "/"])
        guard result.status == 0 else { throw Failure.install(String(result.output.suffix(300))) }
        return version
    }
}
