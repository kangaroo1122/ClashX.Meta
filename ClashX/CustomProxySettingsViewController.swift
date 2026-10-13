import AppKit
import SwiftUI

@MainActor
final class CustomProxyEditor: ObservableObject {
    @Published var draft = CustomProxyConfiguration()
    @Published private(set) var saved = CustomProxyConfiguration()
    @Published private(set) var message = ""
    @Published private(set) var isError = false
    @Published private(set) var isSaving = false
    @Published private(set) var loadFailed = false

    var isDirty: Bool { draft != saved }

    init() { reload() }

    func reload() {
        do {
            let value = try CustomProxyStorage.load()
            draft = value
            saved = value
            loadFailed = false
            message = ""
        } catch {
            loadFailed = true
            report(error.localizedDescription, error: true)
        }
    }

    private func report(_ value: String, error: Bool = false) {
        message = value
        isError = error
    }

    func save() async {
        guard !isSaving, !loadFailed else { return }
        isSaving = true
        defer { isSaving = false }
        let candidate = draft
        await ConfigApplyCoordinator.shared.perform { await self.apply(candidate) }
    }

    private func apply(_ candidate: CustomProxyConfiguration) async {
        do {
            if candidate.enabled { try candidate.validate() }
            let state = ConfigManager.shared.kernelState
            if RemoteControlManager.selectConfig != nil || state == .stopped || state == .failedToStart {
                try CustomProxyStorage.save(candidate)
                saved = candidate
                report(NSLocalizedString("Saved. Custom settings apply the next time a local configuration is loaded.", comment: ""))
                return
            }
            guard state == .running else { throw CustomProxyError("Wait for the core to finish starting or reloading before saving.") }
            let name = ConfigManager.selectConfigName
            guard let current = await ApiRequest.requestConfig() else { throw CustomProxyError("Unable to read the current core configuration.") }
            let rollbackPath = try ConfigOverride.shared.prepareRollback(tunEnabled: current.tun.enable)
            defer {
                if let rollbackPath { ConfigOverride.shared.discardPreparedConfig(path: rollbackPath) }
            }
            guard let candidatePath = await ConfigOverride.shared.composeConfig(configName: name, tunEnabled: current.tun.enable, custom: candidate) else {
                throw CustomProxyError(ConfigOverride.shared.compositionError ?? "Unable to compose the custom configuration.")
            }
            defer { ConfigOverride.shared.discardPreparedConfig(path: candidatePath) }
            let generation = ConfigOverride.shared.runtimeGeneration
            func stillCurrent(allowDisconnected: Bool = false) -> Bool {
                let state = ConfigManager.shared.kernelState
                return RemoteControlManager.selectConfig == nil && ConfigManager.selectConfigName == name
                    && ConfigOverride.shared.runtimeGeneration == generation
                    && (state == .running || (allowDisconnected && state == .disconnected))
            }
            guard stillCurrent() else { throw CustomProxyError("Configuration changed. Please try again.") }
            let applyError = await ApiRequest.requestConfigUpdate(configPath: candidatePath)
            // A successful PUT is authoritative even if the log stream lost
            // contact. Persist it so disk and the running core stay in sync.
            guard stillCurrent(allowDisconnected: true) else { throw CustomProxyError("Configuration changed. Please try again.") }
            do {
                if let applyError { throw CustomProxyError(applyError) }
                try CustomProxyStorage.save(candidate)
            } catch {
                let originalError = error.localizedDescription
                guard let rollbackPath else {
                    throw CustomProxyError(originalError + "\n" + NSLocalizedString("No previously applied configuration is available for rollback. Reload a working subscription.", comment: ""))
                }
                if let rollbackError = await ApiRequest.requestConfigUpdate(configPath: rollbackPath) {
                    throw CustomProxyError(originalError + "\n" + NSLocalizedString("Unable to restore the previous configuration:", comment: "") + " " + rollbackError)
                }
                if stillCurrent() { await ConfigReloadManager.shared.handleClashConfigUpdated(preserveProxyState: true) }
                throw CustomProxyError(originalError)
            }
            saved = candidate
            if stillCurrent() { await ConfigReloadManager.shared.handleClashConfigUpdated(preserveProxyState: true) }
            report(NSLocalizedString("Custom proxy settings saved and applied.", comment: ""))
        } catch {
            report(error.localizedDescription, error: true)
        }
    }

    func recover() async {
        guard loadFailed, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let backup = try await ConfigApplyCoordinator.shared.perform {
                let backup = try CustomProxyStorage.backUpAndDisable()
                CustomProxyHealth.shared.invalidate()
                self.reload()
                return backup
            }
            var text = NSLocalizedString("Custom settings disabled. Backup:", comment: "") + " " + backup.path
            if RemoteControlManager.selectConfig == nil {
                if let error = await ConfigReloadManager.shared.updateConfig(showNotification: false) {
                    text += "\n" + error
                    report(text, error: true)
                    return
                }
            }
            report(text)
        } catch {
            report(error.localizedDescription, error: true)
        }
    }
}

final class CustomProxySettingsViewController: NSViewController, WindowCloseConfirming {
    private let editor = CustomProxyEditor()

    override func loadView() {
        title = NSLocalizedString("Custom proxies and rules", comment: "")
        view = NSHostingView(rootView: CustomProxySettingsView(editor: editor))
        preferredContentSize = NSSize(width: 900, height: 660)
        view.setFrameSize(preferredContentSize)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.contentMinSize = NSSize(width: 800, height: 560)
    }

    func shouldCloseWindow() -> Bool {
        guard !editor.isSaving else { return false }
        guard editor.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Discard unsaved custom proxy changes?", comment: "")
        alert.addButton(withTitle: NSLocalizedString("Keep editing", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Discard changes", comment: ""))
        return alert.runModal() == .alertSecondButtonReturn
    }
}

private struct CustomProxySettingsView: View {
    @ObservedObject var editor: CustomProxyEditor
    @ObservedObject private var health = CustomProxyHealth.shared
    @State private var confirmRecovery = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Enable custom proxies and rules", isOn: $editor.draft.enabled)
                .font(.headline)
            Text("Applied to every local subscription. Custom rules run first; unmatched traffic follows the subscription. Use Rule mode for routing.")
                .font(.callout).foregroundColor(.secondary)
            TabView {
                CustomEntryList(items: $editor.draft.proxies, makeItem: { CustomProxyEntry() }, label: { $0.name }, status: { health.statusText(for: $0) }) { item in
                    ProxyEntryForm(proxy: item)
                }.tabItem { Text("Custom proxies") }
                CustomEntryList(items: $editor.draft.groups, makeItem: { CustomProxyGroup() }, label: { $0.name }) { item in
                    ProxyGroupForm(group: item, targets: editor.draft.targets)
                }.tabItem { Text("Custom proxy groups") }
                CustomEntryList(items: $editor.draft.rules, makeItem: { CustomProxyRule() }, label: { "\($0.type) · \($0.value) → \($0.target)" }) { item in
                    ProxyRuleForm(rule: item, targets: editor.draft.targets, providers: editor.draft.providers.map(\.name))
                }.tabItem { Text("Custom rules") }
                CustomEntryList(items: $editor.draft.providers, makeItem: { CustomRuleProvider() }, label: { $0.name }) { item in
                    RuleProviderForm(provider: item)
                }.tabItem { Text("Custom rule sets") }
            }
            .disabled(editor.isSaving || editor.loadFailed)
            if !editor.message.isEmpty {
                Text(verbatim: editor.message)
                    .foregroundColor(editor.isError ? .red : .secondary)
                    .textSelection(.enabled)
                    .lineLimit(4)
            }
            HStack {
                if editor.isDirty { Text("Unsaved changes").foregroundColor(.secondary) }
                Button("Test custom proxies") { Task { await health.testAll() } }
                    .disabled(editor.isDirty || !editor.saved.enabled || health.activeConfiguration == nil || !health.testing.isEmpty)
                Spacer()
                if editor.loadFailed {
                    Button("Retry reading settings") { editor.reload() }
                    Button("Back up and disable") { confirmRecovery = true }
                }
                if editor.isSaving { ProgressView().controlSize(.small) }
                Button("Save and apply") { Task { await editor.save() } }
                    .disabled(editor.isSaving || editor.loadFailed || (!editor.isDirty &&
                        (RemoteControlManager.selectConfig != nil || ConfigManager.shared.kernelState != .running || health.hasApplied(editor.saved))))
                    .keyboardShortcut("s", modifiers: .command)
            }
        }
        .padding(20)
        .disabled(editor.isSaving)
        .alert("Back up and disable custom settings?", isPresented: $confirmRecovery) {
            Button("Cancel", role: .cancel) {}
            Button("Back up and disable") { Task { await editor.recover() } }
        } message: {
            Text("The original file will be kept as a local backup. Custom proxies and rules will be disabled before reloading the subscription.")
        }
    }
}

/// Stable-ID selection keeps bindings safe when a row is deleted or reordered.
private struct CustomEntryList<Item: Identifiable & Equatable, Detail: View>: View where Item.ID == UUID {
    @Binding var items: [Item]
    let makeItem: () -> Item
    let label: (Item) -> String
    var status: (Item) -> String = { _ in "" }
    @ViewBuilder var detail: (Binding<Item>) -> Detail
    @State private var selection: UUID?
    @State private var confirmDelete = false

    private var selectedIndex: Int? { items.firstIndex { $0.id == selection } }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 8) {
                List(selection: $selection) {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(label(item).isEmpty ? NSLocalizedString("Untitled entry", comment: "") : label(item)).lineLimit(2)
                            if !status(item).isEmpty {
                                Text(verbatim: status(item)).font(.caption).foregroundColor(.secondary)
                            }
                        }.tag(item.id)
                    }
                }
                HStack {
                    Button { let item = makeItem(); items.append(item); selection = item.id } label: { Image(systemName: "plus") }
                        .help("Add entry")
                    Button { confirmDelete = true } label: { Image(systemName: "minus") }
                        .disabled(selectedIndex == nil).help("Delete entry")
                    Spacer()
                    Button { move(-1) } label: { Image(systemName: "arrow.up") }
                        .disabled(selectedIndex == nil || selectedIndex == 0).help("Move up")
                    Button { move(1) } label: { Image(systemName: "arrow.down") }
                        .disabled(selectedIndex == nil || selectedIndex == items.count - 1).help("Move down")
                }.padding(.horizontal, 8)
            }.frame(width: 250).padding(.vertical, 8)
            Divider()
            ScrollView {
                if let index = selectedIndex {
                    let item = items[index]
                    detail(Binding(get: { items.first(where: { $0.id == item.id }) ?? item }, set: { updated in
                        if let current = items.firstIndex(where: { $0.id == item.id }) { items[current] = updated }
                    }))
                    .padding(16)
                } else {
                    Text("Add or select an entry to edit its settings.")
                        .foregroundColor(.secondary).padding(32)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .alert("Delete this entry?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                guard let index = selectedIndex else { return }
                items.remove(at: index)
                selection = items.first?.id
            }
        } message: {
            Text("Update any groups or rules that reference this entry before saving.")
        }
    }

    private func move(_ offset: Int) {
        guard let index = selectedIndex, items.indices.contains(index + offset) else { return }
        items.swapAt(index, index + offset)
    }
}

private struct ProxyEntryForm: View {
    @Binding var proxy: CustomProxyEntry
    @ObservedObject private var health = CustomProxyHealth.shared
    var body: some View {
        Form {
            TextField("Name", text: $proxy.name)
            Picker("Proxy protocol", selection: $proxy.type) {
                Text("HTTP").tag("http")
                Text("SOCKS5").tag("socks5")
            }
            TextField("Server", text: $proxy.server)
            TextField("Port", text: $proxy.port)
            TextField("Username (optional)", text: $proxy.username)
            SecureField("Password (optional)", text: $proxy.password)
            Toggle("TLS", isOn: $proxy.tls)
            if proxy.tls {
                TextField("SNI (optional)", text: $proxy.sni)
                Toggle("Skip certificate verification", isOn: $proxy.skipCertVerify)
            }
            if proxy.type == "socks5" { Toggle("UDP forwarding", isOn: $proxy.udp) }
            TextField("Node test URL (optional)", text: Binding(
                get: { proxy.testURL ?? "" },
                set: { proxy.testURL = $0.isEmpty ? nil : $0 }
            ))
            Text("Use an internal HTTP or HTTPS URL for work proxies. Leave blank to use the app test URL. Save and apply before testing; timeout is 5 seconds.")
                .font(.caption).foregroundColor(.secondary)
            HStack {
                Text(verbatim: health.statusText(for: proxy))
                Button("Test this proxy") { let value = proxy; Task { await health.test(value) } }
                    .disabled(!health.canTest(proxy) || health.testing.contains(proxy.id))
            }
            if let result = health.result(for: proxy) {
                Text(verbatim: result.url).font(.caption).foregroundColor(.secondary).textSelection(.enabled)
                Text(result.checkedAt, style: .time).font(.caption).foregroundColor(.secondary)
            }
            Text("HTTP and SOCKS5 cover the nodes in your work configurations. Credentials are saved locally with owner-only file permissions.")
                .font(.caption).foregroundColor(.secondary)
        }.textFieldStyle(.roundedBorder)
    }
}

private struct ProxyGroupForm: View {
    @Binding var group: CustomProxyGroup
    let targets: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Form {
                TextField("Name", text: $group.name)
                Picker("Group type", selection: $group.type) {
                    Text("Manual selection").tag("select")
                    Text("Automatic fallback").tag("fallback")
                    Text("Lowest latency").tag("url-test")
                }
                if group.type != "select" {
                    TextField("Health-check URL", text: $group.url)
                    TextField("Interval (seconds)", text: $group.interval)
                    TextField("Timeout (milliseconds)", text: $group.timeout)
                    Toggle("Check only when in use", isOn: $group.lazy)
                    if group.type == "url-test" {
                        TextField("Tolerance (milliseconds)", text: $group.tolerance)
                    }
                }
            }.textFieldStyle(.roundedBorder)
            Text("Members, in priority order").font(.headline)
            ForEach(Array(group.members.enumerated()), id: \.offset) { index, member in
                HStack {
                    Text(verbatim: member)
                    Spacer()
                    Button { group.members.swapAt(index, index - 1) } label: { Image(systemName: "arrow.up") }
                        .disabled(index == 0).help("Move up")
                    Button { group.members.swapAt(index, index + 1) } label: { Image(systemName: "arrow.down") }
                        .disabled(index + 1 == group.members.count).help("Move down")
                    Button { group.members.remove(at: index) } label: { Image(systemName: "minus") }.help("Remove member")
                }
            }
            Menu("Add member") {
                ForEach(Array(Set(targets)).sorted().filter { $0 != group.name && !group.members.contains($0) }, id: \.self) { name in
                    Button(name) { group.members.append(name) }
                }
            }
            Text("Fallback tries members from top to bottom. Groups may contain other custom groups; circular references are rejected.")
                .font(.caption).foregroundColor(.secondary)
        }
    }
}

private struct ProxyRuleForm: View {
    @Binding var rule: CustomProxyRule
    let targets: [String]
    let providers: [String]
    var body: some View {
        Form {
            Picker("Rule type", selection: $rule.type) {
                ForEach(CustomProxyRule.types, id: \.self) { Text(verbatim: $0).tag($0) }
            }
            if rule.type == "RULE-SET" {
                Picker("Rule set", selection: $rule.value) {
                    Text("Choose a rule set").tag("")
                    ForEach(Array(Set(providers + (rule.value.isEmpty ? [] : [rule.value]))).sorted(), id: \.self) { Text(verbatim: $0).tag($0) }
                }
            } else {
                TextField("Domain, network or process", text: $rule.value)
            }
            Picker("Route to", selection: $rule.target) {
                ForEach(Array(Set(targets + [rule.target])).sorted(), id: \.self) { Text(verbatim: $0).tag($0) }
            }
            if rule.supportsNoResolve { Toggle("Do not resolve DNS for this rule", isOn: $rule.noResolve) }
            Text("Rules match from top to bottom, ahead of subscription rules. Put a specific host (/32) before its wider network (/24). No catch-all rule is added.")
                .font(.caption).foregroundColor(.secondary)
        }.textFieldStyle(.roundedBorder)
    }
}

private struct RuleProviderForm: View {
    @Binding var provider: CustomRuleProvider
    var body: some View {
        Form {
            TextField("Name", text: $provider.name)
            TextField("Rule-set download URL", text: $provider.url)
            Picker("Rule-set behavior", selection: $provider.behavior) {
                Text("Classical rules").tag("classical")
                Text("Domains").tag("domain")
                Text("IP networks").tag("ipcidr")
            }
            Picker("File format", selection: $provider.format) {
                Text("YAML").tag("yaml")
                Text("Text").tag("text")
                Text("MRS").tag("mrs")
            }
            TextField("Update interval (seconds)", text: $provider.interval)
            Text("Rule sets are downloaded by the core after applying. Add a RULE-SET rule to choose their routing target. Cache paths are managed automatically.")
                .font(.caption).foregroundColor(.secondary)
        }.textFieldStyle(.roundedBorder)
    }
}
