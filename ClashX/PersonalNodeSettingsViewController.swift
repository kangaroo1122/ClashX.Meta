import AppKit
import SwiftUI

final class PersonalNodeSettingsViewController: NSViewController, WindowCloseConfirming {
    private let editor = PersonalNodeEditor.shared

    override func loadView() {
        title = NSLocalizedString("Personal nodes", comment: "")
        view = NSHostingView(rootView: PersonalNodeSettingsView(editor: editor))
        preferredContentSize = NSSize(width: 940, height: 690)
        view.setFrameSize(preferredContentSize)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.contentMinSize = NSSize(width: 820, height: 580)
        if !editor.isDirty { editor.reload() }
        Task { await editor.refreshCatalog() }
    }

    func shouldCloseWindow() -> Bool {
        guard !editor.isSaving else { return false }
        guard editor.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Discard unsaved personal node changes?", comment: "")
        alert.addButton(withTitle: NSLocalizedString("Keep editing", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Discard changes", comment: ""))
        guard alert.runModal() == .alertSecondButtonReturn else { return false }
        editor.reload()
        return true
    }
}

private struct PersonalNodeSettingsView: View {
    @ObservedObject var editor: PersonalNodeEditor
    @ObservedObject private var runtime = PersonalNodeRuntime.shared
    @State private var search = ""
    @State private var selection: UUID?
    @State private var importing = false
    @State private var deleteID: UUID?
    @State private var confirmDelete = false
    @State private var confirmRecovery = false

    private var selected: PersonalNode? { editor.draft.nodes.first { $0.id == selection } }
    private var visible: [PersonalNode] {
        editor.draft.nodes.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.type.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Personal nodes").font(.title2.bold())
                Spacer()
                Button("Import links / YAML…") { importing = true }
                Menu {
                    ForEach(PersonalNode.protocols, id: \.self) { type in
                        Button(type.uppercased()) {
                            let node = PersonalNode(type: type)
                            editor.draft.nodes.append(node); selection = node.id; search = ""
                        }
                    }
                } label: { Label("New node", systemImage: "plus") }
            }.disabled(editor.loadFailed)
            Text("Import your own nodes and add them to selected subscription groups. Source subscriptions remain unchanged.")
                .font(.callout).foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 0) {
                VStack(spacing: 8) {
                    TextField("Search nodes", text: $search).textFieldStyle(.roundedBorder).padding(.horizontal, 8)
                    List(selection: $selection) {
                        ForEach(visible) { node in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Image(systemName: node.enabled ? "checkmark.circle" : "pause.circle")
                                        .foregroundColor(.secondary)
                                        .accessibilityLabel(Text(LocalizedStringKey(node.enabled ? "Enabled" : "Disabled")))
                                    Text(node.name.isEmpty ? NSLocalizedString("Untitled entry", comment: "") : node.name).lineLimit(1)
                                }
                                Text(verbatim: node.type.uppercased()).font(.caption).foregroundColor(.secondary)
                                if node.associations.values.allSatisfy(\.isEmpty) {
                                    Text("Not assigned to a strategy group").font(.caption).foregroundColor(.secondary)
                                }
                                if runtime.isTesting(node) { Text("Testing…").font(.caption) }
                                else if let delay = runtime.delay(for: node) { Text(verbatim: delay).font(.caption).foregroundColor(.secondary) }
                            }
                            .padding(.vertical, 3).tag(node.id)
                            .contextMenu {
                                Button("Duplicate node") { duplicate(node) }
                                Button("Copy sharing link") { copyLink(node) }
                                Button("Copy node YAML") { copyYAML(node) }
                                Button("Test node") { Task { await runtime.test(node) } }.disabled(!runtime.canTest(node))
                                Divider()
                                Button("Delete", role: .destructive) { deleteID = node.id; confirmDelete = true }
                            }
                        }
                    }
                }.frame(width: 245).padding(.vertical, 8)
                Divider()
                if let node = selected {
                    PersonalNodeDetail(node: Binding(get: {
                        editor.draft.nodes.first { $0.id == node.id } ?? node
                    }, set: { value in
                        editor.updateNode(value)
                    }), editor: editor).id(node.id)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "network").font(.largeTitle).foregroundColor(.secondary)
                        Text("Import a link or create a node to get started.").foregroundColor(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Color(NSColor.controlBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
            .disabled(editor.loadFailed)
            if !editor.message.isEmpty {
                Text(verbatim: editor.message).foregroundColor(editor.isError ? .red : .secondary)
                    .font(.callout).textSelection(.enabled).lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if editor.isDirty { Text("Unsaved changes").foregroundColor(.secondary) }
                Spacer()
                if editor.loadFailed {
                    Button("Retry reading settings") { editor.reload() }
                    Button("Back up and reset") { confirmRecovery = true }
                }
                Button("Discard changes") { editor.reload() }.disabled(!editor.isDirty)
                if editor.isSaving { ProgressView().controlSize(.small) }
                Button("Save and apply") { Task { await editor.save() } }
                    .disabled(editor.loadFailed).keyboardShortcut("s", modifiers: .command)
            }
        }
        .padding(20).disabled(editor.isSaving)
        .sheet(isPresented: $importing) {
            PersonalNodeImportView { nodes in
                editor.draft.nodes.append(contentsOf: nodes)
                selection = nodes.first?.id; search = ""
            }
        }
        .alert("Delete this entry?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let id = deleteID, editor.deleteNode(id), selection == id { selection = nil }
                deleteID = nil
            }
        }
        .alert("Back up and reset personal nodes?", isPresented: $confirmRecovery) {
            Button("Cancel", role: .cancel) {}
            Button("Back up and reset", role: .destructive) { Task { await editor.recover() } }
        } message: {
            Text("The original file will be backed up before clearing personal nodes and reloading the local configuration.")
        }
    }

    private func duplicate(_ node: PersonalNode) {
        var copy = node; copy.id = UUID()
        copy.setText("name", node.name + " " + NSLocalizedString("Copy", comment: ""))
        editor.draft.nodes.append(copy); selection = copy.id; search = ""
    }

    private func copyYAML(_ node: PersonalNode) {
        do {
            let text = try node.yaml()
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
            editor.report(NSLocalizedString("Node YAML copied, including credentials.", comment: ""))
        } catch { editor.report(NSLocalizedString("Unable to export node YAML.", comment: ""), error: true) }
    }

    private func copyLink(_ node: PersonalNode) {
        do {
            let link = try PersonalNodeLink.export(node)
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(link, forType: .string)
            editor.report(NSLocalizedString("Sharing link copied, including credentials.", comment: ""))
        } catch { editor.report(error.localizedDescription, error: true) }
    }
}

private struct PersonalNodeDetail: View {
    @Binding var node: PersonalNode
    @ObservedObject var editor: PersonalNodeEditor
    @ObservedObject private var runtime = PersonalNodeRuntime.shared
    @State private var tab = 0
    @State private var yamlEditing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(node.name.isEmpty ? NSLocalizedString("New node", comment: "") : node.name).font(.headline).lineLimit(1)
                Spacer()
                Toggle("Enable node", isOn: $node.enabled)
            }
            Picker("Node details", selection: $tab) {
                Text("Node settings").tag(0)
                Text("Strategy groups").tag(1)
            }.pickerStyle(.segmented)
            ScrollView {
                if tab == 0 { form }
                else { associations }
            }
            if tab == 0 {
                HStack {
                    Button("Personal node YAML editor button") { yamlEditing = true }
                    Spacer()
                    Button("Test node") { Task { await runtime.test(node) } }.disabled(!runtime.canTest(node))
                }
                Text("Testing requires this saved node to be enabled and assigned to the current local configuration.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $yamlEditing) {
            PersonalNodeYAMLEditor(node: node) { value in node = value }
        }
    }

    private var form: some View {
        Form {
            Group {
                TextField("Name", text: text("name"))
                HStack { Text("Personal node protocol label"); Spacer(); Text(verbatim: node.type.uppercased()).foregroundColor(.secondary) }
                TextField("Server", text: text("server"))
                TextField("Port", text: text("port", numeric: true))
            }
            Group {
                if ["vless", "vmess", "tuic"].contains(node.type) { TextField("UUID", text: text("uuid")) }
                if ["http", "socks5"].contains(node.type) { TextField("Username", text: text("username")) }
                if ["ss", "trojan", "hysteria2", "tuic", "http", "socks5"].contains(node.type) { SecureField("Password", text: text("password")) }
                if ["ss", "vmess"].contains(node.type) { TextField("Cipher", text: text("cipher")) }
                if node.type == "vmess" { TextField("Alter ID", text: text("alterId", numeric: true)) }
                if node.type == "vless" { TextField("Flow", text: text("flow")) }
            }
            if ["vless", "vmess", "trojan", "hysteria2", "tuic", "http", "socks5"].contains(node.type) {
                DisclosureGroup("TLS and transport") {
                    if ["vless", "vmess", "http", "socks5"].contains(node.type) { Toggle("Enable TLS", isOn: flag("tls")) }
                    TextField("SNI", text: text(["vless", "vmess"].contains(node.type) ? "servername" : "sni"))
                    Toggle("Skip certificate verification", isOn: flag("skip-cert-verify"))
                    TextField("ALPN (comma separated)", text: arrayText("alpn"))
                    TextField("Client fingerprint", text: text("client-fingerprint"))
                    if node.type == "vless" {
                        TextField("Reality public key", text: nested(["reality-opts", "public-key"]))
                        TextField("Reality short ID", text: nested(["reality-opts", "short-id"]))
                    }
                    if ["vless", "vmess", "trojan"].contains(node.type) {
                        Picker("Transport", selection: Binding(get: { node.text("network").isEmpty ? "tcp" : node.text("network") }, set: { node.setText("network", $0) })) {
                            ForEach(transports, id: \.self) { Text(verbatim: $0).tag($0) }
                        }
                        if node.text("network") == "ws" {
                            TextField("Path", text: nested(["ws-opts", "path"]))
                            TextField("Host", text: nested(["ws-opts", "headers", "Host"]))
                        }
                        if node.text("network") == "grpc" { TextField("gRPC service name", text: nested(["grpc-opts", "grpc-service-name"])) }
                        Text("Additional transport options are preserved and can be edited in node YAML.").font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            DisclosureGroup("Advanced settings") {
                if node.type != "http" { Toggle("UDP forwarding", isOn: flag("udp")) }
                if node.type == "hysteria2" {
                    TextField("Obfuscation", text: text("obfs"))
                    SecureField("Obfuscation password", text: text("obfs-password"))
                    TextField("Upload bandwidth (Mbps)", text: text("up"))
                    TextField("Download bandwidth (Mbps)", text: text("down"))
                    TextField("Port hopping range", text: text("ports"))
                }
                if node.type == "tuic" {
                    TextField("Congestion controller", text: text("congestion-controller"))
                    TextField("UDP relay mode", text: text("udp-relay-mode"))
                    Toggle("Disable SNI", isOn: flag("disable-sni"))
                    Toggle("Reduce RTT", isOn: flag("reduce-rtt"))
                }
                if node.type == "ss" { TextField("Plugin", text: text("plugin")) }
                Text("Use node YAML for plugin options and other protocol fields. Support depends on the installed core.").font(.caption).foregroundColor(.secondary)
            }
        }.textFieldStyle(.roundedBorder).padding(.vertical, 8)
    }

    private var associations: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Nodes join selected groups. Automatic groups use their existing filters; ordering follows the core.").font(.callout).foregroundColor(.secondary)
                Spacer()
                Button("Refresh") { Task { await editor.refreshCatalog() } }
            }
            ForEach(editor.catalog) { config in
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        if let error = config.error { Text(verbatim: error).foregroundColor(.orange) }
                        if config.groups.isEmpty && config.error == nil { Text("No supported strategy groups in this configuration.").foregroundColor(.secondary) }
                        ForEach(config.groups) { group in
                            Toggle(isOn: membership(config.name, group.name)) {
                                HStack { Text(verbatim: group.name); Spacer(); Text(verbatim: group.title).font(.caption).foregroundColor(.secondary) }
                            }
                        }
                        ForEach(Array(Set(node.associations[config.name] ?? []).subtracting(config.groups.map(\.name))).sorted(), id: \.self) { missing in
                            HStack {
                                Image(systemName: "exclamationmark.triangle").foregroundColor(.orange)
                                Text(verbatim: missing)
                                Text("Target group unavailable").font(.caption).foregroundColor(.secondary)
                                Spacer()
                                Button("Remove association") { setMembership(config.name, missing, false) }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                } label: { Text(verbatim: config.name).font(.headline) }
            }
        }.padding(.vertical, 8)
    }

    private func text(_ key: String, numeric: Bool = false) -> Binding<String> {
        Binding(get: { node.text(key) }, set: { node.setText(key, $0, numeric: numeric) })
    }
    private var transports: [String] {
        let supported = node.type == "trojan" ? ["tcp", "ws", "grpc"] : ["tcp", "ws", "grpc", "h2", "http"]
        return Array(Set((supported + [node.text("network")]).filter { !$0.isEmpty })).sorted()
    }
    private func flag(_ key: String) -> Binding<Bool> {
        Binding(get: { node.flag(key) }, set: { node.settings[key] = .bool($0) })
    }
    private func arrayText(_ key: String) -> Binding<String> {
        Binding(get: {
            if case let .array(values) = node.settings[key] { return values.map(\.text).joined(separator: ",") }
            return node.text(key)
        }, set: { value in
            if value.isEmpty { node.settings.removeValue(forKey: key) }
            else { node.settings[key] = .array(value.components(separatedBy: ",").map { .string($0.trimmingCharacters(in: .whitespaces)) }) }
        })
    }
    private func nested(_ path: [String]) -> Binding<String> {
        Binding(get: {
            var current: PersonalNodeValue = .object(node.settings)
            for key in path {
                guard case let .object(map) = current, let next = map[key] else { return "" }
                current = next
            }
            return current.text
        }, set: { value in
            func update(_ map: inout [String: PersonalNodeValue], _ keys: ArraySlice<String>) {
                guard let key = keys.first else { return }
                if keys.count == 1 { map[key] = value.isEmpty ? nil : .string(value); return }
                var child: [String: PersonalNodeValue] = [:]
                if case let .object(existing) = map[key] { child = existing }
                update(&child, keys.dropFirst())
                map[key] = child.isEmpty ? nil : .object(child)
            }
            update(&node.settings, path[...])
        })
    }
    private func membership(_ config: String, _ group: String) -> Binding<Bool> {
        Binding(get: { (node.associations[config] ?? []).contains(group) }, set: { setMembership(config, group, $0) })
    }
    private func setMembership(_ config: String, _ group: String, _ enabled: Bool) {
        var groups = node.associations[config] ?? []
        groups.removeAll { $0 == group }
        if enabled { groups.append(group) }
        node.associations[config] = groups.isEmpty ? nil : groups
    }
}

private struct PersonalNodeImportView: View {
    struct Row: Identifiable {
        let id = UUID()
        let line: Int
        let node: PersonalNode?
        let error: String?
    }
    @Environment(\.dismiss) private var dismiss
    var importNodes: ([PersonalNode]) -> Void
    @State private var text = ""
    @State private var yaml = false
    @State private var rows: [Row] = []
    @State private var previewed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import personal nodes").font(.headline)
            Picker("Import format", selection: $yaml) {
                Text("Sharing links").tag(false)
                Text("Node YAML").tag(true)
            }.pickerStyle(.segmented)
            Text(LocalizedStringKey(yaml ? "Paste a node mapping, a node list, or a proxies YAML section." : "Paste one sharing link per line. Links are parsed on this Mac."))
                .font(.callout).foregroundColor(.secondary)
            TextEditor(text: $text).font(.system(.body, design: .monospaced)).frame(minHeight: 160)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty && !yaml {
                        Text("Personal node link protocols placeholder")
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            if previewed {
                List(rows) { row in
                    HStack(alignment: .top) {
                        Text(verbatim: "\(row.line)").foregroundColor(.secondary).frame(width: 30)
                        if let node = row.node {
                            Text(verbatim: node.name)
                            Spacer()
                            Text(verbatim: node.type.uppercased()).foregroundColor(.secondary)
                            Image(systemName: "checkmark.circle").foregroundColor(.green)
                        } else { Text(verbatim: row.error ?? "").foregroundColor(.red).textSelection(.enabled) }
                    }
                }.frame(height: 150)
            }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Preview import") { preview() }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Import valid nodes") {
                    importNodes(rows.compactMap(\.node))
                    if rows.contains(where: { $0.error != nil }) && !yaml {
                        let lines = text.components(separatedBy: .newlines)
                        text = rows.filter { $0.error != nil }.map { lines[$0.line - 1] }.joined(separator: "\n")
                        rows = []; previewed = false
                    } else { dismiss() }
                }.disabled(!previewed || rows.allSatisfy { $0.node == nil })
            }
        }.padding(20).frame(width: 680, height: 520)
        .onChange(of: text) { _ in rows = []; previewed = false }
        .onChange(of: yaml) { _ in rows = []; previewed = false }
    }

    private func preview() {
        rows = []
        if text.utf8.count > 1_048_576 {
            rows = [.init(line: 1, node: nil, error: NSLocalizedString("Node import is too large.", comment: ""))]
        } else if yaml {
            do { rows = try PersonalNodeLink.parseYAML(text).enumerated().map { .init(line: $0.offset + 1, node: $0.element, error: nil) } }
            catch { rows = [.init(line: 1, node: nil, error: error.localizedDescription)] }
        } else {
            let lines = text.components(separatedBy: .newlines).enumerated().filter { !$0.element.trimmingCharacters(in: .whitespaces).isEmpty }
            if lines.count > 500 { rows = [.init(line: 1, node: nil, error: NSLocalizedString("Import between 1 and 500 nodes at a time.", comment: ""))] }
            else {
                rows = lines.map { index, line in
                    do { return .init(line: index + 1, node: try PersonalNodeLink.parse(line), error: nil) }
                    catch { return .init(line: index + 1, node: nil, error: error.localizedDescription) }
                }
            }
        }
        previewed = true
    }
}

private struct PersonalNodeYAMLEditor: View {
    @Environment(\.dismiss) private var dismiss
    let node: PersonalNode
    let save: (PersonalNode) -> Void
    @State private var text = ""
    @State private var error = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Personal node YAML editor title").font(.headline)
            Text("All protocol fields are preserved. Changes update the draft; save and apply in the main window.").foregroundColor(.secondary)
            TextEditor(text: $text).font(.system(.body, design: .monospaced))
            if !error.isEmpty { Text(verbatim: error).foregroundColor(.red) }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Update draft") {
                    do {
                        let nodes = try PersonalNodeLink.parseYAML(text)
                        guard nodes.count == 1, var value = nodes.first else { throw CustomProxyError("Edit one node at a time.") }
                        value.id = node.id; value.enabled = node.enabled; value.associations = node.associations
                        save(value); dismiss()
                    } catch { self.error = error.localizedDescription }
                }
            }
        }.padding(20).frame(width: 680, height: 520)
        .onAppear {
            do { text = try node.yaml() }
            catch { self.error = NSLocalizedString("Unable to export node YAML.", comment: "") }
        }
    }
}
