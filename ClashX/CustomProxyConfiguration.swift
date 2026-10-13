import Foundation
import Network
import Yams

struct CustomProxyConfiguration: Codable, Equatable {
    var version = 1
    var enabled = false
    var proxies: [CustomProxyEntry] = []
    var groups: [CustomProxyGroup] = []
    var rules: [CustomProxyRule] = []
    var providers: [CustomRuleProvider] = []

    var targets: [String] { ["DIRECT", "REJECT"] + proxies.map(\.name) + groups.map(\.name) }

    func validate() throws {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw CustomProxyError(message) }
        }
        func validName(_ name: String) -> Bool {
            !name.isEmpty && name == name.trimmingCharacters(in: .whitespacesAndNewlines)
                && !name.contains(",") && !name.contains(where: { $0.isNewline })
        }
        let names = proxies.map(\.name) + groups.map(\.name)
        try require(version == 1, "Unsupported custom configuration version.")
        try require(names.allSatisfy(validName), "Proxy and group names must be nonempty and cannot contain commas or line breaks.")
        try require(Set(names).count == names.count, "Proxy and group names must be unique.")
        try require(Set(names).isDisjoint(with: ["DIRECT", "REJECT", "GLOBAL", "REJECT-DROP", "PASS", "COMPATIBLE"]), "A proxy or group uses a reserved name.")
        for proxy in proxies {
            try require(["http", "socks5"].contains(proxy.type), "Unsupported proxy type.")
            try require(!proxy.server.isEmpty && !proxy.server.contains(where: { $0.isWhitespace }) && !proxy.server.contains("/"), "Enter a server hostname or IP address without a URL scheme.")
            try require((1...65535).contains(Int(proxy.port) ?? 0), "Proxy port must be between 1 and 65535.")
            if let url = proxy.testURL, !url.isEmpty {
                try require(Self.validURL(url), "Enter a valid HTTP or HTTPS test URL.")
            }
        }
        let allTargets = Set(targets)
        let groupMap = Dictionary(uniqueKeysWithValues: groups.map { ($0.name, $0) })
        for group in groups {
            try require(["select", "fallback", "url-test"].contains(group.type), "Unsupported group type.")
            try require(!group.members.isEmpty && Set(group.members).count == group.members.count, "Each group needs at least one member, without duplicates.")
            try require(group.members.allSatisfy { allTargets.contains($0) }, "A group references a missing proxy or group. Update its members after renaming or deleting an entry.")
            if group.type != "select" {
                try require(Self.validURL(group.url), "Enter a valid HTTP or HTTPS health-check URL.")
                try require((Int(group.interval) ?? 0) > 0 && (Int(group.timeout) ?? 0) > 0, "Health-check interval and timeout must be positive.")
                try require((Int(group.tolerance) ?? -1) >= 0, "Latency tolerance cannot be negative.")
            }
        }
        var visited = Set<String>()
        var visiting = Set<String>()
        func visit(_ name: String) throws {
            guard let group = groupMap[name], !visited.contains(name) else { return }
            try require(!visiting.contains(name), "Proxy groups cannot reference themselves or form a cycle.")
            visiting.insert(name)
            for member in group.members { try visit(member) }
            visiting.remove(name)
            visited.insert(name)
        }
        for group in groups { try visit(group.name) }
        let providerNames = providers.map(\.name)
        try require(providerNames.allSatisfy(validName) && Set(providerNames).count == providerNames.count, "Rule-set names must be valid and unique.")
        for provider in providers {
            try require(Self.validURL(provider.url) && (Int(provider.interval) ?? 0) > 0, "Rule sets need an HTTP or HTTPS URL and a positive update interval.")
            try require(["classical", "domain", "ipcidr"].contains(provider.behavior), "Unsupported rule-set behavior.")
            try require(["yaml", "text", "mrs"].contains(provider.format), "Unsupported rule-set format.")
            try require(provider.format != "mrs" || provider.behavior != "classical", "MRS rule sets support domain or ipcidr behavior only.")
        }
        for rule in rules {
            try require(CustomProxyRule.types.contains(rule.type), "Unsupported rule type.")
            try require(allTargets.contains(rule.target), "A rule references a missing target. Update it after renaming or deleting an entry.")
            let value = rule.value
            try require(!value.isEmpty && !value.contains(",") && !value.contains(where: { $0.isNewline }), "Rule values must be nonempty and cannot contain commas or line breaks.")
            if rule.type == "RULE-SET" {
                try require(providerNames.contains(value), "A rule references a missing rule set.")
            } else if rule.type == "IP-CIDR" || rule.type == "IP-CIDR6" {
                let parts = value.split(separator: "/", omittingEmptySubsequences: false)
                let ipv6 = rule.type == "IP-CIDR6"
                let addressOK = parts.count == 2 && (ipv6 ? IPv6Address(String(parts[0])) != nil : IPv4Address(String(parts[0])) != nil)
                let prefix = parts.count == 2 ? Int(parts[1]) : nil
                try require(addressOK && prefix.map { (0...(ipv6 ? 128 : 32)).contains($0) } == true, "Enter a valid IP network with a prefix length, such as 192.168.45.0/24.")
            } else if rule.type != "PROCESS-NAME" {
                try require(!value.contains(where: { $0.isWhitespace }) && !value.contains("/"), "Enter a domain or domain keyword without a URL scheme or path.")
            }
        }
    }

    static func validURL(_ text: String) -> Bool {
        guard let url = URLComponents(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty else { return false }
        return !text.contains(where: { $0.isWhitespace }) && url.user == nil && url.password == nil
    }

    /// Namespace all local references, including nested groups and rule sets.
    /// Leave global settings, DNS and the subscription's catch-all unchanged.
    func merge(into node: inout Node) throws {
        guard enabled else { return }
        try validate()
        guard var base = try Yams.load(yaml: Yams.serialize(node: node)) as? [String: Any] else {
            throw CustomProxyError("The subscription must contain a YAML mapping.")
        }
        func array<T>(_ key: String, as type: T.Type) throws -> [T] {
            guard let value = base[key] else { return [] }
            guard let values = value as? [T] else { throw CustomProxyError("Invalid subscription list: \(key)") }
            return values
        }
        func local(_ name: String) -> String { "[Local] " + name }
        func target(_ name: String) -> String { ["DIRECT", "REJECT"].contains(name) ? name : local(name) }
        var existingProxies: [[String: Any]] = try array("proxies", as: [String: Any].self)
        var existingGroups: [[String: Any]] = try array("proxy-groups", as: [String: Any].self)
        let existingRules: [String] = try array("rules", as: String.self)
        let names = Set((existingProxies + existingGroups).compactMap { $0["name"] as? String })
        guard (proxies.map(\.name) + groups.map(\.name)).allSatisfy({ !names.contains(local($0)) }) else {
            throw CustomProxyError("The subscription already contains a conflicting [Local] proxy or group.")
        }
        // Automatic subscription groups must never select a work proxy.
        // Mihomo separates independent exclude expressions with a backtick;
        // preserve the existing expression instead of rewriting its regex.
        if !proxies.isEmpty {
            let exclusion = "^(" + proxies.map {
                NSRegularExpression.escapedPattern(for: local($0.name)).replacingOccurrences(of: "`", with: #"\x60"#)
            }.joined(separator: "|") + ")$"
            for index in existingGroups.indices {
                let group = existingGroups[index]
                func enabled(_ key: String) -> Bool {
                    if let value = group[key] as? Bool { return value }
                    return ["true", "1"].contains((group[key] as? String)?.lowercased() ?? "")
                }
                guard enabled("include-all") || enabled("include-all-proxies") else { continue }
                if let filter = group["exclude-filter"], !(filter is String) {
                    throw CustomProxyError("Invalid subscription exclude-filter.")
                }
                let previous = group["exclude-filter"] as? String ?? ""
                existingGroups[index]["exclude-filter"] = previous.isEmpty
                    ? exclusion : previous + "`" + exclusion
            }
        }
        for proxy in proxies {
            var value: [String: Any] = ["name": local(proxy.name), "type": proxy.type, "server": proxy.server, "port": Int(proxy.port) ?? 0]
            if !proxy.username.isEmpty { value["username"] = proxy.username }
            if !proxy.password.isEmpty { value["password"] = proxy.password }
            if proxy.tls {
                value["tls"] = true
                value["skip-cert-verify"] = proxy.skipCertVerify
                if !proxy.sni.isEmpty { value["sni"] = proxy.sni }
            }
            if proxy.type == "socks5" { value["udp"] = proxy.udp }
            existingProxies.append(value)
        }
        for group in groups {
            var value: [String: Any] = ["name": local(group.name), "type": group.type, "proxies": group.members.map(target)]
            if group.type != "select" {
                value["url"] = group.url
                value["interval"] = Int(group.interval)
                value["timeout"] = Int(group.timeout)
                value["lazy"] = group.lazy
                if group.type == "url-test" { value["tolerance"] = Int(group.tolerance) }
            }
            existingGroups.append(value)
        }
        var existingProviders = base["rule-providers"] as? [String: Any] ?? [:]
        if base["rule-providers"] != nil && !(base["rule-providers"] is [String: Any]) {
            throw CustomProxyError("Invalid subscription rule providers.")
        }
        for provider in providers {
            guard existingProviders[local(provider.name)] == nil else { throw CustomProxyError("The subscription already contains a conflicting [Local] rule set.") }
            existingProviders[local(provider.name)] = [
                "type": "http", "behavior": provider.behavior, "format": provider.format,
                "url": provider.url, "interval": Int(provider.interval) ?? 0,
                "path": "./ruleset/custom-\(provider.id.uuidString).\(provider.format)"
            ] as [String: Any]
        }
        let addedRules = rules.map { rule in
            let value = rule.type == "RULE-SET" ? local(rule.value) : rule.value
            return "\(rule.type),\(value),\(target(rule.target))" + (rule.supportsNoResolve && rule.noResolve ? ",no-resolve" : "")
        }
        base["proxies"] = existingProxies
        base["proxy-groups"] = existingGroups
        base["rules"] = addedRules + existingRules
        if !providers.isEmpty { base["rule-providers"] = existingProviders }
        guard let merged = try Yams.compose(yaml: Yams.dump(object: base)) else { throw CustomProxyError("Unable to compose the custom configuration.") }
        node = merged
    }
}

struct CustomProxyEntry: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = ""
    var type = "http"
    var server = ""
    var port = "8080"
    var username = ""
    var password = ""
    var tls = false
    var sni = ""
    var skipCertVerify = false
    var udp = false
    // Optional so files saved before per-node testing remain readable.
    var testURL: String?
    var runtimeName: String { "[Local] " + name }
}

struct CustomProxyGroup: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = ""
    var type = "select"
    var members: [String] = []
    var url = "https://www.gstatic.com/generate_204"
    var interval = "300"
    var timeout = "5000"
    var lazy = true
    var tolerance = "50"
}

struct CustomProxyRule: Codable, Equatable, Identifiable {
    static let types = ["DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "IP-CIDR", "IP-CIDR6", "PROCESS-NAME", "RULE-SET"]
    var id = UUID()
    var type = "DOMAIN-SUFFIX"
    var value = ""
    var target = "DIRECT"
    var noResolve = true
    var supportsNoResolve: Bool { ["IP-CIDR", "IP-CIDR6", "RULE-SET"].contains(type) }
}

struct CustomRuleProvider: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = ""
    var url = ""
    var behavior = "classical"
    var format = "yaml"
    var interval = "86400"
}

struct CustomProxyError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { NSLocalizedString(message, comment: "Custom proxy configuration") }
}

enum CustomProxyStorage {
    private static var url: URL {
        URL(fileURLWithPath: kConfigFolderPath).appendingPathComponent("custom-proxies.json")
    }

    static func load() throws -> CustomProxyConfiguration {
        guard FileManager.default.fileExists(atPath: url.path) else { return CustomProxyConfiguration() }
        let value = try JSONDecoder().decode(CustomProxyConfiguration.self, from: Data(contentsOf: url))
        guard value.version == 1 else { throw CustomProxyError("Unsupported custom configuration version.") }
        if value.enabled { try value.validate() }
        return value
    }

    /// Keep the original bytes, including files which cannot be decoded.
    /// A failed backup must never discard the user's configuration.
    static func backUpAndDisable() throws -> URL {
        let backup = url.deletingLastPathComponent().appendingPathComponent("custom-proxies-backup-\(UUID().uuidString).json")
        let data = try Data(contentsOf: url)
        guard FileManager.default.createFile(atPath: backup.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CustomProxyError("Unable to back up custom proxy settings.")
        }
        try save(CustomProxyConfiguration())
        return backup
    }

    static func save(_ value: CustomProxyConfiguration) throws {
        let data = try JSONEncoder().encode(value)
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Stage with owner-only permissions before atomically replacing a file
        // which may contain proxy credentials. Never store them in logs.
        let staged = url.deletingLastPathComponent().appendingPathComponent(".custom-proxies-\(UUID().uuidString).json")
        defer { try? fm.removeItem(at: staged) }
        guard fm.createFile(atPath: staged.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CustomProxyError("Unable to save custom proxy settings.")
        }
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: staged)
        } else {
            try fm.moveItem(at: staged, to: url)
        }
    }
}
