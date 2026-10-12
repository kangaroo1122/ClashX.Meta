//
//  ConfigView.swift
//  ClashX Dashboard
//
//

import SwiftUI

struct ConfigView: View {
	
	@State var httpPort: Int = 0
	@State var socks5Port: Int = 0
	@State var mixedPort: Int = 0
	@State var redirPort: Int = 0
	@State var mode: ClashProxyMode = .direct
	@State var logLevel: ClashLogLevel = .unknow
	@State var allowLAN: Bool = false
	@State var sniffer: Bool = false
	@State var ipv6: Bool = false
	
	@State var enableTUNDevice: Bool = false
	@State var deviceName: String = "utun9"
	@State var interfaceName: String = "en0"
	
	@State private var hasLoadedConfig = false
	@State private var isApplyingConfig = false
	
	private let toggleStyle = SwitchToggleStyle()
	
	var body: some View {
		ScrollView {
			modeView
			
			content1
				.padding()
			
			Divider()
				.padding()
			
			tunView
				.padding()
			
			Divider()
				.padding()
			
			content2
				.padding()
		}
        .background(Color("SwiftUI Colors/WindowBackgroundColor"))
		.disabled(!hasLoadedConfig)
		.task {
			await loadConfig()
		}
	}

	@MainActor
	func loadConfig() async {
		hasLoadedConfig = false
		guard let config = await ApiRequest.requestConfig(), !Task.isCancelled else { return }
		apply(config: config)
	}

	@MainActor
	func refreshConfig() async {
		guard let config = await ApiRequest.requestConfig(), !Task.isCancelled else { return }
		apply(config: config)
	}

	@MainActor
	func apply(config: ClashConfig) {
		isApplyingConfig = true

		httpPort = config.port
		socks5Port = config.socksPort
		mixedPort = config.mixedPort
		redirPort = config.redirPort
		mode = config.mode
		logLevel = config.logLevel

		allowLAN = config.allowLan
		sniffer = config.sniffing
		ipv6 = config.ipv6

		enableTUNDevice = config.tun.enable
		deviceName = config.tun.device
		interfaceName = config.interfaceName

		hasLoadedConfig = true
		isApplyingConfig = false
	}
	
	
	var modeView: some View {
		Picker("", selection: $mode) {
			ForEach([
				ClashProxyMode.direct,
				.rule,
				.global
			], id: \.self) {
				Text($0.name).tag($0)
			}
		}
		.onChange(of: mode) { newValue in
			guard hasLoadedConfig, !isApplyingConfig else { return }
			Task {
				_ = await ApiRequest.updateOutBoundMode(mode: newValue)
			}
		}
		.padding()
		.controlSize(.large)
		.labelsHidden()
		.pickerStyle(.segmented)
	}
	
	var content1: some View {
		LazyVGrid(columns: [
			GridItem(.flexible()),
			GridItem(.flexible())
		], alignment: .leading) {
			
			ConfigItemView(name: "Http Port") {
				Text(String(httpPort))
					.font(.system(size: 17))
			}
			
			ConfigItemView(name: "Socks5 Port") {
				Text(String(socks5Port))
					.font(.system(size: 17))
			}
			
			ConfigItemView(name: "Mixed Port") {
				Text(String(mixedPort))
					.font(.system(size: 17))
			}
			
			ConfigItemView(name: "Redir Port") {
				Text(String(redirPort))
					.font(.system(size: 17))
			}
			
			ConfigItemView(name: "Log Level") {
				Text(logLevel.rawValue.capitalized)
					.font(.system(size: 17))
				
//				Picker("", selection: $logLevel) {
//					ForEach([
//						ClashLogLevel.silent,
//						.error,
//						.warning,
//						.info,
//						.debug,
//						.unknow
//					], id: \.self) {
//						Text($0.rawValue.capitalized).tag($0)
//					}
//				}
//				.disabled(true)
//				.pickerStyle(.menu)
			}
			
			ConfigItemView(name: "ipv6") {
				Toggle("", isOn: $ipv6)
					.toggleStyle(toggleStyle)
					.disabled(true)
			}
		}
	}
	
		var tunView: some View {
		LazyVGrid(columns: [
			GridItem(.flexible()),
			GridItem(.flexible())
		], alignment: .leading) {
			
			
			ConfigItemView(name: "Enable TUN Device") {
				Toggle("", isOn: $enableTUNDevice)
					.toggleStyle(toggleStyle)
					.onChange(of: enableTUNDevice) { newValue in
						guard hasLoadedConfig, !isApplyingConfig else { return }
						guard newValue != ProxyManager.shared.runtimeState.tunActive else { return }
						Task {
							await ProxyManager.shared.setTunEnabled(newValue)
						}
					}
					.onReceive(ProxyManager.shared.$runtimeTunActive) { newRuntimeTunActive in
						guard hasLoadedConfig, !isApplyingConfig else { return }
						if enableTUNDevice != newRuntimeTunActive {
							enableTUNDevice = newRuntimeTunActive
						}
					}
			}
			
			
			ConfigItemView(name: "TUN IP Stack") {
				TunStackSettingsView()
			}
			
			
			ConfigItemView(name: "Device Name") {
				Text(deviceName)
					.font(.system(size: 17))
			}
			
			
			ConfigItemView(name: "Interface Name") {
				Text(interfaceName)
					.font(.system(size: 17))
			}
			
		}
	}
	
	var content2: some View {
		LazyVGrid(columns: [
			GridItem(.flexible()),
			GridItem(.flexible())
		], alignment: .leading) {
			
			ConfigItemView(name: "Allow LAN") {
				Toggle("", isOn: $allowLAN)
					.toggleStyle(toggleStyle)
					.onChange(of: allowLAN) { newValue in
						guard hasLoadedConfig, !isApplyingConfig else { return }
						ConfigOverride.shared.allowLan = newValue
						Task {
							await ApiRequest.updateAllowLan(allow: newValue)
							await refreshConfig()
						}
					}
			}
			
			ConfigItemView(name: "Sniffer") {
				Toggle("", isOn: $sniffer)
					.toggleStyle(toggleStyle)
					.onChange(of: sniffer) { newValue in
						guard hasLoadedConfig, !isApplyingConfig else { return }
						ConfigOverride.shared.snifferEnable = newValue
						Task {
							await ApiRequest.updateSniffing(enable: newValue)
							await refreshConfig()
						}
					}
			}
			
			/*
			ConfigItemView(name: "Reload") {
				Button {
					Task {
						await ConfigReloadManager.shared.updateConfig()
					}
				} label: {
					Text("Reload config file")
				}
			}
			 */
			
			ConfigItemView(name: "GEO Databases") {
				Button {
					Task {
						_ = await ApiRequest.updateGEO()
					}
				} label: {
					Text("Update GEO Databases")
				}
			}
			
			ConfigItemView(name: "FakeIP") {
				Button {
                    AppDelegate.shared.flushDNSCache(NSMenuItem())
				} label: {
					Text("Flush dns cache")
				}
			}
		}
	}
}

@MainActor
struct FallbackDNSSettingsView: View {
    @State private var addresses = ConfigOverride.shared.fallbackDNSServers.joined(separator: "\n")
    @State private var savedAddresses = ConfigOverride.shared.fallbackDNSServers.joined(separator: "\n")

    private var parsed: [String]? { ConfigOverride.parseFallbackDNS(addresses) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DNS over HTTPS addresses, one per line.")
                .font(.caption)
                .foregroundColor(.secondary)
            TextEditor(text: $addresses)
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 60)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                .accessibilityLabel(Text("Fallback DNS"))
            HStack {
                Button("Save fallback DNS") {
                    guard let parsed else { return }
                    ConfigOverride.shared.saveFallbackDNS(parsed)
                    addresses = parsed.joined(separator: "\n")
                    savedAddresses = addresses
                }
                .disabled(parsed == nil || addresses == savedAddresses)
                Button("Restore default DNS") {
                    addresses = ConfigOverride.defaultFallbackDNS
                    ConfigOverride.shared.saveFallbackDNS([addresses])
                    savedAddresses = addresses
                }
            }
            Text(LocalizedStringKey(parsed == nil
                 ? "Enter at least one valid HTTPS DNS address."
                 : "Used only when the configuration has no DNS section. Separate from TUN DNS. Saved changes apply the next time a local configuration is loaded."))
                .font(.caption)
                .foregroundColor(parsed == nil ? .red : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct TunStackSettingsView: View {
    @ObservedObject private var settings = TunStackSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !settings.isRemote {
                Picker("TUN IP Stack", selection: Binding(
                    get: { settings.selection },
                    set: { value in Task { await settings.select(value) } }
                )) {
                    ForEach(TunStack.allCases, id: \.self) { stack in
                        Text(stack.title).tag(stack)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .disabled(!settings.canEdit)
            }

            if settings.isApplying {
                Text("Applying…")
                    .font(.caption)
            } else if let stack = settings.currentStack {
                Text(String(format: NSLocalizedString("Current stack: %@", comment: ""), TunStack(rawValue: stack.lowercased())?.title ?? stack))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text(LocalizedStringKey(settings.isRemote
                 ? "TUN stack is read-only in remote control mode."
                 : "Overrides all local configurations. Switching may briefly interrupt connections; when TUN is off, it stays off."))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let error = settings.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(2)
                    .help(error)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

//struct ConfigView_Previews: PreviewProvider {
//    static var previews: some View {
//        ConfigView()
//    }
//}
