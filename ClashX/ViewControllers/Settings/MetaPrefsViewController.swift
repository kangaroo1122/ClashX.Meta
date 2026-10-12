//
//  MetaPrefsViewController.swift
//  ClashX Meta
//
//  Copyright © 2023 west2online. All rights reserved.
//

import Cocoa
import Network
import SwiftUI

class MetaPrefsViewController: NSViewController {
	// Meta Setting
	@IBOutlet var hideUnselectableButton: NSButton!
	
	@IBAction func hideUnselectable(_ sender: NSButton) {
		var newState = NSControl.StateValue.off
		switch sender.state {
		case .off:
			newState = .mixed
		case .mixed:
			newState = .on
		case .on:
			newState = .off
		default:
			return
		}

		sender.state = newState
		MenuItemFactory.hideUnselectable = newState.rawValue
	}
	
	@IBOutlet var tunDNSTextField: NSTextField!
    private let tunDNS2TextField = NSTextField(string: "")
    private let tunDNSErrorLabel = NSTextField(wrappingLabelWithString: "")
    private var tunDNSMessageRow: NSGridRow?
    private let dnsOverrideDraft = DNSOverrideDraft()

    @objc private func restoreDNSDefaults() {
        tunDNSTextField.stringValue = ConfigManager.defaultTunDNS
        tunDNS2TextField.stringValue = ""
        dnsOverrideDraft.addresses = ConfigOverride.defaultFallbackDNS
        tunDNSMessageRow?.isHidden = true
        resizeToFitContent()
    }

    @objc private func saveDNSSettings() {
        let first = tunDNSTextField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let second = tunDNS2TextField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard IPv4Address(first) != nil else {
            showTunDNSMessage(NSLocalizedString("DNS 1 requires a valid IPv4 address.", comment: ""), isError: true)
            return
        }
        guard second.isEmpty || IPv4Address(second) != nil else {
            showTunDNSMessage(NSLocalizedString("DNS 2 must be empty or a valid IPv4 address.", comment: ""), isError: true)
            return
        }
        guard let overrideAddresses = dnsOverrideDraft.parsed else {
            showTunDNSMessage(NSLocalizedString("Enter at least one valid HTTPS DNS address.", comment: ""), isError: true)
            return
        }
        let addresses = second.isEmpty || second == first ? [first] : [first, second]
        ConfigManager.metaTunDNS = addresses.joined(separator: ", ")
        ConfigOverride.shared.saveFallbackDNS(overrideAddresses)
        dnsOverrideDraft.addresses = overrideAddresses.joined(separator: "\n")
        tunDNSTextField.stringValue = addresses[0]
        tunDNS2TextField.stringValue = addresses.count > 1 ? addresses[1] : ""
        showTunDNSMessage(NSLocalizedString("DNS settings saved. Re-enable TUN for system DNS changes; reload the configuration for DNS override changes.", comment: ""), isError: false)
        updateNeedsRestart()
    }

    private func showTunDNSMessage(_ message: String, isError: Bool) {
        tunDNSErrorLabel.stringValue = message
        tunDNSErrorLabel.textColor = isError ? .systemRed : .secondaryLabelColor
        tunDNSMessageRow?.isHidden = false
        resizeToFitContent()
    }

    private func resizeToFitContent() {
        view.layoutSubtreeIfNeeded()
        view.setFrameSize(NSSize(width: view.frame.width, height: view.fittingSize.height))
        preferredContentSize = view.frame.size
    }

	// Dashboard
	@IBOutlet var useSwiftuiButton: NSButton!
	@IBOutlet var useYacdButton: NSButton!
	@IBOutlet var useXDButton: NSButton!
    @IBOutlet var useZashButton: NSButton!
    
    
    @IBAction func switchDashboard(_ sender: NSButton) {
		switch sender {
		case useSwiftuiButton:
			DashboardManager.shared.useSwiftUI = sender.state == .on
		case useYacdButton:
            ConfigManager.webDashboard = .yacd
		case useXDButton:
            ConfigManager.webDashboard = .metacubexd
        case useZashButton:
            ConfigManager.webDashboard = .zashboard
		default:
			break
		}
		initDashboardButtons()
		updateNeedsRestart()
	}
	
	// Alpha Core
	@IBOutlet var useAlphaButton: NSButton!
	@IBOutlet var alphaVersionTextField: NSTextField!
	@IBOutlet var updateButton: NSButton!
	@IBOutlet var updateProgressIndicator: NSProgressIndicator!
	@IBOutlet var showAlphaButton: NSButton!
	

	@IBAction func useAlphaMeta(_ sender: NSButton) {
		if UserDefaults.standard.object(forKey: "useAlphaCore") as? Bool == nil {
			let alert = NSAlert()
			alert.messageText = NSLocalizedString("Alpha Meta core Warning", comment: "")
			alert.alertStyle = .warning
			alert.addButton(withTitle: NSLocalizedString("Continue", comment: ""))
			alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
			if alert.runModal() != .alertFirstButtonReturn {
				return
			}
		}

		let use = sender.state == .on
		ConfigManager.useAlphaCore = use
		updateNeedsRestart()
	}
	
	@IBAction func updateAlpha(_ sender: NSButton) {
		sender.isEnabled = false
		updateProgressIndicator.isHidden = false
		updateProgressIndicator.startAnimation(nil)
		
		let dl = AlphaMetaDownloader.self
		
		Task {
			do {
                let assets = try await dl.alphaAssets()
				let asset = try await dl.alphaCoreAsset(assets)
				let ver = try dl.checkVersion(asset)
				let data = try await dl.downloadCore(ver)
                let checksum = try await dl.checksumString(assets, asset: asset)
                let newVer = try dl.replaceCore(data, checksum: checksum)
				
				await MainActor.run {
					self.updateAlphaVersion(newVer)
					let msg = NSLocalizedString("Version: ", comment: "") + newVer
					UserNotificationCenter.shared.postNotificationAlert(title: "Clash Meta Core", info: msg)
				}
			} catch {
				UserNotificationCenter.shared.postNotificationAlert(title: "Clash Meta Core", info: error.localizedDescription)
			}
			
			await MainActor.run {
				sender.isEnabled = true
				self.updateProgressIndicator.isHidden = true
				self.updateProgressIndicator.stopAnimation(nil)
			}
		}
	}
	
	@IBAction func showAlphaInFinder(_ sender: NSButton) {
		guard let u = Paths.alphaCorePath(),
			  FileManager.default.fileExists(atPath: u.path) else { return }
		NSWorkspace.shared.activateFileViewerSelecting([u])
	}
	
	
	@IBOutlet var restartTextField: NSTextField!
	
	var prefsSnapshot = [String]()
	var versionSnapshot = "none"
	var alphaCoreUpdated = false
	
	override func viewDidLoad() {
        super.viewDidLoad()
		// Meta Setting
		hideUnselectableButton.state = .init(rawValue: MenuItemFactory.hideUnselectable)
		
        tunDNSTextField.placeholderString = ConfigManager.defaultTunDNS
        tunDNS2TextField.placeholderString = NSLocalizedString("Optional", comment: "")
        let addresses = ConfigManager.metaTunDNS.replacingOccurrences(of: "，", with: ",")
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        tunDNSTextField.stringValue = addresses.first ?? ""
        // Preserve extra legacy entries visibly until the user explicitly saves.
        tunDNS2TextField.stringValue = addresses.dropFirst().joined(separator: ", ")

		// Dashboard
		initDashboardButtons()
		
		// Alpha Core
		useAlphaButton.state = ConfigManager.useAlphaCore ? .on : .off
		updateProgressIndicator.isHidden = true
		setAlphaVersion()
		
		// Snapshot
		prefsSnapshot = takePrefsSnapshot()
		versionSnapshot = alphaVersionTextField.stringValue
		restartTextField.isHidden = true
        setupTunStackPicker()
    }

    private func setupTunStackPicker() {
        // Reuse the exact same control/state as the native dashboard.
        var ancestor = tunDNSTextField.superview
        while ancestor != nil && !(ancestor is NSGridView) {
            ancestor = ancestor?.superview
        }
        guard let grid = ancestor as? NSGridView else { return }
        grid.constraints.filter { $0.firstAttribute == .height && $0.secondItem == nil }
            .forEach { $0.isActive = false }

        // Keep the editable field tall enough for its bezel and field editor
        // when the surrounding grid is fitted to its content.
        tunDNSTextField.setContentCompressionResistancePriority(.required, for: .vertical)
        tunDNSTextField.heightAnchor.constraint(
            greaterThanOrEqualToConstant: max(24, tunDNSTextField.intrinsicContentSize.height)
        ).isActive = true

        (grid.cell(atColumnIndex: 0, rowIndex: 1).contentView as? NSTextField)?.stringValue = NSLocalizedString("DNS 1", comment: "")
        grid.cell(atColumnIndex: 0, rowIndex: 2).contentView = NSTextField(labelWithString: NSLocalizedString("DNS 2 (optional)", comment: ""))
        grid.cell(atColumnIndex: 1, rowIndex: 2).contentView = tunDNS2TextField
        grid.row(at: 2).yPlacement = .center
        tunDNS2TextField.translatesAutoresizingMaskIntoConstraints = false
        tunDNS2TextField.widthAnchor.constraint(equalTo: tunDNSTextField.widthAnchor).isActive = true
        tunDNS2TextField.heightAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true
        tunDNS2TextField.setContentCompressionResistancePriority(.required, for: .vertical)
        tunDNSTextField.nextKeyView = tunDNS2TextField

        let hint = NSTextField(wrappingLabelWithString: NSLocalizedString("System DNS used while TUN is enabled. Save, then re-enable TUN to apply.", comment: ""))
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        hint.widthAnchor.constraint(equalToConstant: 270).isActive = true
        grid.addRow(with: [NSGridCell.emptyContentView, hint]).yPlacement = .top
        let dnsLabel = NSTextField(labelWithString: NSLocalizedString("DNS override", comment: ""))
        let dnsControl = NSHostingView(rootView: FallbackDNSSettingsView(draft: dnsOverrideDraft)
            .frame(width: 270, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true))
        dnsControl.translatesAutoresizingMaskIntoConstraints = false
        dnsControl.setContentHuggingPriority(.required, for: .vertical)
        dnsControl.setContentCompressionResistancePriority(.required, for: .vertical)
        grid.addRow(with: [dnsLabel, dnsControl]).yPlacement = .top
        dnsControl.widthAnchor.constraint(equalToConstant: 270).isActive = true
        let saveButton = NSButton(title: NSLocalizedString("Save DNS settings", comment: ""), target: self, action: #selector(saveDNSSettings))
        let restoreButton = NSButton(title: NSLocalizedString("Restore default DNS", comment: ""), target: self, action: #selector(restoreDNSDefaults))
        let dnsActions = NSStackView(views: [saveButton, restoreButton])
        dnsActions.orientation = .horizontal
        dnsActions.spacing = 8
        grid.addRow(with: [NSGridCell.emptyContentView, dnsActions])

        tunDNSErrorLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        tunDNSErrorLabel.widthAnchor.constraint(equalToConstant: 270).isActive = true
        tunDNSMessageRow = grid.addRow(with: [NSGridCell.emptyContentView, tunDNSErrorLabel])
        tunDNSMessageRow?.yPlacement = .top
        tunDNSMessageRow?.isHidden = true

        let label = NSTextField(labelWithString: NSLocalizedString("TUN IP Stack", comment: ""))
        let control = NSHostingView(rootView: TunStackSettingsView()
            .frame(width: 270, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true))
        control.translatesAutoresizingMaskIntoConstraints = false
        control.setContentHuggingPriority(.required, for: .vertical)
        control.setContentCompressionResistancePriority(.required, for: .vertical)
        let row = grid.addRow(with: [label, control])
        row.yPlacement = .top
        control.widthAnchor.constraint(equalToConstant: 270).isActive = true

        // Keep rows at their content height instead of stretching them to fill
        // an arbitrarily enlarged preferences window.
        grid.setContentHuggingPriority(.required, for: .vertical)
        resizeToFitContent()
    }
	
	func initDashboardButtons() {
		let useSwiftUI = DashboardManager.shared.useSwiftUI
		let dashboard = ConfigManager.webDashboard
		
        useSwiftuiButton.isEnabled = true
		useSwiftuiButton.state = useSwiftUI ? .on : .off
        
        let buttons = [useYacdButton, useXDButton, useZashButton]
        
        buttons.forEach {
            $0?.state = .off
            $0?.isEnabled = !useSwiftUI
        }
        
        switch dashboard {
        case .yacd:
            useYacdButton.state = .on
        case .metacubexd:
            useXDButton.state = .on
        case .zashboard:
            useZashButton.state = .on
        }
	}
	
	func setAlphaVersion() {
		if let alphaCorePath = Paths.alphaCorePath(),
		   let v = ClashProcess.verifyCoreFile(alphaCorePath.path)?.version {
			updateAlphaVersion(v)
		} else {
			updateAlphaVersion(nil)
		}
	}
	
	func updateAlphaVersion(_ version: String?) {
		let enable = version != nil
		useAlphaButton.isEnabled = enable
		showAlphaButton.isEnabled = enable
		if let v = version {
			alphaVersionTextField.stringValue = v
			updateButton.title = NSLocalizedString("Update Alpha Meta core", comment: "")
		} else {
			alphaVersionTextField.stringValue = "none"
			updateButton.title = NSLocalizedString("Download Meta core", comment: "")
		}
		
		if let v = version,
		   versionSnapshot != "none",
		   v != versionSnapshot {
			alphaCoreUpdated = true
			updateNeedsRestart()
		}
	}
	
	func takePrefsSnapshot() -> [String] {
		[
			ConfigManager.metaTunDNS,
            ConfigManager.webDashboard.rawValue,
			"\(ConfigManager.useAlphaCore)"
		]
	}
	
	func updateNeedsRestart() {
		let needsRestart = prefsSnapshot != takePrefsSnapshot() || alphaCoreUpdated
		restartTextField.isHidden = !needsRestart
	}
}
