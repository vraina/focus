import AppKit
import Security
import SwiftUI
import FocusSprintCore

enum Keychain {
    private static let service = "com.focussprint.app"

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: key, kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ key: String, _ value: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        SecItemAdd(base.merging([kSecValueData as String: Data(value.utf8)]) { $1 } as CFDictionary, nil)
    }
}

/// Writes root-owned files. macOS shows its own administrator password prompt, so a Standard
/// account cannot change parent settings.
enum AdminWriter {
    struct Item {
        var data: Data
        var destination: URL
        var mode: String
    }

    /// Proves an administrator is at the keyboard, using the standard macOS password prompt.
    static func authenticate() -> Bool {
        if FileManager.default.isWritableFile(atPath: Paths.root.path) { return true } // development root
        let script = NSAppleScript(source: "do shell script \"/usr/bin/true\" with prompt \"YoungWonks Focus parent settings\" with administrator privileges")
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        return error == nil
    }

    static func install(_ items: [Item]) throws {
        let fm = FileManager.default
        if fm.isWritableFile(atPath: Paths.root.path) {
            // Development root owned by the current user: no elevation needed.
            for item in items {
                try item.data.write(to: item.destination, options: .atomic)
                chmod(item.destination.path, mode_t(item.mode, radix: 8) ?? 0o644)
            }
            return
        }
        let staging = fm.temporaryDirectory.appendingPathComponent("focussprint-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        var commands: [String] = []
        for (index, item) in items.enumerated() {
            let tmp = staging.appendingPathComponent("\(index)")
            try item.data.write(to: tmp)
            commands.append("/usr/bin/install -m \(item.mode) -o root -g wheel '\(tmp.path)' '\(item.destination.path)'")
        }
        let shell = commands.joined(separator: " && ")
            .replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = NSAppleScript(source: "do shell script \"\(shell)\" with prompt \"YoungWonks Focus parent settings\" with administrator privileges")
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        if let error {
            throw NSError(domain: "FocusSprint", code: 1, userInfo: [
                NSLocalizedDescriptionKey: (error[NSAppleScript.errorMessage] as? String) ?? "Administrator approval was not given."])
        }
    }
}

struct SettingsView: View {
    @State private var config = ParentConfig.load()
    @State private var domainsText = ""
    @State private var appsText = ""
    @State private var mongoURI = ""
    @State private var serviceURL = ""
    @State private var deviceToken = ""
    @State private var unlocked = false
    @State private var viewerURI = Keychain.get("viewerURI") ?? ""
    @State private var status = HelperStatus.load()
    @State private var message: String?
    @State private var messageIsError = false
    private let statusTimer = Timer.publish(every: 4, on: .main, in: .common).autoconnect()

    var body: some View {
        if unlocked {
            settings.onDisappear { unlocked = false } // locks again as soon as the tab is left
        } else {
            VStack(spacing: 14) {
                Image(systemName: "lock.fill").font(.system(size: 44)).foregroundStyle(.secondary)
                Text("Parent settings").font(.title.bold())
                Text("Only a parent can open this section. It needs the Mac administrator password.")
                    .foregroundStyle(.secondary)
                Button("Unlock…") { unlocked = AdminWriter.authenticate() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var settings: some View {
        Form {
            Section("What gets captured on each switch") {
                Picker("Capture", selection: $config.captureMode) {
                    Text("Screenshots").tag(CaptureMode.screenshot)
                    Text("Short video clips").tag(CaptureMode.video)
                }
                .pickerStyle(.segmented)
                if config.captureMode == .video {
                    Stepper("Clip length: first and last \(config.clipSeconds) seconds", value: $config.clipSeconds, in: 2...15)
                } else {
                    Text("One picture when the switch starts and one from just before returning.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Outside sprints") {
                Toggle("Track known distractions all day", isOn: $config.trackAllDay)
                Text("When no sprint is running, visits to the sites and apps listed below are still recorded, with the same pictures, and count towards the day's total. Everything else is left alone.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Known distractions (flagged in red)") {
                VStack(alignment: .leading) {
                    Text("Websites, one per line").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $domainsText).font(.body.monospaced()).frame(height: 110)
                }
                VStack(alignment: .leading) {
                    Text("Apps, one per line").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $appsText).font(.body.monospaced()).frame(height: 70)
                }
            }
            Section("Cloud storage (MongoDB Atlas)") {
                LabeledContent("Upload status", value: statusText)
                field("Connection string for the insert-only user", hint: "Leave blank to keep the current one",
                      placeholder: "mongodb+srv://user:password@cluster.mongodb.net/focus", text: $mongoURI, secret: true)
                Text("Stored where only an administrator can read it. Records wait on this Mac until Atlas confirms each one.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Website labels and parent emails") {
                field("Family service address", hint: "Fill in both, or leave both blank to keep the current ones",
                      placeholder: "https://your-service.onrender.com", text: $serviceURL, secret: false)
                field("Device token", hint: "The DEVICE_TOKEN value from the service's environment settings",
                      placeholder: "Paste the token here", text: $deviceToken, secret: true)
                Text("New websites are labelled productive or distraction by Claude through this service. It also reviews \"needed for work\" requests and emails you one summary at the end of each day. Nothing is ever blocked.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Save parent settings…") { save() }.buttonStyle(.borderedProminent)
                    Text("Asks for a Mac administrator password.").font(.caption).foregroundStyle(.secondary)
                }
                if let message { Text(message).foregroundStyle(messageIsError ? .red : .green) }
            }
            Section("Viewing cloud history on this Mac") {
                field("Connection string for a read-only user", hint: "Saved in this user's keychain",
                      placeholder: "mongodb+srv://viewer:password@cluster.mongodb.net/focus", text: $viewerURI, secret: true)
                Button("Save for this user") {
                    Keychain.set("viewerURI", viewerURI.trimmingCharacters(in: .whitespacesAndNewlines))
                    message = "Saved. Open History and choose Cloud."
                    messageIsError = false
                }
                Text("Optional. Lets History show sprints from the cloud, for example on a parent's Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            config = ParentConfig.load()
            domainsText = config.distractionDomains.joined(separator: "\n")
            appsText = config.distractionApps.joined(separator: "\n")
        }
        .onReceive(statusTimer) { _ in status = HelperStatus.load() }
    }

    /// A label above a full-width box. (A plain Form text field puts its title on the left and leaves
    /// the box on the right with no border, which made these look like there was nowhere to type.)
    private func field(_ label: String, hint: String, placeholder: String, text: Binding<String>, secret: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.headline)
            Group {
                if secret {
                    SecureField("", text: text, prompt: Text(placeholder))
                } else {
                    TextField("", text: text, prompt: Text(placeholder))
                }
            }
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            Text(hint).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var statusText: String {
        guard let status, status.isFresh else { return "Vault helper is not running" }
        if !status.mongoConfigured { return "No connection string yet · \(status.pending) item(s) waiting on this Mac" }
        if status.pending == 0 { return "Everything is uploaded" }
        return "\(status.pending) item(s) waiting" + (status.lastError != nil ? " · cannot reach Atlas, will retry" : "")
    }

    private func save() {
        config.distractionDomains = FocusRules.parseList(domainsText)
        config.distractionApps = appsText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        do {
            var items = [AdminWriter.Item(data: try JSONCoding.encoder.encode(config), destination: Paths.config, mode: "644")]
            let uri = mongoURI.trimmingCharacters(in: .whitespacesAndNewlines)
            if !uri.isEmpty {
                items.append(AdminWriter.Item(data: try JSONEncoder().encode(Secrets(mongoURI: uri)), destination: Paths.secrets, mode: "600"))
            }
            let address = serviceURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let token = deviceToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if !address.isEmpty, !token.isEmpty {
                items.append(AdminWriter.Item(data: try JSONEncoder().encode(ServiceConfig(serviceURL: address, deviceToken: token)),
                                              destination: Paths.service, mode: "600"))
            }
            try AdminWriter.install(items)
            mongoURI = ""
            deviceToken = ""
            message = "Saved. Applies from the next sprint."
            messageIsError = false
        } catch {
            message = error.localizedDescription
            messageIsError = true
        }
    }
}
