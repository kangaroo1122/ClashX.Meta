//
//  MetaDNS.swift
//  ClashX



import Cocoa
import SystemConfiguration

// https://github.com/zhuhaow/Specht2/blob/main/app/me.zhuhaow.Specht2.proxy-helper/ProxyHelper.swift

class MetaDNS: NSObject {
	private static let appliedDNSKey = "ProxyConfigHelper.AppliedTunDNS"
    private var customDNS = UserDefaults.standard.stringArray(forKey: MetaDNS.appliedDNSKey)
    private static let pendingDNSKey = "ProxyConfigHelper.PendingDNSChange"
    private var hasPendingChange = UserDefaults.standard.bool(forKey: MetaDNS.pendingDNSKey)

    private func dnsError(_ message: String) -> NSError {
        NSError(domain: "com.metacubex.ClashX.ProxyConfigHelper.DNS", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
	
	static let savedDNSKey = "ProxyConfigHelper.SavedSystemDNSs"
    var savedDNS = [String: [String]]()
    let authRef: AuthorizationRef

    override init() {
        var auth: AuthorizationRef?
        let authFlags: AuthorizationFlags = [.extendRights, .interactionAllowed, .preAuthorize]

        let authErr = AuthorizationCreate(nil, nil, authFlags, &auth)

        if authErr != noErr {
            NSLog("Error: Failed to create administration authorization due to error \(authErr).")
        }

        if auth == nil {
            NSLog("Error: No authorization has been granted to modify network configuration.")
        }
		
		
		if let data = UserDefaults.standard.data(forKey: MetaDNS.savedDNSKey),
		   let saved = try? JSONDecoder().decode([String: [String]].self, from: data) {
			self.savedDNS = saved
		}
		
        authRef = auth!

        super.init()
    }

    deinit {
        AuthorizationFree(authRef, AuthorizationFlags())
    }
    
    // A missing applied list denotes a legacy backup. The old helper never
    // persisted its custom DNS, so do not assume that it was 8.8.8.8.
    private func resolveOriginalDNS(_ currentDNS: [String: [String]]) -> [String: [String]] {
        var resolved = savedDNS
        for (serviceID, sysDNS) in currentDNS {
            if let saved = savedDNS[serviceID],
               customDNS == nil || hasPendingChange || sysDNS == customDNS {
                resolved[serviceID] = saved
            } else {
                resolved[serviceID] = sysDNS
            }
        }
        return resolved
    }

    func hijackDNS(_ dns: String) throws {
        guard let addresses = TunDNSAddresses.parse(dns) else {
            throw dnsError("Invalid TUN DNS addresses.")
        }
        let currentDNS = try getAllDns()
        let originals = resolveOriginalDNS(currentDNS)
        let backup = try JSONEncoder().encode(originals)

        // Keep the original backup through address changes. Avoid restoring and
        // immediately re-reading DNS, which could capture the previous override.
        savedDNS = originals
        UserDefaults.standard.set(backup, forKey: MetaDNS.savedDNSKey)
        hasPendingChange = true
        UserDefaults.standard.set(true, forKey: MetaDNS.pendingDNSKey)
        customDNS = addresses
        UserDefaults.standard.set(addresses, forKey: MetaDNS.appliedDNSKey)
        let requested = currentDNS.mapValues { _ in addresses }
        try updateDNSConfigure(requested)
        hasPendingChange = false
        UserDefaults.standard.removeObject(forKey: MetaDNS.pendingDNSKey)
    }

    func revertDNS() throws {
        guard !savedDNS.isEmpty else { return }
        let currentDNS = try getAllDns()
        let resolved = resolveOriginalDNS(currentDNS)
        // Persist recovery intent before writing: commit may succeed even when
        // apply fails. A later retry must still use the original backup.
        savedDNS = resolved
        UserDefaults.standard.set(try JSONEncoder().encode(resolved), forKey: MetaDNS.savedDNSKey)
        hasPendingChange = true
        UserDefaults.standard.set(true, forKey: MetaDNS.pendingDNSKey)
        try updateDNSConfigure(resolved)
        savedDNS.removeAll()
        UserDefaults.standard.removeObject(forKey: MetaDNS.savedDNSKey)
        hasPendingChange = false
        UserDefaults.standard.removeObject(forKey: MetaDNS.pendingDNSKey)
    }

    private func getAllDns() throws -> [String: [String]] {
        guard let prefs = SCPreferencesCreate(nil, "com.metacubex.ClashX.ProxyConfigHelper.preferences" as CFString, nil),
              let values = SCPreferencesGetValue(prefs, kSCPrefNetworkServices) as? [String: AnyObject] else {
            throw dnsError("Failed to read network services for DNS backup.")
        }
        var result = [String: [String]]()
        for (serviceID, service) in values {
            guard let hardware = service.value(forKeyPath: "Interface.Hardware") as? String,
                  ["AirPort", "Wi-Fi", "Ethernet"].contains(hardware) else { continue }
            // Read the committed preferences, not the asynchronously updated
            // dynamic store, when taking a backup immediately after a change.
            result[serviceID] = service.value(forKeyPath: "DNS.ServerAddresses") as? [String] ?? []
        }
        return result
    }

    func flushDnsCache() async {
        if #available(OSX 10.15, *) {
            await Command(cmd: "/usr/bin/dscacheutil", args: ["-flushcache"]).run()
        }
        await Command(cmd: "/usr/bin/killall", args: ["-HUP", "mDNSResponder"]).run()
        
        print("flushDnsCache")
    }

    private func updateDNSConfigure(_ dnsDic: [String: [String]]) throws {
        guard !dnsDic.isEmpty else { return }

        guard let prefRef = SCPreferencesCreateWithAuthorization(
            nil,
            "com.metacubex.ClashX.ProxyConfigHelper.config" as CFString,
            nil,
            authRef) else {
            throw dnsError("Failed to obtain DNS preference reference.")
        }

        guard SCPreferencesLock(prefRef, true) else {
            throw dnsError("Failed to lock DNS preferences.")
        }

        defer {
            SCPreferencesUnlock(prefRef)
        }

        guard let services = SCNetworkServiceCopyAll(prefRef) as? [SCNetworkService] else {
            throw dnsError("Failed to load network services.")
        }
        
        let type = kSCNetworkProtocolTypeDNS

        for service in services {
            guard let id = SCNetworkServiceGetServiceID(service) as? String,
                  let dns = dnsDic[id] else {
                continue
            }
            
            
            guard let protoc = SCNetworkServiceCopyProtocol(service, type) else {
                throw dnsError("Failed to obtain DNS settings for network service \(id).")
            }

            let config = SCNetworkProtocolGetConfiguration(protoc)

            let dic = (config as NSDictionary?)?.mutableCopy() as? NSMutableDictionary ?? NSMutableDictionary()
            
            dic["ServerAddresses"] = dns

            guard SCNetworkProtocolSetConfiguration(protoc, dic as CFDictionary) else {
                throw dnsError("Failed to set DNS settings for network service \(id).")
            }

            NSLog("Set \(type) settings for \(SCNetworkServiceGetName(service)!)")
        }


        guard SCPreferencesCommitChanges(prefRef) else {
            throw dnsError("Failed to commit DNS preference changes.")
        }

        guard SCPreferencesApplyChanges(prefRef) else {
            throw dnsError("Failed to apply DNS preference changes.")
        }
    }
}
