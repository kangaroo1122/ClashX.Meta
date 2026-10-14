import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class CustomProxyEditor: ObservableObject {
    static let shared = CustomProxyEditor()
    @Published var selectedTab = 0
    @Published var draft = CustomProxyConfiguration()
    @Published private(set) var saved = CustomProxyConfiguration()
    @Published private(set) var message = ""
    @Published private(set) var isError = false
    @Published private(set) var isSaving = false
    @Published private(set) var loadFailed = false
    @Published private var isTransferring = false

    var isDirty: Bool { draft != saved }
    var isBusy: Bool { isSaving || isTransferring }

    init() { reload() }

    func reload() {
        do {
            let value = try CustomProxyStorage.load()
            draft = value
            saved = value
            loadFailed = false
            message = ""
            isError = false
        } catch {
            loadFailed = true
            report(error.localizedDescription, error: true)
        }
    }

    private func report(_ value: String, error: Bool = false) {
        message = value
        isError = error
    }

    func importConfiguration() {
        guard !isBusy, !loadFailed else { return }
        isTransferring = true
        defer { isTransferring = false }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = NSLocalizedString("Import a ClashX custom configuration. Review it before saving and applying.", comment: "")
        guard panel.runModal() == .OK, let source = panel.url else { return }
        do {
            let candidate = try CustomProxyStorage.importConfiguration(from: source)
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Replace the current custom configuration draft?", comment: "")
            let counts = String(format: NSLocalizedString("Proxies: %ld · Proxy groups: %ld · Rules: %ld · Rule groups: %ld · Rule sets: %ld", comment: "Import summary"),
                                candidate.proxies.count, candidate.groups.count, candidate.rules.count, candidate.ruleGroups.count, candidate.providers.count)
            alert.informativeText = counts + "\n\n" + NSLocalizedString("This replaces all entries and the enable setting in the editor, including unsaved changes. Saved settings and the running core change only after Save and apply.", comment: "")
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Replace draft", comment: ""))
            guard alert.runModal() == .alertSecondButtonReturn else { return }
            draft = candidate
            report(NSLocalizedString("Imported into the editor. Review the settings, then choose Save and apply.", comment: ""))
        } catch {
            report(error.localizedDescription, error: true)
        }
    }

    func exportConfiguration() {
        guard !isBusy, !loadFailed else { return }
        isTransferring = true
        defer { isTransferring = false }
        do {
            let candidate = draft
            try candidate.validate()
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "ClashX-custom-proxies.json"
            panel.canCreateDirectories = true
            panel.message = NSLocalizedString("Exports the current editor contents, including unsaved changes. The file contains unencrypted proxy passwords; transfer and store it securely.", comment: "")
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            try CustomProxyStorage.exportConfiguration(candidate, to: destination)
            report(NSLocalizedString("Custom configuration exported. The file includes proxy credentials.", comment: ""))
        } catch {
            report(error.localizedDescription, error: true)
        }
    }

    func save() async {
        guard !isBusy, !loadFailed else { return }
        isSaving = true
        defer {
            isSaving = false
            MenuItemFactory.refreshRuleGroupMenu()
        }
        let candidate = draft
        await ConfigApplyCoordinator.shared.perform { await self.apply(candidate) }
    }

    /// Menu actions share the editor and its transaction, never overwrite an
    /// unsaved draft, and only commit the checkmark after apply/persist succeeds.
    func toggleRuleGroup(id: UUID, expectedEnabled: Bool) async {
        guard !isBusy else { return }
        if isDirty {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Save or discard your draft before switching rule groups.", comment: "")
            alert.addButton(withTitle: NSLocalizedString("Manage rules…", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Discard draft and switch", comment: ""))
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                selectedTab = 2
                ClashWindowController<CustomProxySettingsViewController>.create().showWindow(nil)
                return
            }
            guard response == .alertThirdButtonReturn else { return }
        }
        isSaving = true
        defer {
            isSaving = false
            MenuItemFactory.refreshRuleGroupMenu()
        }
        await ConfigApplyCoordinator.shared.perform {
            self.reload()
            guard !self.loadFailed, RemoteControlManager.selectConfig == nil,
                  ConfigManager.shared.kernelState == .running,
                  self.saved.enabled, CustomProxyHealth.shared.hasApplied(self.saved),
                  let index = self.saved.ruleGroups.firstIndex(where: { $0.id == id }),
                  self.saved.ruleGroups[index].enabled == expectedEnabled else {
                self.report(NSLocalizedString("Save and apply the current custom configuration before switching rule groups.", comment: ""), error: true)
                return
            }
            var candidate = self.saved
            candidate.ruleGroups[index].enabled.toggle()
            await self.apply(candidate)
            if !self.isError { self.draft = self.saved }
        }
        if isError {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Unable to switch rule group", comment: "")
            alert.informativeText = message
            alert.runModal()
        }
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
        guard loadFailed, !isBusy else { return }
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
    private let editor = CustomProxyEditor.shared

    override func loadView() {
        title = NSLocalizedString("Custom proxies and rules", comment: "")
        view = NSHostingView(rootView: CustomProxySettingsView(editor: editor))
        preferredContentSize = NSSize(width: 900, height: 660)
        view.setFrameSize(preferredContentSize)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.contentMinSize = NSSize(width: 800, height: 560)
        if !editor.isDirty && !editor.isBusy { editor.reload() }
    }

    func shouldCloseWindow() -> Bool {
        guard !editor.isBusy else { return false }
        guard editor.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Discard unsaved custom proxy changes?", comment: "")
        alert.addButton(withTitle: NSLocalizedString("Keep editing", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Discard changes", comment: ""))
        guard alert.runModal() == .alertSecondButtonReturn else { return false }
        editor.reload()
        return true
    }
}

private struct CustomProxySettingsView: View {
    @ObservedObject var editor: CustomProxyEditor
    @ObservedObject private var health = CustomProxyHealth.shared
    @State private var confirmRecovery = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Toggle("Enable custom proxies and rules", isOn: $editor.draft.enabled)
                    .font(.headline)
                Spacer()
                Button("Import configuration…") { editor.importConfiguration() }
                    .disabled(editor.loadFailed)
                Button("Export configuration…") { editor.exportConfiguration() }
                    .disabled(editor.loadFailed)
            }
            Text("Applied to every local subscription. Custom rules run first; unmatched traffic follows the subscription. Use Rule mode for routing.")
                .font(.callout).foregroundColor(.secondary)
            TabView(selection: $editor.selectedTab) {
                CustomEntryList(items: $editor.draft.proxies, makeItem: { CustomProxyEntry() }, label: { $0.name }, status: { health.statusText(for: $0) }) { item in
                    ProxyEntryForm(proxy: item)
                }.tabItem { Text("Custom proxies") }.tag(0)
                CustomEntryList(items: $editor.draft.groups, makeItem: { CustomProxyGroup() }, label: { $0.name }) { item in
                    ProxyGroupForm(group: item, targets: editor.draft.targets)
                }.tabItem { Text("Custom proxy groups") }.tag(1)
                CustomRulesView(configuration: $editor.draft)
                    .tabItem { Text("Custom rules") }.tag(2)
                CustomEntryList(items: $editor.draft.providers, makeItem: { CustomRuleProvider() }, label: { $0.name }) { item in
                    RuleProviderForm(provider: item)
                }.tabItem { Text("Custom rule sets") }.tag(3)
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
        .disabled(editor.isBusy)
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

private struct CustomRulesView: View {
    private enum Filter: Hashable {
        case all, ungrouped, group(UUID)
    }

    @Binding var configuration: CustomProxyConfiguration
    @State private var filter: Filter? = .all
    @State private var selectedRule: UUID?
    @State private var deletingGroup: UUID?
    @State private var confirmDeleteGroup = false
    @State private var deletingRule: UUID?
    @State private var confirmDeleteRule = false

    private var selectedGroupID: UUID? {
        if case let .group(id) = filter ?? .all { return id }
        return nil
    }

    private var visibleRules: [CustomProxyRule] {
        configuration.rules.filter { rule in
            switch filter ?? .all {
            case .all: return true
            case .ungrouped: return rule.groupID == nil
            case let .group(id): return rule.groupID == id
            }
        }
    }

    private var selectedIndex: Int? {
        configuration.rules.firstIndex { $0.id == selectedRule }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 210)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Rules match in global order. Reorder in All rules.")
                    .font(.caption).foregroundColor(.secondary)
                ruleTable.frame(minHeight: 130)
                HStack {
                    Button { addRule() } label: { Image(systemName: "plus") }
                        .help("Add entry")
                    Button {
                        deletingRule = selectedRule
                        confirmDeleteRule = true
                    } label: { Image(systemName: "minus") }
                        .disabled(selectedRule == nil).help("Delete entry")
                    Spacer()
                    Button { moveRule(-1) } label: { Image(systemName: "arrow.up") }
                        .disabled(filter != .all || selectedIndex == nil || selectedIndex == 0)
                        .help("Move up")
                    Button { moveRule(1) } label: { Image(systemName: "arrow.down") }
                        .disabled(filter != .all || selectedIndex == nil || selectedIndex == configuration.rules.count - 1)
                        .help("Move down")
                }
                Divider()
                ScrollView {
                    if let index = selectedIndex {
                        let rule = configuration.rules[index]
                        ProxyRuleForm(rule: Binding(get: {
                            configuration.rules.first { $0.id == rule.id } ?? rule
                        }, set: { value in
                            if let index = configuration.rules.firstIndex(where: { $0.id == rule.id }) {
                                configuration.rules[index] = value
                            }
                        }), targets: configuration.targets, providers: configuration.providers.map(\.name),
                                      ruleGroups: configuration.ruleGroups)
                    } else {
                        Text("Add or select an entry to edit its settings.")
                            .foregroundColor(.secondary).padding(20)
                    }
                }.frame(minHeight: 180, maxHeight: 235)
            }.padding(12)
        }
        .onChange(of: visibleRules.map(\.id)) { ids in
            if let selectedRule, !ids.contains(selectedRule) { self.selectedRule = nil }
        }
        .onChange(of: configuration.ruleGroups.map(\.id)) { ids in
            if let selectedGroupID, !ids.contains(selectedGroupID) { filter = .all }
        }
        .alert("Delete this rule group?", isPresented: $confirmDeleteGroup) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                guard let id = deletingGroup else { return }
                configuration.ruleGroups.removeAll { $0.id == id }
                for index in configuration.rules.indices where configuration.rules[index].groupID == id {
                    configuration.rules[index].groupID = nil
                }
                filter = .all
            }
        } message: {
            Text("Its rules will move to Ungrouped and become enabled after saving. Their global order is preserved.")
        }
        .alert("Delete this entry?", isPresented: $confirmDeleteRule) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                configuration.rules.removeAll { $0.id == deletingRule }
                selectedRule = nil
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            List(selection: $filter) {
                Text("All rules").tag(Filter.all)
                Text("Ungrouped").tag(Filter.ungrouped)
                Section("Rule groups") {
                    ForEach($configuration.ruleGroups) { $group in
                        HStack {
                            Text(verbatim: group.name).lineLimit(2)
                            Spacer(minLength: 4)
                            Text(verbatim: String(configuration.rules.filter { $0.groupID == group.id }.count))
                                .foregroundColor(.secondary).monospacedDigit()
                            Toggle(isOn: $group.enabled) { Text(verbatim: group.name) }
                                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                        }.tag(Filter.group(group.id))
                    }
                }
            }
            if let id = selectedGroupID, let group = configuration.ruleGroups.first(where: { $0.id == id }) {
                TextField("Rule group name", text: Binding(get: {
                    configuration.ruleGroups.first { $0.id == id }?.name ?? group.name
                }, set: { name in
                    if let index = configuration.ruleGroups.firstIndex(where: { $0.id == id }) {
                        configuration.ruleGroups[index].name = name
                    }
                })).textFieldStyle(.roundedBorder).padding(.horizontal, 8)
            }
            HStack {
                Button { addGroup() } label: { Image(systemName: "plus") }
                    .help("Add rule group")
                Button {
                    deletingGroup = selectedGroupID
                    confirmDeleteGroup = true
                } label: { Image(systemName: "minus") }
                    .disabled(selectedGroupID == nil).help("Delete rule group")
                Spacer()
            }.padding(8)
        }
    }

    private var ruleTable: some View {
        Table(visibleRules, selection: $selectedRule) {
            TableColumn("Order") { rule in
                Text(verbatim: String((configuration.rules.firstIndex { $0.id == rule.id } ?? 0) + 1))
                    .monospacedDigit().foregroundColor(ruleColor(rule))
            }.width(40)
            TableColumn("Rule type") { rule in
                Text(verbatim: rule.type).foregroundColor(ruleColor(rule))
            }.width(min: 70, ideal: 90)
            TableColumn("Match") { rule in
                Text(verbatim: rule.value).foregroundColor(ruleColor(rule)).help(rule.value)
            }.width(min: 90, ideal: 150)
            TableColumn("Route to") { rule in
                Text(verbatim: rule.target).foregroundColor(ruleColor(rule)).help(rule.target)
            }.width(min: 70, ideal: 100)
            TableColumn("Rule group") { rule in
                VStack(alignment: .leading, spacing: 2) {
                    if let group = configuration.ruleGroups.first(where: { $0.id == rule.groupID }) {
                        Text(verbatim: group.name)
                        if !group.enabled { Text("Group disabled").font(.caption) }
                    } else {
                        Text("Ungrouped")
                    }
                }.foregroundColor(ruleColor(rule))
            }.width(min: 90, ideal: 130)
        }
    }

    private func ruleColor(_ rule: CustomProxyRule) -> Color {
        configuration.isRuleEnabled(rule) ? .primary : .secondary
    }

    private func addGroup() {
        let base = NSLocalizedString("New rule group", comment: "")
        var name = base
        var suffix = 2
        while configuration.ruleGroups.contains(where: { $0.name == name }) {
            name = "\(base) \(suffix)"
            suffix += 1
        }
        let group = CustomRuleGroup(name: name)
        configuration.ruleGroups.append(group)
        filter = .group(group.id)
        selectedRule = nil
    }

    private func addRule() {
        var rule = CustomProxyRule()
        rule.groupID = selectedGroupID
        configuration.rules.append(rule)
        selectedRule = rule.id
    }

    private func moveRule(_ offset: Int) {
        guard filter == .all, let index = selectedIndex,
              configuration.rules.indices.contains(index + offset) else { return }
        configuration.rules.swapAt(index, index + offset)
    }
}

private struct ProxyRuleForm: View {
    @Binding var rule: CustomProxyRule
    let targets: [String]
    let providers: [String]
    let ruleGroups: [CustomRuleGroup]
    var body: some View {
        Form {
            Picker("Rule group", selection: $rule.groupID) {
                Text("Ungrouped").tag(Optional<UUID>.none)
                ForEach(ruleGroups) { group in
                    Text(verbatim: group.name).tag(Optional(group.id))
                }
            }
            if let group = ruleGroups.first(where: { $0.id == rule.groupID }), !group.enabled {
                Text("Group disabled. This rule stays editable but will not be applied.")
                    .font(.caption).foregroundColor(.secondary)
            }
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
