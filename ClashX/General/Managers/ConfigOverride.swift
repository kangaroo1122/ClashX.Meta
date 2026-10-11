//
//  ConfigOverride.swift
//  ClashX
//

import Foundation
import Combine
import RxCocoa
import RxSwift
import Yams

enum TunStack: String, CaseIterable {
    case followConfig = ""
    case mips, mixed, system, gvisor

    var title: String {
        switch self {
        case .followConfig: return NSLocalizedString("Follow configuration", comment: "TUN stack")
        case .mips: return "MIPS"
        case .mixed: return "Mixed"
        case .system: return "System"
        case .gvisor: return "gVisor"
        }
    }
}

final class ConfigOverride {
    static let shared = ConfigOverride()

    private init() {}

    // MARK: - Always Override

    var logLevel: ClashLogLevel {
        get { ClashLogLevel(rawValue: UserDefaults.standard.string(forKey: "selectLoggingApiLevel") ?? "") ?? .info }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "selectLoggingApiLevel") }
    }

    // MARK: - Optional Override

    var allowLan: Bool? {
        get { UserDefaults.standard.object(forKey: "allowConnectFromLan") as? Bool }
        set {
            if let v = newValue {
                UserDefaults.standard.set(v, forKey: "allowConnectFromLan")
            } else {
                UserDefaults.standard.removeObject(forKey: "allowConnectFromLan")
            }
        }
    }

    var mode: ClashProxyMode {
        get { ClashProxyMode(rawValue: UserDefaults.standard.string(forKey: "selectOutBoundMode") ?? "") ?? .rule }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "selectOutBoundMode") }
    }

    // MARK: - Forced Default Override

    var snifferEnable: Bool? {
        get { UserDefaults.standard.object(forKey: "overrideSnifferEnable") as? Bool }
        set {
            if let v = newValue {
                UserDefaults.standard.set(v, forKey: "overrideSnifferEnable")
            } else {
                UserDefaults.standard.removeObject(forKey: "overrideSnifferEnable")
            }
        }
    }

    @MainActor
    var tunEnable: Bool? {
        let intent = ProxyManager.shared.state.intent
        return intent.tunOverridden ? intent.tunEnabled : nil
    }

    var tunStack: TunStack {
        get { TunStack(rawValue: UserDefaults.standard.string(forKey: "overrideTunStack") ?? "") ?? .followConfig }
        set {
            if newValue == .followConfig {
                UserDefaults.standard.removeObject(forKey: "overrideTunStack")
            } else {
                UserDefaults.standard.set(newValue.rawValue, forKey: "overrideTunStack")
            }
        }
    }

    func composeConfig(configName: String, stack: TunStack? = nil, tunEnabled: Bool? = nil) async -> String? {
        guard let configPath = await ApiRequest.findConfigPath(configName: configName),
              let yamlString = readFileString(configPath),
              var yaml = try? Yams.compose(yaml: yamlString) else {
            return nil
        }

        await applyOverrides(&yaml, stack: stack)
        if let tunEnabled {
            yaml["tun"]!["enable"] = .init("\(tunEnabled)")
        }

        guard let result = try? Yams.serialize(node: yaml),
              let path = RemoteConfigManager.createCacheConfig(string: result) else {
            return nil
        }
        return path
    }

    @MainActor
    func applyOverrides(_ yaml: inout Node, stack: TunStack? = nil) {
        if let allowLan = allowLan {
            yaml["allow-lan"] = .init("\(allowLan)")
        }
        yaml["mode"] = .init(mode.rawValue)
        yaml["log-level"] = .init(logLevel.rawValue)

        applySnifferOverride(&yaml)
        applyTunOverride(&yaml)
        let selectedStack = stack ?? tunStack
        if selectedStack != .followConfig {
            yaml["tun"]!["stack"] = .init(selectedStack.rawValue)
        }
    }

    private func applySnifferOverride(_ yaml: inout Node) {
        if yaml["sniffer"] != nil {
            if let snifferEnable = snifferEnable {
                yaml["sniffer"]!["enable"] = .init("\(snifferEnable)")
            }
        } else {
            yaml["sniffer"] = [
                "enable": .init("\(snifferEnable ?? false)"),
                "sniff": [
                    "HTTP": [
                        "ports": ["80", "8080-8880"],
                        "override-destination": "true",
                    ],
                    "TLS": [
                        "ports": ["443", "8443"],
                    ],
                    "QUIC": [
                        "ports": ["443", "8443"],
                    ],
                ],
                "skip-domain": [
                    "Mijia Cloud",
                    "+.push.apple.com",
                ],
            ]
        }
    }

    @MainActor
    private func applyTunOverride(_ yaml: inout Node) {
        if yaml["tun"] != nil {
            if let tunEnable = tunEnable {
                yaml["tun"]!["enable"] = .init("\(tunEnable)")
            }
        } else {
            yaml["tun"] = [
                "enable": .init("\(tunEnable ?? false)"),
                "auto-route": "true",
                "auto-detect-interface": "true",
                "dns-hijack": [
                    "any:53",
                    "tcp://any:53"
                ],
            ]
        }
    }

    private func readFileString(_ path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Shared by the preferences window and the native dashboard.
@MainActor
final class TunStackSettings: ObservableObject {
    static let shared = TunStackSettings()
    nonisolated static let remoteControlChanged = Notification.Name("TunStackRemoteControlChanged")

    @Published private(set) var selection = ConfigOverride.shared.tunStack
    @Published private(set) var isApplying = false
    @Published private(set) var isRemote = RemoteControlManager.selectConfig != nil
    @Published private(set) var currentStack: String?
    @Published private(set) var kernelReady = false
    @Published private(set) var errorMessage: String?
    private let disposeBag = DisposeBag()

    private init() {
        ConfigManager.shared.currentConfigRelay
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] config in
                self?.currentStack = config?.tun.stack
            }).disposed(by: disposeBag)
        ConfigManager.shared.kernelStateRelay
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] state in
                self?.kernelReady = state == .running
                if !state.isOperational { self?.currentStack = nil }
            }).disposed(by: disposeBag)
        NotificationCenter.default.rx.notification(Self.remoteControlChanged)
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] _ in
                self?.isRemote = RemoteControlManager.selectConfig != nil
                self?.currentStack = nil
                self?.errorMessage = nil
            }).disposed(by: disposeBag)
    }

    var canEdit: Bool {
        !isRemote && !isApplying && (kernelReady || ConfigManager.shared.kernelState == .stopped || ConfigManager.shared.kernelState == .failedToStart)
    }

    func select(_ stack: TunStack) async {
        guard canEdit, stack != selection else { return }
        errorMessage = nil
        guard kernelReady else {
            ConfigOverride.shared.tunStack = stack
            selection = stack
            return
        }

        isApplying = true
        defer { isApplying = false }
        let name = ConfigManager.selectConfigName
        let previous = selection
        // Read the actual enable state: changing the stack must never enable TUN.
        guard let current = await ApiRequest.requestConfig(),
              let path = await ConfigOverride.shared.composeConfig(configName: name, stack: stack, tunEnabled: current.tun.enable),
              let rollbackPath = await ConfigOverride.shared.composeConfig(configName: name, stack: previous, tunEnabled: current.tun.enable) else {
            errorMessage = NSLocalizedString("Unable to prepare TUN configuration.", comment: "")
            return
        }
        guard RemoteControlManager.selectConfig == nil, ConfigManager.selectConfigName == name,
              ConfigManager.shared.kernelState == .running else {
            errorMessage = NSLocalizedString("Configuration changed. Please try again.", comment: "")
            return
        }

        var applyError = await ApiRequest.requestConfigUpdate(configPath: path)
        if applyError == nil, RemoteControlManager.selectConfig == nil, ConfigManager.selectConfigName == name {
            if let applied = await ApiRequest.requestConfig() {
                ConfigManager.shared.currentConfig = applied
                if stack != .followConfig && applied.tun.stack.lowercased() != stack.rawValue {
                    applyError = NSLocalizedString("The core did not apply the selected TUN stack.", comment: "")
                }
            } else {
                applyError = NSLocalizedString("Unable to verify the TUN configuration.", comment: "")
            }
        }
        if let error = applyError {
            errorMessage = error
            // An unsuccessful reload may have partially applied the configuration.
            if RemoteControlManager.selectConfig == nil, ConfigManager.selectConfigName == name {
                if let rollbackError = await ApiRequest.requestConfigUpdate(configPath: rollbackPath) {
                    errorMessage = error + "\n" + NSLocalizedString("Unable to restore TUN configuration:", comment: "") + " " + rollbackError
                }
                await ConfigReloadManager.shared.handleClashConfigUpdated(preserveProxyState: true)
            }
            return
        }

        ConfigOverride.shared.tunStack = stack
        selection = stack
        if RemoteControlManager.selectConfig == nil, ConfigManager.selectConfigName == name {
            await ConfigReloadManager.shared.handleClashConfigUpdated(preserveProxyState: true)
        }
    }
}
