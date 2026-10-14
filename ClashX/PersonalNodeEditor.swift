import AppKit
import SwiftUI
import Yams
import RxSwift
import RxCocoa

@MainActor
final class PersonalNodeRuntime: ObservableObject {
    static let shared = PersonalNodeRuntime()
    @Published private(set) var configuration: PersonalNodeConfiguration?
    @Published private var delays: [UUID: String] = [:]
    @Published private var testing = Set<UUID>()
    @Published private(set) var isUpdating = false
    private var names = Set<String>()
    private var configName = ""
    private var generation = UUID()
    private let disposeBag = DisposeBag()

    private init() {
        ConfigManager.shared.kernelStateRelay.observe(on: MainScheduler.instance).subscribe(onNext: { [weak self] state in
            if state == .disconnected {
                self?.invalidateTests()
            } else if !state.isOperational {
                self?.record(nil)
            } else {
                // Publish recovery even when the retained configuration is unchanged.
                self?.objectWillChange.send()
            }
        }).disposed(by: disposeBag)
        // Switching the controller does not unload the local core configuration.
        // Invalidate outstanding results but retain the snapshot for returning locally.
        NotificationCenter.default.rx.notification(TunStackSettings.remoteControlChanged)
            .observe(on: MainScheduler.instance).subscribe(onNext: { [weak self] _ in self?.invalidateTests() })
            .disposed(by: disposeBag)
    }

    func beginUpdate() {
        isUpdating = true
        invalidateTests()
    }

    private func invalidateTests() {
        generation = UUID()
        delays = [:]; testing = []
    }

    func endUpdate() { isUpdating = false }

    func record(_ snapshot: ConfigOverride.AppliedSnapshot?) {
        generation = UUID()
        configuration = snapshot?.personal
        configName = snapshot?.configName ?? ""
        names = []
        if let yaml = snapshot?.yaml,
           let mapping = try? Yams.load(yaml: yaml) as? [String: Any],
           let rows = mapping["proxies"] as? [[String: Any]] {
            names = Set(rows.compactMap { $0["name"] as? String })
        }
        delays = [:]
        testing = []
    }

    private func isApplied(_ node: PersonalNode) -> Bool {
        !isUpdating && RemoteControlManager.selectConfig == nil && ConfigManager.shared.kernelState == .running
            && configName == ConfigManager.selectConfigName && names.contains(node.runtimeName)
            && configuration?.nodes.contains(node) == true
    }

    func canTest(_ node: PersonalNode) -> Bool {
        isApplied(node) && !testing.contains(node.id)
    }

    func isTesting(_ node: PersonalNode) -> Bool {
        isApplied(node) && testing.contains(node.id)
    }

    func delay(for node: PersonalNode) -> String? {
        isApplied(node) ? delays[node.id] : nil
    }

    func test(_ node: PersonalNode) async {
        guard canTest(node) else { return }
        let expected = generation
        testing.insert(node.id)
        let result = await ApiRequest.requestProxyDelay(proxyName: node.runtimeName, url: ConfigManager.shared.benchMarkUrl, timeout: 5000)
        guard expected == generation else { return }
        testing.remove(node.id)
        guard canTest(node) else { return }
        delays[node.id] = result.map { "\($0) ms" } ?? NSLocalizedString("Test failed or timed out", comment: "")
    }
}

struct PersonalNodeGroupCatalog: Identifiable {
    struct Group: Identifiable {
        let name: String
        let type: String
        var id: String { name }
        var title: String {
            switch type {
            case "select": return NSLocalizedString("Manual selection", comment: "")
            case "fallback": return NSLocalizedString("Automatic fallback", comment: "")
            case "url-test": return NSLocalizedString("Lowest latency", comment: "")
            default: return NSLocalizedString("Load balancing", comment: "")
            }
        }
    }
    let name: String
    var groups: [Group] = []
    var error: String?
    var id: String { name }
}

@MainActor
final class PersonalNodeEditor: ObservableObject {
    static let shared = PersonalNodeEditor()
    @Published var draft = PersonalNodeConfiguration()
    @Published private(set) var saved = PersonalNodeConfiguration()
    @Published private(set) var isSaving = false
    @Published private(set) var loadFailed = false
    @Published private(set) var message = ""
    @Published private(set) var isError = false
    @Published private(set) var catalog: [PersonalNodeGroupCatalog] = []
    private var catalogGeneration = UUID()
    var isDirty: Bool { draft != saved }

    init() { reload() }

    func report(_ text: String, error: Bool = false) { message = text; isError = error }

    func updateNode(_ node: PersonalNode) {
        guard !isSaving, let index = draft.nodes.firstIndex(where: { $0.id == node.id }) else { return }
        let previous = draft.nodes[index]
        var updated = draft
        updated.nodes[index] = node
        if previous.name != node.name {
            // Resolve against the draft before the rename, including unsaved imports.
            // Both the form and YAML editor use this same update path.
            for i in updated.nodes.indices {
                let reference = updated.nodes[i].text("dialer-proxy")
                guard !reference.isEmpty else { continue }
                if i == index, reference != previous.text("dialer-proxy") { continue }
                let matches = draft.nodes.filter { $0.name == reference || $0.runtimeName == reference }
                guard matches.count == 1, matches[0].id == node.id else { continue }
                updated.nodes[i].setText("dialer-proxy", node.runtimeName)
            }
        }
        draft = updated
    }

    func deleteNode(_ id: UUID) -> Bool {
        guard !isSaving, let node = draft.nodes.first(where: { $0.id == id }) else { return false }
        let hasReplacement = draft.nodes.contains {
            $0.id != id && $0.enabled && $0.name == node.name
        }
        let isReferenced = draft.nodes.contains { other in
            let reference = other.text("dialer-proxy")
            guard other.id != id, !reference.isEmpty else { return false }
            // An exact runtime reference belongs to this node. A name reference
            // can survive deleting a duplicate if an enabled replacement remains.
            return reference == node.runtimeName || (reference == node.name && !hasReplacement)
        }
        guard !isReferenced else {
            report(NSLocalizedString("This personal node is still referenced. Update or remove its dialer-proxy references before deleting it.", comment: ""), error: true)
            return false
        }
        draft.nodes.removeAll { $0.id == id }
        return true
    }

    func reload() {
        guard !isSaving else { return }
        do {
            let value = try PersonalNodeStorage.load()
            draft = value; saved = value; loadFailed = false
            report("")
        } catch { loadFailed = true; report(error.localizedDescription, error: true) }
    }

    func refreshCatalog() async {
        let token = UUID()
        catalogGeneration = token
        var names = Set(ConfigManager.getConfigFilesList() + RemoteConfigManager.shared.configs.map(\.name) + [ConfigManager.selectConfigName])
        for node in draft.nodes { names.formUnion(node.associations.keys) }
        if ICloudManager.shared.useICloudRelay.value, let directory = await ICloudManager.shared.getUrl(),
           let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            names.formUnion(urls.filter { $0.pathExtension == "yaml" }.map { $0.deletingPathExtension().lastPathComponent })
        }
        var result: [PersonalNodeGroupCatalog] = []
        for name in names.sorted() {
            var entry = PersonalNodeGroupCatalog(name: name)
            if let path = await ConfigManager.getConfigPath(configName: name),
               let text = try? String(contentsOfFile: path, encoding: .utf8),
               let base = try? Yams.load(yaml: text) as? [String: Any] {
                if let groups = base["proxy-groups"] as? [[String: Any]] {
                    var seen = Set<String>()
                    entry.groups = groups.compactMap { group in
                        guard let name = group["name"] as? String, let type = group["type"] as? String,
                              ["select", "url-test", "fallback", "load-balance"].contains(type), seen.insert(name).inserted else { return nil }
                        return .init(name: name, type: type)
                    }
                } else if let value = base["proxy-groups"], !(value is NSNull) {
                    entry.error = NSLocalizedString("Unable to read strategy groups.", comment: "")
                }
            } else { entry.error = NSLocalizedString("Configuration is missing or unreadable.", comment: "") }
            result.append(entry)
        }
        guard token == catalogGeneration else { return }
        catalog = result
    }

    func save() async {
        guard !isSaving, !loadFailed else { return }
        isSaving = true
        defer { isSaving = false }
        let candidate = draft
        await ConfigApplyCoordinator.shared.perform { await self.apply(candidate) }
    }

    func recover() async {
        guard loadFailed, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let backup = try await ConfigApplyCoordinator.shared.perform {
                let source = PersonalNodeStorage.url
                let backup = source.deletingLastPathComponent().appendingPathComponent("personal-nodes-backup-\(UUID().uuidString).json")
                try CustomProxyStorage.writePrivateFile(Data(contentsOf: source), to: backup)
                try PersonalNodeStorage.save(PersonalNodeConfiguration())
                self.draft = PersonalNodeConfiguration(); self.saved = self.draft; self.loadFailed = false
                PersonalNodeRuntime.shared.record(nil)
                return backup
            }
            report(NSLocalizedString("Personal nodes reset. Original file backed up to:", comment: "") + " " + backup.path)
            if RemoteControlManager.selectConfig == nil,
               let error = await ConfigReloadManager.shared.updateConfig(showNotification: false) { report(error, error: true) }
        } catch { report(error.localizedDescription, error: true) }
    }

    private func validateReferences(_ candidate: PersonalNodeConfiguration) throws {
        // Rename propagation belongs to updateNode. Saving must not reinterpret
        // a reference that now resolves to another node in the current draft.
        for index in candidate.nodes.indices {
            let reference = candidate.nodes[index].text("dialer-proxy")
            guard !reference.isEmpty else { continue }
            // Keep the deleted-dependency check for unchanged saved references.
            guard let old = saved.nodes.first(where: { $0.id == candidate.nodes[index].id }),
                  old.text("dialer-proxy") == reference else { continue }
            let previous = saved.nodes.filter { $0.name == reference || $0.runtimeName == reference }
            guard previous.count == 1 else { continue }
            if !candidate.nodes.contains(where: { $0.id == previous[0].id }) {
                // A replacement with the same name can still satisfy the reference.
                // Otherwise, do not silently turn a deleted local dependency into
                // an unchecked external reference, even for an inactive configuration.
                if candidate.nodes.contains(where: { $0.name == reference || $0.runtimeName == reference }) { continue }
                throw CustomProxyError("A deleted personal node is still referenced. Update or remove its dialer-proxy references before saving.")
            }
        }
    }

    private func acceptSaved(_ candidate: PersonalNodeConfiguration) {
        var renamed: [String: String] = [:]
        for old in saved.nodes {
            if let node = candidate.nodes.first(where: { $0.id == old.id }), node.runtimeName != old.runtimeName {
                renamed[old.runtimeName] = node.runtimeName
            }
        }
        // Migrate all local configuration selections only after persistence succeeds.
        if !renamed.isEmpty {
            ConfigManager.selectedProxyRecords = ConfigManager.selectedProxyRecords.map { record in
                SavedProxyModel(group: record.group, selected: renamed[record.selected] ?? record.selected, config: record.config)
            }
        }
        saved = candidate
        draft = candidate
    }

    private func apply(_ candidate: PersonalNodeConfiguration) async {
        do {
            try validateReferences(candidate)
            try candidate.validateForSave()
            let state = ConfigManager.shared.kernelState
            if RemoteControlManager.selectConfig != nil || state == .stopped || state == .failedToStart {
                try PersonalNodeStorage.save(candidate)
                acceptSaved(candidate)
                report(NSLocalizedString("Saved. Personal nodes apply the next time a local configuration is loaded.", comment: ""))
                return
            }
            guard state == .running else { throw CustomProxyError("Wait for the core to finish starting or reloading before saving.") }
            let name = ConfigManager.selectConfigName
            let generation = ConfigOverride.shared.runtimeGeneration
            func stillCurrent(allowDisconnected: Bool = false) -> Bool {
                let state = ConfigManager.shared.kernelState
                return RemoteControlManager.selectConfig == nil && ConfigManager.selectConfigName == name
                    && ConfigOverride.shared.runtimeGeneration == generation
                    && (state == .running || (allowDisconnected && state == .disconnected))
            }
            guard let current = await ApiRequest.requestConfig(), stillCurrent() else {
                throw CustomProxyError("Unable to read the current core configuration.")
            }
            let rollback = try ConfigOverride.shared.prepareRollback(tunEnabled: current.tun.enable)
            defer { if let rollback { ConfigOverride.shared.discardPreparedConfig(path: rollback) } }
            guard let path = await ConfigOverride.shared.composeConfig(configName: name, tunEnabled: current.tun.enable, personal: candidate) else {
                throw CustomProxyError(ConfigOverride.shared.compositionError ?? "Unable to compose personal nodes.")
            }
            defer { ConfigOverride.shared.discardPreparedConfig(path: path) }
            guard stillCurrent() else { throw CustomProxyError("Configuration changed. Please try again.") }
            let error = await ApiRequest.requestConfigUpdate(configPath: path)
            guard stillCurrent(allowDisconnected: true) else { throw CustomProxyError("Configuration changed. Please try again.") }
            do {
                if let error { throw CustomProxyError(error) }
                try PersonalNodeStorage.save(candidate)
            } catch {
                let original = error.localizedDescription
                guard let rollback else {
                    throw CustomProxyError(original + "\n" + NSLocalizedString("No previously applied configuration is available for rollback. Reload a working subscription.", comment: ""))
                }
                if let failure = await ApiRequest.requestConfigUpdate(configPath: rollback) {
                    throw CustomProxyError(original + "\n" + NSLocalizedString("Unable to restore the previous configuration:", comment: "") + " " + failure)
                }
                if stillCurrent() { await ConfigReloadManager.shared.handleClashConfigUpdated(preserveProxyState: true) }
                throw CustomProxyError(original)
            }
            acceptSaved(candidate)
            if stillCurrent() { await ConfigReloadManager.shared.handleClashConfigUpdated(preserveProxyState: true) }
            report(NSLocalizedString("Personal nodes saved and applied. Only enabled nodes with matching strategy groups are loaded.", comment: ""))
            await refreshCatalog()
        } catch { report(error.localizedDescription, error: true) }
    }
}
