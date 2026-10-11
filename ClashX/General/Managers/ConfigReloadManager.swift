//
//  ConfigReloadManager.swift
//  ClashX
//

import Cocoa
import RxCocoa
import RxSwift

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
        guard ConfigManager.shared.kernelState.isOperational else { return nil }

        let config = configName ?? ConfigManager.selectConfigName

        ClashProxy.cleanCache()

        guard let composedPath = await ConfigOverride.shared.composeConfig(configName: config) else {
            return "compose config failed"
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
