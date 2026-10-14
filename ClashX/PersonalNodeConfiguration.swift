import Foundation
import CoreFoundation
import Yams

/// A lossless, Codable tree keeps protocol options that the basic form does not expose.
indirect enum PersonalNodeValue: Codable, Equatable {
    case string(String), number(Double), bool(Bool), array([PersonalNodeValue]), object([String: PersonalNodeValue]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([PersonalNodeValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: PersonalNodeValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case let .string(v): try c.encode(v)
        case let .number(v): try c.encode(v)
        case let .bool(v): try c.encode(v)
        case let .array(v): try c.encode(v)
        case let .object(v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    init(_ value: Any) throws {
        switch value {
        case let v as String: self = .string(v)
        case let v as NSNumber:
            self = CFGetTypeID(v) == CFBooleanGetTypeID() ? .bool(v.boolValue) : .number(v.doubleValue)
        case let v as [String: Any]: self = .object(try v.mapValues { try PersonalNodeValue($0) })
        case let v as [Any]: self = .array(try v.map { try PersonalNodeValue($0) })
        case is NSNull: self = .null
        default: throw CustomProxyError("Unsupported YAML value in node settings.")
        }
    }

    var value: Any {
        switch self {
        case let .string(v): return v
        case let .number(v):
            if v.isFinite, v.rounded() == v, v >= Double(Int.min), v < Double(Int.max) { return Int(v) }
            return v
        case let .bool(v): return v
        case let .array(v): return v.map(\.value)
        case let .object(v): return v.mapValues(\.value)
        case .null: return NSNull()
        }
    }

    var text: String {
        switch self {
        case let .string(v): return v
        case let .number(v): return v.rounded() == v ? String(format: "%.0f", v) : String(v)
        default: return ""
        }
    }
}

struct PersonalNode: Codable, Equatable, Identifiable {
    static let protocols = ["vless", "vmess", "ss", "trojan", "hysteria2", "tuic", "http", "socks5"]
    var id = UUID()
    var enabled = true
    var settings: [String: PersonalNodeValue] = [:]
    /// Configuration names are the same identities used by configuration selection.
    var associations: [String: [String]] = [:]

    init(type: String = "vless") {
        settings = ["name": .string(""), "type": .string(type), "server": .string(""), "port": .number(443)]
        if type != "http" { settings["udp"] = .bool(true) }
        if ["vless", "vmess"].contains(type) { settings["tls"] = .bool(true) }
        if type == "vmess" { settings["cipher"] = .string("auto"); settings["alterId"] = .number(0) }
        if type == "ss" { settings["cipher"] = .string("aes-128-gcm") }
    }

    init(mapping: [String: Any]) throws {
        settings = try mapping.mapValues { try PersonalNodeValue($0) }
    }

    var name: String { text("name") }
    var type: String { text("type") }
    var runtimeName: String { "[Own] \(name) [\(id.uuidString.prefix(8))]" }
    func text(_ key: String) -> String { settings[key]?.text ?? "" }
    func flag(_ key: String) -> Bool { settings[key] == .bool(true) }

    mutating func setText(_ key: String, _ value: String, numeric: Bool = false) {
        if value.isEmpty { settings.removeValue(forKey: key) }
        else if numeric, let n = Int(value) { settings[key] = .number(Double(n)) }
        else { settings[key] = .string(value) }
    }

    func yaml() throws -> String { try Yams.dump(object: settings.mapValues(\.value)) }

    func validatedMapping() throws -> [String: Any] {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw CustomProxyError(message) }
        }
        try require(!name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !name.contains(where: \.isNewline), "Enter a node name without line breaks.")
        try require(!type.isEmpty, "Choose a node protocol.")
        let server = text("server")
        try require(!server.isEmpty && !server.contains(where: \.isWhitespace) && !server.contains("/"), "Enter a server hostname or IP address without a URL scheme.")
        try require((1...65535).contains(Int(text("port")) ?? 0), "Proxy port must be between 1 and 65535.")
        if ["vless", "vmess", "tuic"].contains(type) {
            try require(!text("uuid").isEmpty, "Enter a node UUID.")
        }
        if ["ss", "trojan", "hysteria2", "tuic"].contains(type) {
            try require(!text("password").isEmpty, "Enter a node password.")
        }
        if ["ss", "vmess"].contains(type) { try require(!text("cipher").isEmpty, "Enter a cipher.") }
        if type == "vmess" { try require((Int(text("alterId")) ?? -1) >= 0, "Alter ID must be a nonnegative integer.") }
        if let reality = settings["reality-opts"], case let .object(options) = reality {
            try require(flag("tls") && !(options["public-key"]?.text ?? "").isEmpty, "Reality requires TLS and a public key.")
        }
        if let reference = settings["dialer-proxy"] {
            guard case .string = reference else { throw CustomProxyError("A node dialer reference must be a name.") }
        }
        var result = settings.mapValues(\.value)
        result["port"] = Int(text("port"))!
        if type == "vmess" { result["alterId"] = Int(text("alterId"))! }
        return result
    }
}

struct PersonalNodeConfiguration: Codable, Equatable {
    var version = 1
    var nodes: [PersonalNode] = []

    func validate() throws {
        guard version == 1, Set(nodes.map(\.id)).count == nodes.count else {
            throw CustomProxyError("Invalid personal node configuration version or duplicate identifiers.")
        }
        for node in nodes { _ = try node.validatedMapping() }
    }

    func validateForSave() throws {
        try validate()
        // Check every saved association, not only the currently selected subscription.
        let roots = nodes.filter { $0.enabled && $0.associations.values.contains { !$0.isEmpty } }
        _ = try resolveDependencies(roots: roots)
    }

    /// Shared by save validation and composition; no subscription file or running core required.
    private func resolveDependencies(roots: [PersonalNode], subscriptionNames: Set<String> = []) throws
        -> (active: [PersonalNode], references: [UUID: String]) {
        var loaded = Set<UUID>()
        var visiting = Set<UUID>()
        var references: [UUID: String] = [:]
        // Dependencies need not be members of a group, but must be enabled.
        func visit(_ node: PersonalNode) throws {
            guard !loaded.contains(node.id) else { return }
            guard visiting.insert(node.id).inserted else { throw CustomProxyError("Personal node dialer references contain a cycle.") }
            let reference = node.text("dialer-proxy")
            if !reference.isEmpty {
                let matches = nodes.filter { $0.name == reference || $0.runtimeName == reference }
                if !matches.isEmpty {
                    guard matches.count == 1, !subscriptionNames.contains(reference) else {
                        throw CustomProxyError("A personal node dialer reference is ambiguous. Use a unique node name.")
                    }
                    let dependency = matches[0]
                    guard dependency.enabled else { throw CustomProxyError("A personal node depends on a disabled node.") }
                    try visit(dependency)
                    references[node.id] = dependency.runtimeName
                }
            }
            visiting.remove(node.id)
            loaded.insert(node.id)
        }
        for node in roots { try visit(node) }
        return (nodes.filter { loaded.contains($0.id) }, references)
    }

    func merge(into yaml: inout Node, configName: String) throws {
        guard !nodes.isEmpty else { return }
        try validate()
        guard var base = try Yams.load(yaml: Yams.serialize(node: yaml)) as? [String: Any] else {
            throw CustomProxyError("The subscription must contain a YAML mapping.")
        }
        func list(_ key: String) throws -> [[String: Any]] {
            guard let v = base[key], !(v is NSNull) else { return [] }
            guard let rows = v as? [[String: Any]] else { throw CustomProxyError("Invalid subscription list: \(key)") }
            return rows
        }
        var proxies = try list("proxies")
        var groups = try list("proxy-groups")
        let supported = Set(["select", "url-test", "fallback", "load-balance"])
        let groupNames = Set(groups.filter { supported.contains($0["type"] as? String ?? "") }.compactMap { $0["name"] as? String })
        let roots = nodes.filter { $0.enabled && !Set($0.associations[configName] ?? []).isDisjoint(with: groupNames) }
        guard !roots.isEmpty else { return }
        var names = Set((proxies + groups).compactMap { $0["name"] as? String })
        let subscriptionNames = names.union(["DIRECT", "REJECT", "REJECT-DROP", "COMPATIBLE", "PASS", "GLOBAL"])
        let (active, references) = try resolveDependencies(roots: roots, subscriptionNames: subscriptionNames)
        for node in active {
            guard names.insert(node.runtimeName).inserted else { throw CustomProxyError("A subscription node conflicts with a personal node name.") }
            var value = try node.validatedMapping()
            value["name"] = node.runtimeName
            if let reference = references[node.id] { value["dialer-proxy"] = reference }
            // Every group, dialer reference and manual test shares this instance.
            proxies.append(value)
        }
        func flag(_ group: [String: Any], _ key: String) -> Bool {
            group[key] as? Bool == true || ["true", "1"].contains((group[key] as? String)?.lowercased() ?? "")
        }
        func members(_ group: [String: Any], _ key: String) throws -> [String] {
            guard let value = group[key], !(value is NSNull) else { return [] }
            guard let list = value as? [String] else { throw CustomProxyError("Invalid subscription group members.") }
            return list
        }
        func exactNames(_ values: [String]) -> String {
            // Backticks delimit Mihomo filters even inside regex character classes.
            let escaped = values.map {
                NSRegularExpression.escapedPattern(for: $0).replacingOccurrences(of: "`", with: "\\x60")
            }
            return "\\A(?:" + escaped.joined(separator: "|") + ")\\z"
        }
        for i in groups.indices {
            let name = groups[i]["name"] as? String ?? ""
            let assigned = roots.filter { ($0.associations[configName] ?? []).contains(name) && supported.contains(groups[i]["type"] as? String ?? "") }
            if flag(groups[i], "include-all") || flag(groups[i], "include-all-proxies") {
                // Let the core collect assigned nodes once and apply its original
                // filters/order. Exclude only nodes not associated with this group.
                let assignedIDs = Set(assigned.map(\.id))
                let excluded = active.filter { !assignedIDs.contains($0.id) }
                guard !excluded.isEmpty else { continue }
                if let value = groups[i]["exclude-filter"], !(value is NSNull), !(value is String) {
                    throw CustomProxyError("Invalid subscription exclude-filter.")
                }
                let previous = groups[i]["exclude-filter"] as? String ?? ""
                let exclusion = exactNames(excluded.map(\.runtimeName))
                // Backticks separate independent regexes in Mihomo. Do not merge
                // expressions: doing so changes capture groups and backreferences.
                groups[i]["exclude-filter"] = previous.isEmpty ? exclusion : previous + "`" + exclusion
            } else if !assigned.isEmpty {
                var explicit = try members(groups[i], "proxies")
                for node in assigned where !explicit.contains(node.runtimeName) {
                    explicit.append(node.runtimeName)
                }
                groups[i]["proxies"] = explicit
            }
        }
        base["proxies"] = proxies
        base["proxy-groups"] = groups
        guard let result = try Yams.compose(yaml: Yams.dump(object: base)) else { throw CustomProxyError("Unable to compose personal nodes.") }
        yaml = result
    }
}

enum PersonalNodeStorage {
    static var url: URL { URL(fileURLWithPath: kConfigFolderPath).appendingPathComponent("personal-nodes.json") }

    static func load() throws -> PersonalNodeConfiguration {
        guard FileManager.default.fileExists(atPath: url.path) else { return PersonalNodeConfiguration() }
        do {
            let result = try JSONDecoder().decode(PersonalNodeConfiguration.self, from: Data(contentsOf: url))
            try result.validate()
            return result
        } catch { throw CustomProxyError("Unable to read personal-nodes.json. Restore a valid backup or correct the file, then retry.") }
    }

    static func save(_ value: PersonalNodeConfiguration) throws {
        try value.validateForSave()
        try CustomProxyStorage.writePrivateFile(JSONEncoder().encode(value), to: url)
    }
}
