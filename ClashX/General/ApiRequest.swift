//
//  ApiRequest.swift
//  ClashX
//
//  Created by CYC on 2018/7/30.
//  Copyright © 2018年 yichengchen. All rights reserved.
//

import Cocoa

import SwiftyJSON
import Foundation
import NIOHTTP1
import NIOCore

typealias ErrorString = String

struct ClashVersion: Decodable {
	let version: String
	let meta: Bool?
}

class ApiRequest {
    static let shared = ApiRequest()

    private var proxyRespCache: ClashProxyResp?
    
    private lazy var logQueue = DispatchQueue(label: "com.ClashX.core.log")

    @objc enum ProviderType: Int {
        case rule, proxy

        func apiString() -> String {
            self == .proxy ? "proxies" : "rules"
        }

        func logString() -> String {
            self == .proxy ? "Proxy" : "Rule"
        }
    }

    private init() {
    }

    @discardableResult
    private static func req(
        _ url: String,
        method: HTTPMethod = .GET,
        parameters: [String: Any]? = nil,
        encoding: ApiParameterEncoding = .default,
        requiresCoreRunning: Bool = true,
        timeout: TimeAmount? = nil
    ) async -> ApiRequestTransport.Handle {
        await ApiRequestTransport.req(
            url,
            method: method,
            parameters: parameters,
            encoding: encoding,
            requiresCoreRunning: requiresCoreRunning,
            timeout: timeout
        )
    }

    static func findConfigPath(configName: String) async -> String? {
        if ICloudManager.shared.useICloudRelay.value {
            guard let url = await ICloudManager.shared.getUrl() else {
                return nil
            }
            return url.appendingPathComponent(Paths.configFileName(for: configName)).path
        } else {
            return Paths.localConfigPath(for: configName)
        }
    }

    private static func flushFakeipCacheResult() async -> Bool {
        Logger.log("FlushFakeipCache")

        let success: Bool

        let response = await req("/cache/fakeip/flush", method: .POST)
            .response
        success = response.httpResponse?.statusCode == 204

        Logger.log("FlushFakeipCache \(success ? "success" : "failed")")
        return success
    }

    private static func flushDNSCacheResult() async -> Bool {
        Logger.log("FlushDNSCache")

        let success: Bool

        let response = await req("/cache/dns/flush", method: .POST)
            .response
        success = response.httpResponse?.statusCode == 204

        Logger.log("FlushDNSCache \(success ? "success" : "failed")")
        return success
    }

    static func requestVersion(timeout: TimeAmount? = nil) async -> ClashVersion? {
        do {
            return try await req("/version", requiresCoreRunning: false, timeout: timeout)
                .validate()
                .responseDecodable(ClashVersion.self)
        } catch {
            Logger.log("Request Version failed, \(error)", level: .error)
            return nil
        }
    }

    static func requestConfig() async -> ClashConfig? {
        do {
            return try await req("/configs")
                .validate()
                .responseDecodable(ClashConfig.self)
        } catch {
            Logger.log(error.localizedDescription)
            await MainActor.run {
                UserNotificationCenter.shared.post(title: "Error", info: error.localizedDescription)
            }
            return nil
        }
    }

    static func requestConfigUpdate(configName: String) async -> ErrorString? {
        return await ConfigApplyCoordinator.shared.perform {
            await requestConfigUpdateSeriallyConfigName(configName: configName)
        }
    }

    private static func requestConfigUpdateSeriallyConfigName(configName: String) async -> ErrorString? {
        guard let path = await findConfigPath(configName: configName) else {
            return "icloud error"
        }

        guard ICloudManager.shared.useICloudRelay.value else {
            return await requestConfigUpdate(configPath: path)
        }

        #warning("icloud operation not permitted")

        let tempPath = Paths.localConfigPath(for: kSafeConfigName)

        try? FileManager.default.removeItem(atPath: tempPath)

        do {
            try FileManager.default.copyItem(atPath: path, toPath: tempPath)
        } catch {
            return "clashx_meta_config error \(error)"
        }

        return await requestConfigUpdate(configPath: tempPath)
    }

    static func requestConfigUpdate(configPath: String) async -> ErrorString? {
        return await ConfigApplyCoordinator.shared.perform {
            await requestConfigUpdateSeriallyConfigPath(configPath: configPath)
        }
    }

    @MainActor
    private static func requestConfigUpdateSeriallyConfigPath(configPath: String) async -> ErrorString? {
        let local = RemoteControlManager.selectConfig == nil
        let snapshot = ConfigOverride.shared.takePreparedConfig(path: configPath)
        if local {
            CustomProxyHealth.shared.beginConfigurationUpdate()
        } else {
            CustomProxyHealth.shared.invalidate()
        }
        defer {
            if local { CustomProxyHealth.shared.endConfigurationUpdate() }
        }
        let generation = ConfigOverride.shared.runtimeGeneration
        let placeHolderErrorDesp = "Error occoured, Please try to fix it by restarting ClashX. "

        let response = await req(
                "/configs",
                method: .PUT,
                parameters: ["Path": configPath],
                encoding: .json
            )
            .response

        if response.httpResponse?.statusCode == 204 {
            if local {
                // A stream disconnection does not invalidate a successful PUT.
                // The generation changes only when the local process restarts.
                guard generation == ConfigOverride.shared.runtimeGeneration else {
                    return NSLocalizedString("Configuration changed. Please try again.", comment: "")
                }
                ConfigOverride.shared.recordAppliedConfig(snapshot)
            }
            return nil
        }

        let err = JSON(response.data ?? Data())["message"].string
            ?? response.error?.localizedDescription
            ?? placeHolderErrorDesp
        Logger.log(err)
        return err
    }

    static func updateOutBoundMode(mode: ClashProxyMode) async -> Bool {
        return await ConfigApplyCoordinator.shared.perform {
            await updateOutBoundModeSeriallyMode(mode: mode)
        }
    }

    private static func updateOutBoundModeSeriallyMode(mode: ClashProxyMode) async -> Bool {
        let response = await req(
            "/configs",
            method: .PATCH,
            parameters: ["mode": mode.rawValue],
            encoding: .json
        )
        .validate()
        .response
        return response.error == nil
    }

    static func updateLogLevel(level: ClashLogLevel) async -> Bool {
        return await ConfigApplyCoordinator.shared.perform {
            await updateLogLevelSeriallyLevel(level: level)
        }
    }

    private static func updateLogLevelSeriallyLevel(level: ClashLogLevel) async -> Bool {
        let response = await req(
            "/configs",
            method: .PATCH,
            parameters: ["log-level": level.rawValue],
            encoding: .json
        )
        .validate()
        .response
        return response.error == nil
    }

    static func requestProxyGroupList() async -> ClashProxyResp {
        let proxies: ClashProxyResp

        do {
            let data = try await req("/proxies")
                .validate()
                .responseData
            proxies = ClashProxyResp(data)
        } catch {
            Logger.log(error.localizedDescription)
            proxies = ClashProxyResp(nil)
        }

        ApiRequest.shared.proxyRespCache = proxies
        return proxies
    }

    static func requestProxyProviderList() async -> ClashProviderResp {
        do {
            return try await req("/providers/proxies")
                .validate()
                .responseDecodable(ClashProviderResp.self)
        } catch {
            Logger.log("requestProxyProviderList error \(error.localizedDescription)")
            return ClashProviderResp()
        }
    }

    static func getAllProxyList() async -> [ClashProxyName] {
        let proxyInfo = await requestProxyGroupList()
        return proxyInfo.proxiesMap["GLOBAL"]?.all ?? []
    }

    static func updateAllowLan(allow: Bool) async {
        await ConfigApplyCoordinator.shared.perform {
            await updateAllowLanSeriallyAllow(allow: allow)
        }
    }

    private static func updateAllowLanSeriallyAllow(allow: Bool) async {
        Logger.log("update allow lan:\(allow)", level: .debug)
        do {
            _ = try await req(
                "/configs",
                method: .PATCH,
                parameters: ["allow-lan": allow],
                encoding: .json
            )
            .validate()
            .responseData
        } catch {
            Logger.log("update allow lan failed: \(error.localizedDescription)", level: .error)
        }
    }

    static func updateProxyGroup(group: String, selectProxy: String) async -> Bool {
        let response = await req(
            "/proxies/\(group.encoded)",
            method: .PUT,
            parameters: ["name": selectProxy],
            encoding: .json
        )
        .response
        return response.httpResponse?.statusCode == 204
    }

    static func getMergedProxyData() async -> ClashProxyResp {
        async let provider = requestProxyProviderList()
        async let proxyInfo = requestProxyGroupList()

        let mergedProxyInfo = await proxyInfo
        mergedProxyInfo.updateProvider(await provider)
        return mergedProxyInfo
    }

    static func getProxyDelay(proxyName: String) async -> Int {
        if let proxy = await CustomProxyHealth.shared.savedProxy(named: proxyName) {
            return await CustomProxyHealth.shared.test(proxy) ?? 0
        }
        return await requestProxyDelay(proxyName: proxyName, url: ConfigManager.shared.benchMarkUrl, timeout: 2500) ?? 0
    }

    static func requestProxyDelay(proxyName: String, url: String, timeout: Int) async -> Int? {
        do {
            let data = try await req(
                "/proxies/\(proxyName.encoded)/delay",
                method: .GET,
                parameters: ["timeout": timeout, "url": url]
            )
            .validate()
            .responseData
            return JSON(data)["delay"].int
        } catch {
            return nil
        }
    }

    static func getGroupDelay(groupName: String) async -> [String: Int] {
        do {
            return try await req(
                "/group/\(groupName.encoded)/delay",
                method: .GET,
                parameters: ["timeout": 2500, "url": ConfigManager.shared.benchMarkUrl]
            )
            .validate()
            .responseDecodable([String: Int].self)
        } catch {
            return [:]
        }
    }

    static func getRules() async -> [ClashRule] {
        do {
            let data = try await req("/rules")
                .validate()
                .responseData
            return ClashRuleResponse.fromData(data).rules ?? []
        } catch {
            return []
        }
    }

    static func healthCheck(proxy: ClashProviderName) async {
        Logger.log("HeathCheck for \(proxy) started")
        let response = await req("/providers/proxies/\(proxy.encoded)/healthcheck")
            .response
        if response.httpResponse?.statusCode == 204 {
            Logger.log("HeathCheck for \(proxy) finished")
        } else {
            Logger.log("HeathCheck for \(proxy) failed:\(response.httpResponse?.statusCode ?? -1)")
        }
    }
}

// MARK: - Connections

extension ApiRequest {
    static func getConnections() async -> [ClashConnectionBaseSnapShot.Connection] {
        do {
            let snapshot = try await req("/connections")
                .validate()
                .responseDecodable(ClashConnectionBaseSnapShot.self)
            return snapshot.connections
        } catch {
            assertionFailure()
            return []
        }
    }

    static func closeConnection(_ id: String) async {
            _ = try? await req("/connections/\(id)", method: .DELETE)
                .validate()
                .responseData
    }
	
	static func getConnectionsSnapshot() async -> DBConnectionSnapShot? {
		do {
			return try await req("/connections")
				.validate()
				.responseDecodable(DBConnectionSnapShot.self)
		} catch {
			return nil
		}
	}

	static func closeConnection(_ conn: ClashConnectionSnapShot.Connection) async {
            _ = try? await req("/connections/".appending(conn.id), method: .DELETE)
                .validate()
                .responseData
	}

	static func closeAllConnection() async {
            _ = try? await req("/connections", method: .DELETE)
                .validate()
                .responseData
	}
}

// MARK: - Meta

extension ApiRequest {
    static func updateAllProviders(for type: ProviderType) async -> Int {
        let providerNames: [String]

        if type == .proxy {
            let response = await requestProxyProviderList()
            providerNames = response.allProviders
                .filter { $0.value.vehicleType == .HTTP }
                .map(\.key)
        } else {
            let response = await requestRuleProviderList()
            providerNames = response.allProviders.map(\.key)
        }

        return await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for name in providerNames {
                group.addTask {
                    await !updateProvider(for: type, name: name)
                }
            }

            var failuresCount = 0
            for await didFail in group {
                if didFail {
                    failuresCount += 1
                }
            }
            return failuresCount
        }
    }

    static func updateProvider(for type: ProviderType, name: String) async -> Bool {
        let logTitle = "Update \(type.logString()) Provider"

        Logger.log("\(logTitle) \(name)")

        let response = await req("/providers/\(type.apiString())/\(name)", method: .PUT)
            .response
        let success = response.httpResponse?.statusCode == 204

        Logger.log("\(logTitle) \(name) \(success ? "success" : "failed")")
        return success
    }

    static func requestRuleProviderList() async -> ClashRuleProviderResp {
        do {
            return try await req("/providers/rules")
                .validate()
                .responseDecodable(ClashRuleProviderResp.self)
        } catch {
            Logger.log("Get Rule providers error \(error.localizedDescription)")
            return ClashRuleProviderResp()
        }
    }

    static func flushDNSCache() async {
        async let flushFakeipCache = flushFakeipCacheResult()
        async let flushDNSCache = flushDNSCacheResult()

        let flushFakeipCacheResult = await flushFakeipCache
        let flushDNSCacheResult = await flushDNSCache
        let info = (flushFakeipCacheResult && flushDNSCacheResult) ? "Success" : "Failed"

        await MainActor.run {
            UserNotificationCenter.shared.post(title: NSLocalizedString("Flush dns cache", comment: ""), info: info)
        }
    }

    static func updateGEO() async -> Bool {
        Logger.log("UpdateGEO")
        let response = await req("/configs/geo", method: .POST)
            .response
        let success = response.httpResponse?.statusCode == 204
        Logger.log("Updating GEO Databases...")
        return success
    }

    static func updateTun(enable: Bool) async {
        await ConfigApplyCoordinator.shared.perform {
            await updateTunSeriallyEnable(enable: enable)
        }
    }

    private static func updateTunSeriallyEnable(enable: Bool) async {
        Logger.log("update tun:\(enable)", level: .debug)
        do {
            _ = try await req(
                "/configs",
                method: .PATCH,
                parameters: ["tun": ["enable": enable]],
                encoding: .json
            )
            .validate()
            .responseData
        } catch {
            Logger.log("update tun failed: \(error.localizedDescription)", level: .error)
        }
    }

    static func updateSniffing(enable: Bool) async {
        await ConfigApplyCoordinator.shared.perform {
            await updateSniffingSeriallyEnable(enable: enable)
        }
    }

    private static func updateSniffingSeriallyEnable(enable: Bool) async {
        Logger.log("update sniffing:\(enable)", level: .debug)
        do {
            _ = try await req(
                "/configs",
                method: .PATCH,
                parameters: ["sniffing": enable],
                encoding: .json
            )
            .validate()
            .responseData
        } catch {
            Logger.log("update sniffing failed: \(error.localizedDescription)", level: .error)
        }
    }
    
    // MARK: - Providers

    struct AllProviders {
        var proxies = [String]()
        var rules = [String]()
    }

    static func requestExternalProviderNames() async -> AllProviders {
        async let proxyNamesTask: [String] = {
            do {
                let data = try await req("/providers/proxies")
                    .validate()
                    .responseData
                let json = JSON(data)
                return json["providers"].dictionaryValue
                    .filter { $0.value["vehicleType"] == "HTTP" }
                    .map(\.key)
            } catch {
                Logger.log(error.localizedDescription, level: .warning)
                return []
            }
        }()


        return AllProviders(proxies: await proxyNamesTask, rules: [])
    }

	/*
    enum ProviderType {
        case proxy
        case rule
    }
	 */

    static func resetFakeIpCache() async {
        let response = await req("/cache/fakeip/flush", method: .POST)
            .response
        Logger.log("flush fake ip: \(response.httpResponse?.statusCode ?? -1)")
    }
}

// MARK: - Stream Apis

extension ApiRequest {
	@MainActor
	func resetStreamApis() {
		ApiRequestStream.shared.resetStreamApis()
	}

	@MainActor
	func resetStreamApi(for type: ApiRequestStream.StreamType) {
		ApiRequestStream.shared.resetStreamApi(for: type)
	}

	@MainActor
	func prepareForTermination() {
		ApiRequestStream.shared.prepareForTermination()
	}
}
