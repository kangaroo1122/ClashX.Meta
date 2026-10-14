import Foundation
import Yams

/// Sharing links are converted locally. Unknown options are rejected, never silently dropped.
enum PersonalNodeLink {
    static func decodeBase64(_ text: String) -> Data? {
        var value = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        return Data(base64Encoded: value)
    }

    private static func fail(_ message: String = "Invalid node link. Check the format and required fields.") -> CustomProxyError { CustomProxyError(message) }

    static func parse(_ text: String) throws -> PersonalNode {
        let link = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard link.utf8.count <= 65536, !link.contains(where: \.isWhitespace),
              let schemeEnd = link.range(of: "://") else { throw fail() }
        let scheme = String(link[..<schemeEnd.lowerBound]).lowercased()
        if scheme == "vmess", let data = decodeBase64(String(link[schemeEnd.upperBound...])),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return try vmess(json)
        }
        if scheme == "ss" { return try shadowsocks(link) }
        let (normalizedLink, hoppingPorts): (String, String?) = try ["hysteria2", "hy2"].contains(scheme)
            ? normalizeHysteriaPorts(link) : (link, nil)
        guard ["vless", "vmess", "trojan", "hysteria2", "hy2", "tuic", "http", "https", "socks5"].contains(scheme),
              let url = URLComponents(string: normalizedLink), let host = url.host, !host.isEmpty,
              url.path.isEmpty || url.path == "/" else { throw fail() }
        let type = scheme == "hy2" ? "hysteria2" : scheme == "https" ? "http" : scheme
        var node = PersonalNode(type: type)
        node.setText("name", url.fragment?.isEmpty == false ? url.fragment! : host)
        node.setText("server", host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
        let defaultPort = scheme == "http" ? 80 : (["hysteria2", "trojan", "https", "hy2"].contains(scheme) ? 443 : 0)
        node.setText("port", String(url.port ?? defaultPort), numeric: true)
        var query = try parameters(url)
        func take(_ key: String) -> String? { query.removeValue(forKey: key) }
        func takeAlias(_ keys: [String]) throws -> String? {
            let values = keys.compactMap { take($0) }
            guard Set(values).count <= 1 else { throw fail("Conflicting node link parameters.") }
            return values.first
        }
        if ["vless", "vmess", "tuic"].contains(type) {
            node.setText("uuid", url.user ?? "")
            if type != "tuic", url.password != nil { throw fail() }
        }
        switch type {
        case "trojan", "hysteria2":
            node.setText("password", (url.user ?? "") + (url.password.map { ":" + $0 } ?? ""))
        case "tuic":
            guard url.password != nil else { throw fail("Only TUIC v5 sharing links are supported.") }
            node.setText("password", url.password ?? "")
        case "http", "socks5":
            node.setText("username", url.user ?? "")
            node.setText("password", url.password ?? "")
            node.settings["tls"] = .bool(scheme == "https")
        default: break
        }
        if let insecure = try takeAlias(["allowInsecure", "insecure", "allow_insecure", "skip-cert-verify"]) {
            node.settings["skip-cert-verify"] = .bool(try boolean(insecure))
        }
        if let sni = try takeAlias(["sni", "peer", "servername"]) {
            node.setText(["vless", "vmess"].contains(type) ? "servername" : "sni", sni)
        }
        if let alpn = take("alpn") { node.settings["alpn"] = .array(alpn.split(separator: ",").map { .string(String($0)) }) }
        if let fingerprint = try takeAlias(["fp", "client-fingerprint"]) { node.setText("client-fingerprint", fingerprint) }
        if ["vless", "vmess", "trojan"].contains(type) {
            if let pin = take("pcs") { node.setText("fingerprint", pin) }
            let security = take("security") ?? (type == "trojan" ? "tls" : "none")
            guard ["none", "tls", "reality"].contains(security), type == "vless" || security != "reality",
                  type != "trojan" || security == "tls" else { throw fail("Unsupported TLS mode in sharing link. Use node YAML instead.") }
            if type != "trojan" { node.settings["tls"] = .bool(security != "none") }
            if security == "reality" {
                guard let key = take("pbk"), !key.isEmpty else { throw fail("Reality requires TLS and a public key.") }
                var reality: [String: PersonalNodeValue] = ["public-key": .string(key), "short-id": .string(take("sid") ?? "")]
                if let value = take("support-x25519mlkem768") {
                    reality["support-x25519mlkem768"] = .bool(try boolean(value))
                }
                // Xray's SpiderX has no Mihomo equivalent; accept it only for REALITY links.
                _ = take("spx")
                node.settings["reality-opts"] = .object(reality)
                if node.text("client-fingerprint").isEmpty { node.setText("client-fingerprint", "chrome") }
            }
            if type == "vless" {
                if let flow = take("flow") {
                    guard flow.isEmpty || flow == "xtls-rprx-vision" else { throw fail("Unsupported VLESS flow. Use node YAML instead.") }
                    node.setText("flow", flow)
                }
                if let encryption = take("encryption"), encryption != "none", !encryption.isEmpty {
                    throw fail("Unsupported VLESS encryption in sharing link. Use node YAML instead.")
                }
                if let encoding = take("packetEncoding") { node.setText("packet-encoding", encoding) }
            } else if type == "vmess" {
                node.setText("cipher", take("encryption") ?? "auto")
            }
            var network = (take("type") ?? "tcp").lowercased()
            if network.isEmpty { network = "tcp" }
            let path = take("path")
            let hostHeader = take("host")
            let service = take("serviceName")
            let header = take("headerType")
            guard header == nil || header == "" || header == "none" || (header == "http" && network == "tcp") else { throw fail("Unsupported transport header. Use node YAML instead.") }
            if network == "http" { network = "h2" }
            else if header == "http" { network = "http" }
            try transport(&node, network: network, path: path, host: hostHeader, service: service)
            if ["ws", "httpupgrade"].contains(network), case var .object(options) = node.settings["ws-opts"] {
                if let earlyData = take("ed") {
                    guard !earlyData.isEmpty, earlyData.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                          let size = Int(earlyData), size >= 0 else { throw fail() }
                    if network == "httpupgrade" {
                        options["v2ray-http-upgrade-fast-open"] = .bool(size > 0)
                    } else {
                        options["max-early-data"] = .number(Double(size))
                        options["early-data-header-name"] = .string("Sec-WebSocket-Protocol")
                    }
                }
                if let headerName = take("eh"), !headerName.isEmpty {
                    options["early-data-header-name"] = .string(headerName)
                }
                node.settings["ws-opts"] = .object(options)
            }
        } else if type == "hysteria2" {
            for key in ["obfs", "obfs-password", "up", "down"] {
                if let value = take(key) { node.setText(key, value) }
            }
            if let pin = take("pinSHA256") { node.setText("fingerprint", pin) }
            let queryPorts = try take("mport").map { try validatedPorts($0).ports }
            if let hoppingPorts, let queryPorts, hoppingPorts != queryPorts { throw fail("Conflicting node link parameters.") }
            if let ports = hoppingPorts ?? queryPorts { node.setText("ports", ports) }
            if let ech = take("ech"), !ech.isEmpty {
                guard Data(base64Encoded: ech) != nil else { throw fail() }
                node.settings["ech-opts"] = .object(["enable": .bool(true), "config": .string(ech)])
            }
        } else if type == "tuic" {
            for (source, target) in [("congestion_control", "congestion-controller"), ("udp_relay_mode", "udp-relay-mode")] {
                if let value = take(source) { node.setText(target, value) }
            }
            for (source, target) in [("disable_sni", "disable-sni"), ("reduce_rtt", "reduce-rtt")] {
                if let value = take(source) { node.settings[target] = .bool(try boolean(value)) }
            }
        }
        try rejectUnknown(query)
        _ = try node.validatedMapping()
        return node
    }

    private static func validatedPorts(_ text: String) throws -> (ports: String, first: Int) {
        var ranges: [String] = []
        var first: Int?
        for part in text.split(separator: ",", omittingEmptySubsequences: false) {
            let bounds = part.split(separator: "-", omittingEmptySubsequences: false)
            guard (1...2).contains(bounds.count) else { throw fail() }
            let numbers = try bounds.map { bound -> Int in
                guard !bound.isEmpty, bound.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                      let port = Int(bound), (1...65535).contains(port) else { throw fail() }
                return port
            }
            guard numbers[0] <= numbers[numbers.count - 1] else { throw fail() }
            if first == nil { first = numbers[0] }
            ranges.append(numbers.map { String($0) }.joined(separator: "-"))
        }
        guard let first else { throw fail() }
        return (ranges.joined(separator: ","), first)
    }

    /// URLComponents only accepts a single numeric port. Normalize the authority first,
    /// retaining the full hopping range separately and leaving credentials/IPv6 intact.
    private static func normalizeHysteriaPorts(_ link: String) throws -> (String, String?) {
        guard let start = link.range(of: "://")?.upperBound else { throw fail() }
        let end = link[start...].firstIndex(where: { "/?#".contains($0) }) ?? link.endIndex
        let authority = link[start..<end]
        let hostStart = authority.lastIndex(of: "@").map { link.index(after: $0) } ?? start
        let hostPort = link[hostStart..<end]
        let colon: String.Index?
        if hostPort.hasPrefix("[") {
            guard let bracket = hostPort.firstIndex(of: "]") else { throw fail() }
            let next = link.index(after: bracket)
            colon = next < end && link[next] == ":" ? next : nil
        } else {
            colon = hostPort.lastIndex(of: ":")
        }
        guard let colon else { return (link, nil) }
        let portStart = link.index(after: colon)
        let rawPorts = String(link[portStart..<end])
        guard rawPorts.contains(",") || rawPorts.contains("-") else { return (link, nil) }
        let parsed = try validatedPorts(rawPorts)
        return (String(link[..<portStart]) + String(parsed.first) + String(link[end...]), parsed.ports)
    }

    private static func parameters(_ url: URLComponents) throws -> [String: String] {
        var result: [String: String] = [:]
        for item in url.queryItems ?? [] {
            guard result[item.name] == nil else { throw fail("Duplicate node link parameters.") }
            result[item.name] = item.value ?? ""
        }
        return result
    }

    private static func rejectUnknown(_ values: [String: String]) throws {
        guard values.isEmpty else {
            // Report keys only: parameter values can contain credentials.
            throw fail(NSLocalizedString("Unsupported link parameters; use node YAML:", comment: "") + " " + values.keys.sorted().joined(separator: ", "))
        }
    }

    private static func boolean(_ text: String) throws -> Bool {
        switch text.lowercased() {
        case "true", "1": return true
        case "false", "0": return false
        default: throw fail("Invalid boolean in node link.")
        }
    }

    private static func transport(_ node: inout PersonalNode, network: String, path: String?, host: String?, service: String?) throws {
        let network = network.isEmpty ? "tcp" : network
        let supported = node.type == "trojan" ? ["tcp", "ws", "grpc"] : ["tcp", "ws", "httpupgrade", "grpc", "h2", "http"]
        guard supported.contains(network) else {
            throw fail("Unsupported transport in sharing link. Use node YAML instead.")
        }
        guard network == "grpc" || service == nil || service == "",
              network != "grpc" || ((path ?? "").isEmpty && (host ?? "").isEmpty),
              network != "tcp" || ((path ?? "").isEmpty && (host ?? "").isEmpty) else {
            throw fail("Link parameters do not match the selected transport.")
        }
        node.setText("network", network == "httpupgrade" ? "ws" : network)
        switch network {
        case "ws", "httpupgrade":
            var options: [String: PersonalNodeValue] = ["path": .string(path ?? "/")]
            if network == "httpupgrade" { options["v2ray-http-upgrade"] = .bool(true) }
            if let host, !host.isEmpty { options["headers"] = .object(["Host": .string(host)]) }
            node.settings["ws-opts"] = .object(options)
        case "grpc": node.settings["grpc-opts"] = .object(["grpc-service-name": .string(service ?? "")])
        case "h2":
            var options: [String: PersonalNodeValue] = ["path": .string(path ?? "/")]
            if let host, !host.isEmpty { options["host"] = .array(host.split(separator: ",").map { .string(String($0)) }) }
            node.settings["h2-opts"] = .object(options)
        case "http":
            var options: [String: PersonalNodeValue] = ["path": .array([.string(path ?? "/")])]
            if let host, !host.isEmpty { options["headers"] = .object(["Host": .array(host.split(separator: ",").map { .string(String($0)) })]) }
            node.settings["http-opts"] = .object(options)
        default: break
        }
    }

    private static func vmess(_ object: [String: Any]) throws -> PersonalNode {
        let known: Set<String> = ["v", "ps", "add", "port", "id", "aid", "scy", "net", "type", "host", "path", "tls", "sni", "alpn", "fp", "allowInsecure"]
        try rejectUnknown(object.filter { !known.contains($0.key) }.mapValues { _ in "" })
        func string(_ key: String, _ fallback: String = "") -> String {
            if let value = object[key] as? String { return value }
            if let value = object[key] as? NSNumber { return value.stringValue }
            return fallback
        }
        guard object.values.allSatisfy({ $0 is String || $0 is NSNumber }), ["", "2"].contains(string("v")) else { throw fail() }
        var node = PersonalNode(type: "vmess")
        for (key, value) in [("name", string("ps", string("add"))), ("server", string("add")), ("uuid", string("id")), ("cipher", string("scy", "auto"))] {
            node.setText(key, value)
        }
        node.setText("port", string("port"), numeric: true)
        node.setText("alterId", string("aid", "0"), numeric: true)
        guard ["", "none", "tls"].contains(string("tls")) else { throw fail("Unsupported TLS mode in sharing link. Use node YAML instead.") }
        node.settings["tls"] = .bool(string("tls") == "tls")
        node.setText("servername", string("sni"))
        node.setText("client-fingerprint", string("fp"))
        if !string("alpn").isEmpty { node.settings["alpn"] = .array(string("alpn").split(separator: ",").map { .string(String($0)) }) }
        if object["allowInsecure"] != nil { node.settings["skip-cert-verify"] = .bool(try boolean(string("allowInsecure"))) }
        var network = string("net", "tcp")
        let header = string("type", "none")
        guard ["", "none", "http"].contains(header) else { throw fail("Unsupported transport header. Use node YAML instead.") }
        if network == "http" { network = "h2" }
        if header == "http" { network = "http" }
        try transport(&node, network: network, path: network == "grpc" ? nil : string("path"), host: string("host"), service: network == "grpc" ? string("path") : nil)
        _ = try node.validatedMapping()
        return node
    }

    private static func shadowsocks(_ link: String) throws -> PersonalNode {
        var normalized = link
        // Legacy links encode the complete method:password@host:port authority.
        let body = String(link.dropFirst(5))
        let authority = String(body.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0])
        if !authority.contains("@"), let data = decodeBase64(authority), let decoded = String(data: data, encoding: .utf8) {
            guard let at = decoded.lastIndex(of: "@"), let colon = decoded[..<at].firstIndex(of: ":") else { throw fail() }
            var components = URLComponents(string: "ss://" + decoded[decoded.index(after: at)...])
            components?.user = String(decoded[..<colon])
            components?.password = String(decoded[decoded.index(after: colon)..<at])
            if let fragment = body.firstIndex(of: "#") {
                guard let name = String(body[body.index(after: fragment)...]).removingPercentEncoding else { throw fail() }
                components?.fragment = name
            }
            guard let value = components?.string else { throw fail() }
            normalized = value
        }
        guard let url = URLComponents(string: normalized), let host = url.host,
              let port = url.port, url.path.isEmpty || url.path == "/" else { throw fail() }
        let method: String
        let password: String
        if let plain = url.password { method = url.user ?? ""; password = plain }
        else {
            guard let data = decodeBase64(url.user ?? ""), let decoded = String(data: data, encoding: .utf8),
                  let colon = decoded.firstIndex(of: ":") else { throw fail() }
            method = String(decoded[..<colon]); password = String(decoded[decoded.index(after: colon)...])
        }
        var node = PersonalNode(type: "ss")
        node.setText("name", url.fragment?.isEmpty == false ? url.fragment! : host)
        node.setText("server", host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
        node.setText("port", String(port), numeric: true)
        node.setText("cipher", method)
        node.setText("password", password)
        var query = try parameters(url)
        if let plugin = query.removeValue(forKey: "plugin") { try parsePlugin(plugin, into: &node) }
        try rejectUnknown(query)
        _ = try node.validatedMapping()
        return node
    }

    private static func parsePlugin(_ text: String, into node: inout PersonalNode) throws {
        let fields = text.components(separatedBy: ";")
        let name = fields[0]
        guard ["obfs-local", "simple-obfs", "v2ray-plugin"].contains(name) else { throw fail("Unsupported Shadowsocks plugin. Use node YAML instead.") }
        var values: [String: String] = [:]
        for field in fields.dropFirst() where !field.isEmpty {
            let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(pair[0])
            guard values[key] == nil else { throw fail("Duplicate node link parameters.") }
            values[key] = pair.count == 2 ? String(pair[1]) : "true"
        }
        var options: [String: PersonalNodeValue] = [:]
        if name == "v2ray-plugin" {
            node.setText("plugin", name)
            options["mode"] = .string(values.removeValue(forKey: "mode") ?? "websocket")
            for key in ["host", "path"] { if let value = values.removeValue(forKey: key) { options[key] = .string(value) } }
            for key in ["tls", "mux", "skip-cert-verify"] { if let value = values.removeValue(forKey: key) { options[key] = .bool(try boolean(value)) } }
        } else {
            node.setText("plugin", "obfs")
            guard let mode = values.removeValue(forKey: "obfs"), ["http", "tls"].contains(mode) else { throw fail() }
            options["mode"] = .string(mode)
            if let host = values.removeValue(forKey: "obfs-host") { options["host"] = .string(host) }
        }
        try rejectUnknown(values)
        node.settings["plugin-opts"] = .object(options)
    }

    static func parseYAML(_ text: String) throws -> [PersonalNode] {
        guard text.utf8.count <= 1_048_576 else { throw fail("Node import is too large.") }
        let object: Any?
        do { object = try Yams.load(yaml: text) }
        catch { throw fail("Invalid node YAML. Check the syntax.") }
        let rows: [[String: Any]]
        if let map = object as? [String: Any], let list = map["proxies"] as? [[String: Any]] { rows = list }
        else if let list = object as? [[String: Any]] { rows = list }
        else if let map = object as? [String: Any], map["type"] != nil { rows = [map] }
        else { throw fail("Paste a node mapping, a node list, or a proxies YAML section.") }
        guard !rows.isEmpty, rows.count <= 500 else { throw fail("Import between 1 and 500 nodes at a time.") }
        return try rows.map {
            let node = try PersonalNode(mapping: $0)
            _ = try node.validatedMapping()
            return node
        }
    }

    /// Only export a link when re-importing it preserves the complete node.
    /// YAML remains available for options without a supported link representation.
    static func export(_ node: PersonalNode) throws -> String {
        _ = try node.validatedMapping()
        var url = URLComponents()
        url.scheme = node.type == "http" && node.flag("tls") ? "https" : node.type
        let server = node.text("server")
        url.host = server.contains(":") && !server.hasPrefix("[") ? "[\(server)]" : server
        url.port = Int(node.text("port"))
        url.fragment = node.name
        var query: [URLQueryItem] = []
        func add(_ key: String, _ value: String) {
            if !value.isEmpty { query.append(URLQueryItem(name: key, value: value)) }
        }
        func object(_ key: String) -> [String: PersonalNodeValue] {
            if case let .object(value) = node.settings[key] { return value }
            return [:]
        }
        func array(_ key: String) -> String {
            if case let .array(values) = node.settings[key] { return values.map(\.text).joined(separator: ",") }
            return ""
        }
        switch node.type {
        case "ss":
            if node.text("cipher").hasPrefix("2022-") {
                // SIP002 requires percent-encoded, non-Base64 userinfo for SS2022.
                let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
                url.percentEncodedUser = node.text("cipher").addingPercentEncoding(withAllowedCharacters: unreserved)
                url.percentEncodedPassword = node.text("password").addingPercentEncoding(withAllowedCharacters: unreserved)
            } else {
                url.user = Data((node.text("cipher") + ":" + node.text("password")).utf8).base64EncodedString()
                    .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: "=", with: "")
            }
            if !node.text("plugin").isEmpty {
                let options = object("plugin-opts")
                if node.text("plugin") == "obfs" {
                    var plugin = "obfs-local;obfs=\(options["mode"]?.text ?? "")"
                    if let host = options["host"] { plugin += ";obfs-host=" + host.text }
                    add("plugin", plugin)
                } else if node.text("plugin") == "v2ray-plugin" {
                    let fields = options.keys.sorted().map { key -> String in
                        if case let .bool(value) = options[key] { return "\(key)=\(value)" }
                        return "\(key)=\(options[key]?.text ?? "")"
                    }
                    add("plugin", (["v2ray-plugin"] + fields).joined(separator: ";"))
                }
            }
        case "vless", "vmess", "tuic":
            url.user = node.text("uuid")
            if node.type == "tuic" { url.password = node.text("password") }
        case "trojan", "hysteria2": url.user = node.text("password")
        case "http", "socks5":
            if !node.text("username").isEmpty { url.user = node.text("username") }
            if !node.text("password").isEmpty { url.password = node.text("password") }
        default: throw fail("These node options cannot be exported as a sharing link. Copy node YAML instead.")
        }
        if node.type != "ss" {
            add("sni", node.text(["vless", "vmess"].contains(node.type) ? "servername" : "sni"))
            add("alpn", array("alpn"))
            add("fp", node.text("client-fingerprint"))
            if node.flag("skip-cert-verify") { add("insecure", "1") }
        }
        if ["vless", "vmess", "trojan"].contains(node.type) {
            let reality = object("reality-opts")
            add("security", !reality.isEmpty ? "reality" : (node.flag("tls") || node.type == "trojan" ? "tls" : "none"))
            add("pbk", reality["public-key"]?.text ?? "")
            add("sid", reality["short-id"]?.text ?? "")
            if case let .bool(enabled) = reality["support-x25519mlkem768"] {
                add("support-x25519mlkem768", enabled ? "true" : "false")
            }
            if node.type == "vless" { add("flow", node.text("flow")); add("packetEncoding", node.text("packet-encoding")) }
            if node.type == "vmess" { add("encryption", node.text("cipher")) }
            add("pcs", node.text("fingerprint"))
            let network = node.text("network").isEmpty ? "tcp" : node.text("network")
            let httpUpgrade = network == "ws" && object("ws-opts")["v2ray-http-upgrade"] == .bool(true)
            add("type", httpUpgrade ? "httpupgrade" : network == "h2" ? "http" : network == "http" ? "tcp" : network)
            if network == "http" { add("headerType", "http") }
            if network == "ws" {
                let options = object("ws-opts")
                add("path", options["path"]?.text ?? "")
                add("ed", options["max-early-data"]?.text ?? "")
                if httpUpgrade, case let .bool(fastOpen) = options["v2ray-http-upgrade-fast-open"] {
                    add("ed", fastOpen ? "1" : "0")
                }
                add("eh", options["early-data-header-name"]?.text ?? "")
                if case let .object(headers) = options["headers"] { add("host", headers["Host"]?.text ?? "") }
            } else if network == "grpc" { add("serviceName", object("grpc-opts")["grpc-service-name"]?.text ?? "") }
            else if network == "h2" || network == "http" {
                let options = object(network + "-opts")
                if network == "h2" {
                    add("path", options["path"]?.text ?? "")
                    if case let .array(hosts) = options["host"] { add("host", hosts.map(\.text).joined(separator: ",")) }
                } else {
                    if case let .array(paths) = options["path"], paths.count == 1 { add("path", paths[0].text) }
                    if case let .object(headers) = options["headers"], case let .array(hosts) = headers["Host"] { add("host", hosts.map(\.text).joined(separator: ",")) }
                }
            }
        } else if node.type == "hysteria2" {
            for key in ["obfs", "obfs-password", "up", "down"] { add(key, node.text(key)) }
            add("mport", node.text("ports")); add("pinSHA256", node.text("fingerprint"))
            let ech = object("ech-opts")
            if ech["enable"] == .bool(true) { add("ech", ech["config"]?.text ?? "") }
        } else if node.type == "tuic" {
            add("congestion_control", node.text("congestion-controller"))
            add("udp_relay_mode", node.text("udp-relay-mode"))
            if node.flag("disable-sni") { add("disable_sni", "1") }
            if node.flag("reduce-rtt") { add("reduce_rtt", "1") }
        }
        if node.type == "ss", !query.isEmpty { url.path = "/" }
        url.queryItems = query.isEmpty ? nil : query
        guard var link = url.string else { throw fail() }
        // These extensions have URI representations; the legacy JSON format cannot
        // express them reliably across clients. Keep the URI when they are present.
        if node.type == "vmess", !query.contains(where: { ["pcs", "ed", "eh"].contains($0.name) || ($0.name == "type" && $0.value == "httpupgrade") }) {
            let network = node.text("network").isEmpty ? "tcp" : node.text("network")
            var json: [String: Any] = [
                "v": "2", "ps": node.name, "add": server, "port": node.text("port"),
                "id": node.text("uuid"), "aid": node.text("alterId"), "scy": node.text("cipher"),
                "net": network == "h2" ? "http" : network == "http" ? "tcp" : network,
                "type": network == "http" ? "http" : "none",
                "tls": node.flag("tls") ? "tls" : "", "sni": node.text("servername"),
                "fp": node.text("client-fingerprint"), "alpn": array("alpn"),
                "allowInsecure": node.flag("skip-cert-verify") ? "1" : "0"
            ]
            if let host = query.first(where: { $0.name == "host" })?.value { json["host"] = host }
            if let path = query.first(where: { $0.name == "path" || $0.name == "serviceName" })?.value { json["path"] = path }
            link = "vmess://" + (try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])).base64EncodedString()
        }
        func comparable(_ node: PersonalNode) throws -> [String: PersonalNodeValue] {
            var settings = try node.validatedMapping().mapValues { try PersonalNodeValue($0) }
            for key in ["skip-cert-verify", "tls", "disable-sni", "reduce-rtt"] where settings[key] == .bool(false) { settings.removeValue(forKey: key) }
            if settings["network"] == .string("tcp") { settings.removeValue(forKey: "network") }
            if node.type == "vless" && settings["encryption"] == .string("none") { settings.removeValue(forKey: "encryption") }
            // UDP is opt-in in Mihomo; preserve a missing value as false.
            if settings["udp"] == nil { settings["udp"] = .bool(["tuic", "hysteria2"].contains(node.type)) }
            return settings
        }
        guard let decoded = try? parse(link), try comparable(decoded) == comparable(node) else {
            throw fail("These node options cannot be exported as a sharing link. Copy node YAML instead.")
        }
        return link
    }
}
