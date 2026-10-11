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

/// Checks published releases only. Downloading and replacing the app remain user actions.
@MainActor
final class GitHubUpdateChecker {
    static let shared = GitHubUpdateChecker()
    private(set) var isChecking = false

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
            alert.informativeText = NSLocalizedString("Download and open the DMG, quit ClashX Meta, then drag the app into Applications to replace it. Updates are not installed automatically.", comment: "")
        }
        if asset == nil {
            alert.informativeText += "\n" + NSLocalizedString("The release has no matching download yet. Open the release page to check its downloads.", comment: "")
        }
        alert.addButton(withTitle: NSLocalizedString(asset == nil ? "Open release page" : "Download", comment: ""))
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
            open(asset?.browser_download_url ?? release.html_url)
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
