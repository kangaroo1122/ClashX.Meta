//
//  ProxyHealthCheckManager.swift
//  ClashX
//

import Cocoa
import Combine
import RxCocoa
import RxSwift

@MainActor
final class ProxyHealthCheckManager {
    static let shared = ProxyHealthCheckManager()

    private var isSpeedTesting = false
    private var ipAddressChangeTask: Task<Void, Never>?

    private init() {}

    func healthCheck(proxy name: ClashProxyName) async {
        await ApiRequest.healthCheck(proxy: name)
    }

    func getGroupDelay(groupName: ClashProxyName) async -> [String: Int] {
        if let delays = await CustomProxyHealth.shared.testGroup(named: groupName) { return delays }
        return await ApiRequest.getGroupDelay(groupName: groupName)
    }

    func healthCheckOnNetworkChange() async {
        let proxyResp = await ApiRequest.getMergedProxyData()
        let groups = proxyResp.proxyGroups.filter(\.type.isAutoGroup)
        var providers = Set<ClashProxyName>()

        groups.forEach { group in
            group.all?.compactMap {
                proxyResp.proxiesMap[$0]?.enclosingProvider?.name
            }.forEach {
                providers.insert($0)
            }
        }

        for group in groups {
            Logger.log("Start auto health check for group \(group.name)")
            await healthCheck(proxy: group.name)
        }

        for provider in providers {
            Logger.log("Start auto health check for provider \(provider)")
            await healthCheck(proxy: provider)
        }
    }

    func setupHealthCheckOnIPAddressChange(disposeBag _: DisposeBag) {
        guard ipAddressChangeTask == nil else { return }

        ipAddressChangeTask = Task { @MainActor in
            var previousIPAddress = NetworkChangeNotifier.getPrimaryIPAddress(allowIPV6: false)
            var debounceTask: Task<Void, Never>?

            defer {
                debounceTask?.cancel()
            }

            for await currentIPAddress in NetworkChangeNotifier.ipAddressStream(allowIPV6: false) {
                guard !Task.isCancelled else { return }
                guard let currentIPAddress, currentIPAddress != previousIPAddress else { continue }

                previousIPAddress = currentIPAddress
                debounceTask?.cancel()
                debounceTask = Task { @MainActor in
                    try? await Task.sleep(seconds: 5)
                    guard !Task.isCancelled else { return }
                    await ProxyHealthCheckManager.shared.healthCheckOnNetworkChange()
                }
            }
        }
    }

    func runSpeedTest() async {
        if isSpeedTesting {
            UserNotificationCenter.shared.postSpeedTestingNotice()
            return
        }

        UserNotificationCenter.shared.postSpeedTestBeginNotice()
        isSpeedTesting = true
        defer {
            UserNotificationCenter.shared.postSpeedTestFinishNotice()
            isSpeedTesting = false
        }

        let resp = await ApiRequest.getMergedProxyData()
        let custom = CustomProxyHealth.shared.activeConfiguration
        let customNames = Set((custom?.proxies.map(\.runtimeName) ?? []) + (custom?.groups.map { "[Local] " + $0.name } ?? []))

        await withTaskGroup(of: Void.self) { group in
            resp.enclosingProviderResp?.providers.forEach { name, _ in
                group.addTask {
                    await self.healthCheck(proxy: name)
                }
            }

            resp.proxiesMap["GLOBAL"]?.all?.filter { !customNames.contains($0) }.forEach { proxy in
                group.addTask {
                    _ = await ApiRequest.getProxyDelay(proxyName: proxy)
                }
            }
            // Test every saved local node, even without a proxy group. Do not
            // test local groups again with the global URL and overwrite results.
            group.addTask { await CustomProxyHealth.shared.testAll() }
        }
        await MenuItemFactory.refreshExistingMenuItems()
    }
}

@MainActor
final class CustomProxyHealth: ObservableObject {
    static let shared = CustomProxyHealth()

    struct Result {
        let proxy: CustomProxyEntry
        let url: String
        let delay: Int?
        let checkedAt: Date
    }

    @Published private(set) var results: [UUID: Result] = [:]
    @Published private(set) var testing = Set<UUID>()
    @Published private var appliedConfiguration: CustomProxyConfiguration?
    @Published private var isApplyingConfiguration = false
    private var tasks: [UUID: Task<Int?, Never>] = [:]
    private var generation = 0
    private let bag = DisposeBag()

    private init() {
        ConfigManager.shared.kernelStateRelay.observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] state in
                if state != .running { self?.invalidate() }
                // Connectivity is not process lifetime: the stream can lose
                // contact with either a local or a remote core temporarily.
                switch state {
                case .stopped, .failedToStart, .checkingLaunchPath, .checkingHelper, .preparingConfig, .starting:
                    self?.setAppliedConfiguration(nil)
                    ConfigOverride.shared.forgetAppliedConfig()
                case .disconnected, .reloadingConfig, .running:
                    break
                }
            }).disposed(by: bag)
        NotificationCenter.default.rx.notification(TunStackSettings.remoteControlChanged)
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] _ in self?.invalidate() }).disposed(by: bag)
    }

    var activeConfiguration: CustomProxyConfiguration? {
        guard !isApplyingConfiguration, RemoteControlManager.selectConfig == nil, ConfigManager.shared.kernelState == .running,
              let config = appliedConfiguration, config.enabled else { return nil }
        return config
    }

    func setAppliedConfiguration(_ config: CustomProxyConfiguration?) {
        appliedConfiguration = config
        invalidate()
    }

    func beginConfigurationUpdate() {
        // Stop tests while applying, but retain the last confirmed configuration
        // if the core rejects the candidate. Only success replaces that record.
        isApplyingConfiguration = true
        invalidate()
    }

    func endConfigurationUpdate() {
        isApplyingConfiguration = false
        MenuItemFactory.refreshCustomProxyStatusMenu()
    }

    func hasApplied(_ config: CustomProxyConfiguration) -> Bool {
        !isApplyingConfiguration && RemoteControlManager.selectConfig == nil && ConfigManager.shared.kernelState == .running
            && appliedConfiguration == config
    }

    func savedProxy(named name: String) -> CustomProxyEntry? {
        activeConfiguration?.proxies.first { $0.runtimeName == name }
    }

    func effectiveURL(_ proxy: CustomProxyEntry) -> String {
        if let url = proxy.testURL, !url.isEmpty { return url }
        return ConfigManager.shared.benchMarkUrl
    }

    func invalidate() {
        generation += 1
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        testing.removeAll()
        results.removeAll()
    }

    func canTest(_ proxy: CustomProxyEntry) -> Bool {
        savedProxy(named: proxy.runtimeName) == proxy && CustomProxyConfiguration.validURL(effectiveURL(proxy))
    }

    func result(for proxy: CustomProxyEntry) -> Result? {
        guard canTest(proxy), let result = results[proxy.id], result.proxy == proxy,
              result.url == effectiveURL(proxy) else { return nil }
        return result
    }

    func statusText(for proxy: CustomProxyEntry) -> String {
        guard canTest(proxy) else { return NSLocalizedString("Save and apply to a running local core to test.", comment: "") }
        if testing.contains(proxy.id) { return NSLocalizedString("Testing", comment: "") }
        guard let result = result(for: proxy) else { return NSLocalizedString("Not tested", comment: "") }
        return result.delay.map { "\($0) ms" } ?? NSLocalizedString("Test failed or timed out", comment: "")
    }

    @discardableResult
    func test(_ proxy: CustomProxyEntry) async -> Int? {
        guard canTest(proxy) else { return nil }
        if let task = tasks[proxy.id] { return await task.value }
        let currentGeneration = generation
        let url = effectiveURL(proxy)
        testing.insert(proxy.id)
        results.removeValue(forKey: proxy.id)
        MenuItemFactory.refreshCustomProxyStatusMenu()
        let task = Task<Int?, Never> {
            // Confirm it exists in the current core before calling its delay API.
            let response = await ApiRequest.getMergedProxyData()
            guard !Task.isCancelled, currentGeneration == self.generation,
                  self.canTest(proxy), response.proxiesMap[proxy.runtimeName] != nil else { return nil }
            return await ApiRequest.requestProxyDelay(proxyName: proxy.runtimeName, url: url, timeout: 5000)
        }
        tasks[proxy.id] = task
        let delay = await task.value
        guard currentGeneration == generation else { return nil }
        tasks.removeValue(forKey: proxy.id)
        testing.remove(proxy.id)
        guard canTest(proxy), effectiveURL(proxy) == url, !task.isCancelled else { return nil }
        results[proxy.id] = Result(proxy: proxy, url: url, delay: delay, checkedAt: Date())
        MenuItemFactory.refreshCustomProxyStatusMenu()
        NotificationCenter.default.post(name: .speedTestFinishForProxy, object: nil, userInfo: [
            "proxyName": proxy.runtimeName, "delay": delay.map { "\($0) ms" } ?? NSLocalizedString("fail", comment: ""),
            "rawValue": delay ?? 0
        ])
        return delay
    }

    func testAll() async {
        guard let config = activeConfiguration else { return }
        await testNodes(config.proxies)
    }

    private func testNodes(_ proxies: [CustomProxyEntry]) async {
        let startGeneration = generation
        // Bound concurrency so a large work configuration does not flood the core.
        for start in stride(from: 0, to: proxies.count, by: 4) {
            guard !Task.isCancelled, startGeneration == generation else { return }
            await withTaskGroup(of: Void.self) { group in
                for proxy in proxies[start..<min(start + 4, proxies.count)] {
                    group.addTask { _ = await self.test(proxy) }
                }
            }
        }
    }

    /// For local groups, test leaf nodes with their own URLs, including nested
    /// groups. Leave automatic fallback health checks to the core's group URL.
    func testGroup(named name: String) async -> [String: Int]? {
        guard let config = activeConfiguration,
              let root = config.groups.first(where: { "[Local] " + $0.name == name }) else { return nil }
        let startGeneration = generation
        var visited = Set<String>()
        var nodes: [CustomProxyEntry] = []
        func collect(_ member: String) {
            guard visited.insert(member).inserted else { return }
            if let proxy = config.proxies.first(where: { $0.name == member }) { nodes.append(proxy) }
            else if let group = config.groups.first(where: { $0.name == member }) { group.members.forEach(collect) }
        }
        root.members.forEach(collect)
        await testNodes(nodes)
        guard startGeneration == generation else { return [:] }
        var delays = Dictionary(uniqueKeysWithValues: nodes.compactMap { proxy -> (String, Int)? in
            guard let delay = result(for: proxy)?.delay else { return nil }
            return (proxy.runtimeName, delay)
        })
        if visited.contains("DIRECT") {
            let url = root.type == "select" ? ConfigManager.shared.benchMarkUrl : root.url
            if let delay = await ApiRequest.requestProxyDelay(proxyName: "DIRECT", url: url, timeout: 5000) {
                delays["DIRECT"] = delay
            }
        }
        let response = await ApiRequest.getMergedProxyData()
        guard startGeneration == generation else { return [:] }
        // A nested group's displayed delay is its currently selected leaf's
        // result, rather than a failed test for an unmeasured group name.
        func selectedDelay(_ runtimeName: String, seen: Set<String>) -> Int? {
            if let delay = delays[runtimeName] { return delay }
            guard !seen.contains(runtimeName), let selected = response.proxiesMap[runtimeName]?.now else { return nil }
            return selectedDelay(selected, seen: seen.union([runtimeName]))
        }
        for member in root.members where member != "DIRECT" && member != "REJECT" {
            let runtimeName = "[Local] " + member
            if let delay = selectedDelay(runtimeName, seen: []) { delays[runtimeName] = delay }
        }
        return delays
    }
}
