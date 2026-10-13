//
//  ConfigReloadManager.swift
//  ClashX
//

import Cocoa
import RxCocoa
import RxSwift

/// Serialize the whole read/compose/apply/persist transaction, not just PUT.
/// Nested calls in the same task (for example TUN reconciliation) share ownership.
@MainActor
final class ConfigApplyCoordinator {
    static let shared = ConfigApplyCoordinator()
    @TaskLocal private static var taskOwner: UUID?
    private var owner: UUID?
    private var ownerTaskID: Int?
    private var waiters: [(UUID, CheckedContinuation<Void, Never>)] = []

    func perform<T: Sendable>(_ operation: @MainActor () async throws -> T) async rethrows -> T {
        // Task-local values also propagate to child tasks. Only the original
        // task may re-enter; a spawned callback must wait like any other caller.
        let taskID = withUnsafeCurrentTask { $0?.hashValue }
        if let owner, Self.taskOwner == owner, let taskID, taskID == ownerTaskID {
            return try await operation()
        }
        let token = UUID()
        if owner != nil {
            await withCheckedContinuation { waiters.append((token, $0)) }
        } else {
            owner = token
        }
        ownerTaskID = taskID
        defer {
            ownerTaskID = nil
            if waiters.isEmpty {
                owner = nil
            } else {
                let next = waiters.removeFirst()
                owner = next.0
                next.1.resume()
            }
        }
        return try await Self.$taskOwner.withValue(token) { try await operation() }
    }
}

@MainActor
final class ConfigReloadManager {
    static let shared = ConfigReloadManager()

    private var remoteControlResetTask: Task<Void, Never>?

    private init() {}

    func syncConfig() async {
        guard let config = await ApiRequest.requestConfig() else { return }
        ConfigManager.shared.currentConfig = config
    }

    func resetStreamApi() {
        ApiRequestStream.shared.addObserver(AppDelegate.shared)
        ApiRequestStream.shared.resetStreamApis()
    }

    func resetStreamApiIfRemoteControlEnabled() {
        guard RemoteControlManager.selectConfig != nil else { return }
        resetStreamApi()
    }



    func updateLoggingLevel(menuItems: [NSMenuItem]) async {
        _ = await ApiRequest.updateLogLevel(level: ConfigOverride.shared.logLevel)
        menuItems.forEach {
            $0.state = $0.title.lowercased() == ConfigOverride.shared.logLevel.rawValue ? .on : .off
        }
        NotificationCenter.default.post(name: .reloadDashboard, object: nil)
    }

    func setupRemoteControlStreamResetOnIPAddressChange(disposeBag _: DisposeBag) {
        guard remoteControlResetTask == nil else { return }

        remoteControlResetTask = Task { @MainActor in
            for await _ in NetworkChangeNotifier.ipAddressStream(allowIPV6: false) {
                guard !Task.isCancelled else { return }
                ConfigReloadManager.shared.resetStreamApiIfRemoteControlEnabled()
            }
        }
    }

    @discardableResult
    func updateConfig(configName: String? = nil, showNotification: Bool = true) async -> ErrorString? {
        await AppDelegate.shared.startProxyCore()
        return await ConfigApplyCoordinator.shared.perform {
            await self.applyConfig(configName: configName, showNotification: showNotification)
        }
    }

    private func applyConfig(configName: String?, showNotification: Bool) async -> ErrorString? {
        guard ConfigManager.shared.kernelState.isOperational else {
            return NSLocalizedString("Wait for the core to finish starting or reloading before saving.", comment: "")
        }
        guard RemoteControlManager.selectConfig == nil else {
            return NSLocalizedString("Configuration changed. Please try again.", comment: "")
        }

        let config = configName ?? ConfigManager.selectConfigName

        ClashProxy.cleanCache()

        guard let composedPath = await ConfigOverride.shared.composeConfig(configName: config) else {
            let error = ConfigOverride.shared.compositionError ?? "compose config failed"
            UpdateConfigAction.showError(text: error, configName: config)
            return error
        }

        let err = await ApiRequest.requestConfigUpdate(configPath: composedPath)
        if let err {
            UpdateConfigAction.showError(text: err, configName: config)
            return err
        }

        if let newConfigName = configName {
            ConfigManager.selectConfigName = newConfigName
        }

        await handleClashConfigUpdated()

        if showNotification {
            UserNotificationCenter.shared.post(
                title: NSLocalizedString("Reload Config Succeed", comment: ""),
                info: NSLocalizedString("Success", comment: "")
            )
        }

        return nil
    }

    func handleClashConfigUpdated(isInitialApply: Bool = false, preserveProxyState: Bool = false) async {
        if isInitialApply {
            ConfigManager.shared.kernelState = .reloadingConfig
        }

        let currentConfig = await ApiRequest.requestConfig()
        if let currentConfig {
            ConfigManager.shared.currentConfig = currentConfig
        }

        if preserveProxyState {
            await ProxyManager.shared.syncTunState()
        } else {
            await ProxyManager.shared.reconcileState()
        }

        if isInitialApply {
            await SSIDSuspendTool.shared.setup()
        } else if !preserveProxyState {
            await SSIDSuspendTool.shared.update()
        }

        resetStreamApi()
        await selectProxyGroupWithMemory()
        await MenuItemFactory.recreateProxyMenuItems()
        NotificationCenter.default.post(name: .reloadDashboard, object: nil)

        if isInitialApply {
            ConfigManager.shared.kernelState = .running
        }
    }

    func selectOutBoundModeWithMenory() async {
        _ = await ApiRequest.updateOutBoundMode(mode: ConfigOverride.shared.mode ?? .rule)
        await ConnectionManager.closeAllConnection()
        await syncConfig()
    }

    func removeUnExistProxyGroups() async {
        let action: (([String]) -> Void) = { list in
            let unexists = ConfigManager.selectedProxyRecords.filter {
                !list.contains($0.config)
            }
            ConfigManager.selectedProxyRecords.removeAll {
                unexists.contains($0)
            }
        }

        let list = if ICloudManager.shared.useICloudRelay.value {
            await ICloudManager.shared.getConfigFilesList()
        } else {
            ConfigManager.getConfigFilesList()
        }

        action(list)
    }

    private func selectProxyGroupWithMemory() async {
        let items = [SavedProxyModel](ConfigManager.selectedProxyRecords).filter {
            $0.config == ConfigManager.selectConfigName
        }
        let failedKeys = await withTaskGroup(of: String?.self, returning: [String].self) { group in
            items.forEach { item in
                Logger.log("Auto selecting \(item.group) \(item.selected)", level: .debug)
                let groupName = item.group
                let selected = item.selected
                let itemKey = item.key

                group.addTask {
                    let success = await ApiRequest.updateProxyGroup(group: groupName, selectProxy: selected)
                    return success ? nil : itemKey
                }
            }

            var failedKeys: [String] = []
            for await failedKey in group {
                guard let failedKey else { continue }
                failedKeys.append(failedKey)
            }
            return failedKeys
        }

        guard !failedKeys.isEmpty else { return }
        ConfigManager.selectedProxyRecords.removeAll { model in
            failedKeys.contains(model.key)
        }
    }
}
