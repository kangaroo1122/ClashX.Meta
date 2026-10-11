//
//  AppVersionUtil.swift
//  ClashX
//
//  Created by CYC on 2019/2/18.
//  Copyright © 2019 west2online. All rights reserved.
//

import Cocoa

class AppVersionUtil: NSObject {
    private static let shared = AppVersionUtil()

    private static let kLastVersionNumberKey = "com.clashX.lastVersionNumber"
    private static let kConfigFolderMigrationTipKey = "ClashX_Meta_1.3.0_UpdateTips"
    private static let configFolderMigrationTipInfo = "Config Floder migrated from\n~/.config/clash to\n~/.config/clash.meta"
    private static let configFolderMigrationVersion = "1.3.0"
    private static var hasHandledPostLaunchUpdateTips = false

    private let lastVersionNumber: String?

    static var currentVersion: String {
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    static var currentBuild: String {
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    }

    static var isBeta: Bool {
        return Bundle.main.object(forInfoDictionaryKey: "BETA") as? Bool ?? false
    }

    override init() {
        lastVersionNumber = UserDefaults.standard.string(forKey: AppVersionUtil.kLastVersionNumberKey)
        UserDefaults.standard.set(AppVersionUtil.currentVersion, forKey: AppVersionUtil.kLastVersionNumberKey)
    }

    static var isFirstLaunch: Bool {
        return shared.lastVersionNumber == nil
    }

    static var hasVersionChanged: Bool {
        return shared.lastVersionNumber != currentVersion
    }
}

/// Checks published releases and downloads installers; app replacement remains a user action.
@MainActor
final class GitHubUpdateChecker {
    static let shared = GitHubUpdateChecker()
    private(set) var isChecking = false
    private var installerDownload: InstallerDownloadController?

    private struct Release: Decodable {
        let tag_name: String
        let body: String?
        let html_url: URL
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }

    private struct Asset: Decodable {
        let name: String
        let browser_download_url: URL
        let state: String
        let size: Int64
    }

    /// Numeric suffixes are fork revisions, not prerelease markers:
    /// 1.4.46 < 1.4.46-1 < 1.4.46-2 < 1.4.47.
    /// Release eligibility is determined by GitHub's draft/prerelease flags.
    private struct Version {
        let numbers: [Int]
        let revision: Int

        init?(_ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let version = trimmed.hasPrefix("v") || trimmed.hasPrefix("V") ? String(trimmed.dropFirst()) : trimmed
            guard !version.isEmpty else { return nil }
            let withoutBuild = version.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let parts = withoutBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            guard let base = parts.first else { return nil }
            let components = base.split(separator: ".", omittingEmptySubsequences: false)
            guard !components.isEmpty,
                  components.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }) else { return nil }
            let parsed = components.compactMap { Int($0) }
            guard parsed.count == components.count else { return nil }
            numbers = parsed
            if parts.count > 1 {
                let suffix = parts[1]
                guard !suffix.isEmpty, suffix.allSatisfy({ $0.isASCII && $0.isNumber }),
                      let value = Int(suffix) else { return nil }
                revision = value
            } else {
                revision = 0
            }
        }

        func isNewer(than other: Version) -> Bool {
            for index in 0..<max(numbers.count, other.numbers.count) {
                let lhs = index < numbers.count ? numbers[index] : 0
                let rhs = index < other.numbers.count ? other.numbers[index] : 0
                if lhs != rhs { return lhs > rhs }
            }
            return revision > other.revision
        }
    }

    func checkForUpdates() async {
        if let installerDownload {
            installerDownload.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        guard let repository = Bundle.main.object(forInfoDictionaryKey: "GitHubUpdateRepository") as? String,
              repository.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil,
              let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            showMessage("Update check failed", detail: NSLocalizedString("The update repository is not configured correctly.", comment: ""))
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ClashX-Meta", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if http.statusCode == 404 {
                showMessage("No published release", detail: NSLocalizedString("No public stable release was found in the update repository. Branch build artifacts are not releases.", comment: ""))
                return
            }
            if http.statusCode == 403 || http.statusCode == 429 {
                showMessage("Update check failed", detail: NSLocalizedString("GitHub refused the request or its rate limit was reached. Please try again later.", comment: ""))
                return
            }
            guard http.statusCode == 200 else { throw URLError(.badServerResponse) }
            let release = try JSONDecoder().decode(Release.self, from: data)
            guard !release.draft, !release.prerelease else {
                showMessage("No published release", detail: NSLocalizedString("No public stable release was found in the update repository. Branch build artifacts are not releases.", comment: ""))
                return
            }
            guard let latest = Version(release.tag_name),
                  let current = Version(AppVersionUtil.currentVersion) else {
                showMessage("Update check failed", detail: NSLocalizedString("Unable to compare release versions. Use numeric version tags such as v1.2.3 or v1.2.3-1.", comment: ""))
                return
            }
            guard latest.isNewer(than: current) else {
                showMessage("No newer release", detail: String(format: NSLocalizedString("Current version: %@\nLatest release: %@", comment: ""), AppVersionUtil.currentVersion, release.tag_name))
                return
            }
            present(release, repository: repository)
        } catch {
            showMessage("Update check failed", detail: error.localizedDescription)
        }
    }

    private func present(_ release: Release, repository: String) {
        // Prefer the disk image, but keep downloads working for older ZIP releases.
        let downloadableAssets = release.assets.filter {
            $0.state == "uploaded"
                && isGitHubURL($0.browser_download_url, repository: repository, pathPrefix: "/releases/download/")
        }
        // GitHub may replace spaces with dots in uploaded asset names.
        let dmgNames = ["ClashX Meta.dmg", "ClashX.Meta.dmg"]
        let zipNames = ["ClashX Meta.zip", "ClashX.Meta.zip"]
        let asset = downloadableAssets.first { dmgNames.contains($0.name) }
            ?? downloadableAssets.first { zipNames.contains($0.name) }
        guard isGitHubURL(release.html_url, repository: repository, pathPrefix: "/releases/") else {
            showMessage("Update check failed", detail: NSLocalizedString("The release URL is invalid.", comment: ""))
            return
        }

        let alert = NSAlert()
        alert.messageText = String(format: NSLocalizedString("New version available: %@", comment: ""), release.tag_name)
        if let asset, zipNames.contains(asset.name) {
            alert.informativeText = NSLocalizedString("Download the ZIP, quit ClashX Meta, then unzip and replace the app. Updates are not installed automatically.", comment: "")
        } else {
            alert.informativeText = NSLocalizedString("Download the installer with progress in the app. When it finishes, choose whether to open the DMG and quit ClashX Meta to install it.", comment: "")
        }
        if asset == nil {
            alert.informativeText += "\n" + NSLocalizedString("The release has no matching download yet. Open the release page to check its downloads.", comment: "")
        }
        alert.addButton(withTitle: NSLocalizedString(asset == nil ? "Open release page" : "Download installer", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        if asset != nil { alert.addButton(withTitle: NSLocalizedString("Open release page", comment: "")) }

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 440, height: 230))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let notes = NSTextView(frame: scroll.contentView.bounds)
        notes.isEditable = false
        notes.isRichText = false
        notes.font = .systemFont(ofSize: NSFont.systemFontSize)
        notes.isVerticallyResizable = true
        notes.isHorizontallyResizable = false
        notes.autoresizingMask = [.width]
        notes.textContainer?.widthTracksTextView = true
        let body = release.body ?? ""
        notes.string = body.isEmpty ? NSLocalizedString("No release notes provided.", comment: "") : body
        scroll.documentView = notes
        alert.accessoryView = scroll

        NSApp.activate(ignoringOtherApps: true)
        let result = alert.runModal()
        if result == .alertFirstButtonReturn {
            if let asset, dmgNames.contains(asset.name) {
                let controller = InstallerDownloadController()
                installerDownload = controller
                controller.onFinish = { [weak self] in self?.installerDownload = nil }
                controller.start(url: asset.browser_download_url, expectedSize: asset.size)
            } else {
                open(asset?.browser_download_url ?? release.html_url)
            }
        } else if result == .alertThirdButtonReturn {
            open(release.html_url)
        }
    }

    private func isGitHubURL(_ url: URL, repository: String, pathPrefix: String) -> Bool {
        url.scheme == "https" && url.host == "github.com"
            && url.path.lowercased().hasPrefix("/" + repository.lowercased() + pathPrefix)
    }

    private func open(_ url: URL) {
        if !NSWorkspace.shared.open(url) {
            showMessage("Update check failed", detail: NSLocalizedString("Unable to open the browser.", comment: ""))
        }
    }

    private func showMessage(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString(title, comment: "")
        alert.informativeText = detail
        alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

/// URLSession owns the temporary download; cancellation removes the partial transfer.
private final class InstallerDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let update: @Sendable (Int64, Int64) -> Void

    init(update: @escaping @Sendable (Int64, Int64) -> Void) {
        self.update = update
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        update(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}

@MainActor
private final class InstallerDownloadController: NSWindowController {
    var onFinish: (() -> Void)?
    private var transfer: Task<Void, Never>?
    private let progress = NSProgressIndicator(frame: NSRect(x: 24, y: 76, width: 392, height: 20))
    private let detail = NSTextField(labelWithString: "")

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 160),
                              styleMask: [.titled], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = NSLocalizedString("Download installer", comment: "")
        window.center()
        progress.style = .bar
        progress.minValue = 0
        progress.maxValue = 1
        window.contentView?.addSubview(progress)
        detail.frame = NSRect(x: 24, y: 106, width: 392, height: 24)
        window.contentView?.addSubview(detail)
        let cancel = NSButton(title: NSLocalizedString("Cancel", comment: ""), target: self, action: #selector(cancelDownload))
        cancel.bezelStyle = .rounded
        cancel.frame = NSRect(x: 312, y: 20, width: 104, height: 32)
        window.contentView?.addSubview(cancel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func start(url: URL, expectedSize: Int64) {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        transfer = Task { [self] in
            defer {
                transfer = nil
                close()
                onFinish?()
            }
            while !Task.isCancelled {
                do {
                    let file = try await download(url: url, expectedSize: expectedSize)
                    try Task.checkCancellation()
                    window?.orderOut(nil)
                    offerInstallation(file)
                    return
                } catch {
                    if Task.isCancelled { return }
                    let alert = NSAlert()
                    alert.messageText = NSLocalizedString("Installer download failed", comment: "")
                    alert.informativeText = error.localizedDescription
                    alert.addButton(withTitle: NSLocalizedString("Retry download", comment: ""))
                    alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                }
            }
        }
    }

    @objc private func cancelDownload() {
        transfer?.cancel()
    }

    private func download(url: URL, expectedSize: Int64) async throws -> URL {
        progress.isIndeterminate = true
        progress.startAnimation(nil)
        detail.stringValue = NSLocalizedString("Connecting to download…", comment: "")
        let delegate = InstallerDownloadProgress { [weak self] received, expected in
            Task { @MainActor [weak self] in
                guard let self, self.transfer?.isCancelled == false else { return }
                self.progress.isIndeterminate = expected <= 0
                let receivedText = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
                if expected > 0 {
                    self.progress.stopAnimation(nil)
                    self.progress.doubleValue = min(1, Double(received) / Double(expected))
                    let total = ByteCountFormatter.string(fromByteCount: expected, countStyle: .file)
                    self.detail.stringValue = "\(Int(self.progress.doubleValue * 100))% — \(receivedText) / \(total)"
                } else {
                    self.detail.stringValue = receivedText
                }
            }
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("ClashX-Meta", forHTTPHeaderField: "User-Agent")
        let (temporary, response) = try await session.download(for: request, delegate: delegate)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              response.url?.scheme == "https" else { throw URLError(.badServerResponse) }
        let manager = FileManager.default
        let attributes = try manager.attributesOfItem(atPath: temporary.path)
        guard expectedSize > 0,
              (attributes[.size] as? NSNumber)?.int64Value == expectedSize else {
            throw URLError(.cannotDecodeContentData)
        }
        let downloads = try manager.url(for: .downloadsDirectory, in: .userDomainMask,
                                        appropriateFor: nil, create: true)
        let directory = downloads.appendingPathComponent("ClashX Meta", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("ClashX.Meta.dmg")
        let staging = directory.appendingPathComponent(UUID().uuidString + ".download")
        defer { try? manager.removeItem(at: staging) }
        try manager.moveItem(at: temporary, to: staging)
        try Task.checkCancellation()
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: staging)
        } else {
            try manager.moveItem(at: staging, to: destination)
        }
        return destination
    }

    private func offerInstallation(_ file: URL) {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Installer download complete", comment: "")
        alert.informativeText = NSLocalizedString("Install now opens the DMG and quits ClashX Meta. Drag the app into Applications to finish replacing it. The installer is saved at:", comment: "") + "\n" + file.path
        alert.addButton(withTitle: NSLocalizedString("Install now", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Install later", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Show in Finder", comment: ""))
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if NSWorkspace.shared.open(file) {
                NSApp.terminate(nil)
            } else {
                let failure = NSAlert()
                failure.messageText = NSLocalizedString("Unable to open installer", comment: "")
                failure.informativeText = file.path
                failure.runModal()
                NSWorkspace.shared.activateFileViewerSelecting([file])
            }
        case .alertThirdButtonReturn:
            NSWorkspace.shared.activateFileViewerSelecting([file])
        default:
            break
        }
    }
}

extension AppVersionUtil {
    @MainActor
    static func showUpgradeAlert() async {
        guard !hasHandledPostLaunchUpdateTips,
              let lastVersion = shared.lastVersionNumber,
              hasVersionChanged else { return }

        hasHandledPostLaunchUpdateTips = true
        await WebCacheCleaner.clean()

        guard lastVersion.compare(configFolderMigrationVersion, options: .numeric) == .orderedAscending,
              !UserDefaults.standard.bool(forKey: kConfigFolderMigrationTipKey) else { return }

        UserDefaults.standard.set(true, forKey: kConfigFolderMigrationTipKey)

        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Update Tips", comment: "")
        alert.informativeText = configFolderMigrationTipInfo
        alert.alertStyle = .informational
        alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
        alert.runModal()
    }
}
