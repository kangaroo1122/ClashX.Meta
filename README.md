<h1 align="center">
  <img src="https://github.com/MetaCubeX/mihomo/raw/Meta/Meta.png" alt="Clash" width="200">
  <br>
  ClashX Meta
  <br>
</h1>

A rule based proxy for Mac based on [Mihomo](https://wiki.metacubex.one/).

[中文 README](README_zh.md)

## Note
- ClashX / ClashX Pro / ClashX Meta is only a proxy tool and does not provide any proxy servers. If the server is unavailable or you have renewal-related issues, please contact your provider.
- ClashX / ClashX Pro / ClashX Meta does not have an official website. Any site claiming to be the official one is a scam.

## Features

- Mihomo Core
- Tun mode support

## Install

You can download from the [Release](https://github.com/MetaCubeX/Clash.Meta/releases) page.

## Build

- Install GH
  ```
  brew install gh
  ```

- Download deps
  ```
  bash install_dependency.sh
  ```

- Build and run.

## App updates

The “Check Update” menu item checks the current fork's stable GitHub Releases and displays release notes.
“Download installer” downloads the DMG in the app, with progress, cancellation and retry. Completed installers are saved as `~/Downloads/ClashX.Meta.dmg`, replacing the previous installer after a successful download and size check. Failed or cancelled downloads preserve the previous file.
After downloading, choose “Install now”, “Install later”, or “Show in Finder”. Installing opens the DMG and quits the app through its normal cleanup flow. Drag the app onto the image's Applications shortcut and confirm replacement, then reopen it. Transfers use system temporary storage and a `.download` staging file before the completed `.dmg` is saved.
Branch artifacts download as `ClashX-Meta-artifact.zip` containing the DMG; Release assets provide the DMG directly. The update checker also supports older ZIP releases.
Updates are not installed automatically, and Actions artifacts are not treated as releases.

GitHub Actions still uploads only an Artifact for branch builds and publishes a Release for `v*` tag builds, marked **Pre-release** by default.
After verification, edit the release on GitHub, clear the prerelease flag and set it as **Latest** to make it available to the update checker.
The app uses GitHub's latest stable release endpoint and ignores drafts and prereleases. Numeric suffixes are revision numbers, ordered as `v1.4.46 < v1.4.46-1 < v1.4.46-2 < v1.4.47`; equal or older versions do not trigger an update prompt.
No `ED_KEY` or update feed is needed. CI writes the current repository into `GitHubUpdateRepository`;
for local builds, this value lives in `ClashX/Info.plist`. Use increasing numeric release tags such as `v1.3.1` or `v1.3.1-1`.

## Config

The default configuration directory is `$HOME/.config/clash.meta`

TUN defaults to the System stack. Existing explicit stack selections are preserved, and other stacks or “Follow configuration” remain available in Meta settings. The separate TUN IPv6 toggle defaults to off (`tun.inet6-address: []`), matching the observed IPv4-only ClashX Pro setup. Enabling it assigns a TUN IPv6 address, subject to the core global IPv6 setting. Changes reload the configuration while preserving TUN enablement and roll back on failure. This does not disable macOS IPv6 or override profile DNS settings. Quit the old app before launching the update and re-enabling TUN to release the old interface and routes.

When a locally loaded configuration (including a remote subscription) has no `dns` field at all, the app adds the following DNS settings to the temporary runtime configuration, leaving the source file unchanged. An existing `dns` field is preserved as-is, including an explicitly disabled section, an empty mapping or `null`; its fields are not merged or overwritten:

```yaml
dns:
  enable: true
  ipv6: false
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  nameserver:
    - https://dns.alidns.com/dns-query
```

Edit these nameserver addresses under Settings → Meta → DNS Override (one DNS-over-HTTPS URL per line), then click “Save DNS Settings”. They take effect the next time a local configuration is loaded. “Restore Defaults” also sets DNS 1 to `8.8.8.8`, clears DNS 2 and restores the default DNS override address; you still need to save. It does not change the TUN stack or IPv6 toggle. Existing DNS configuration is unaffected.

The default configuration file name is `config.yaml`. You can use your custom config name and switch config in the menu `Config` section.

### Personal nodes

Open **Personal nodes** from the menu to add your own nodes to subscription strategy groups without editing subscription files.

1. Import sharing links or node YAML, review the preview, and confirm.
2. Select a node, edit its settings, and choose target configurations and strategy groups.
3. Click “Save and apply”. Associations are reapplied after subscription updates; renamed or deleted groups need reassignment.

Supported links include VLESS, VMess, Shadowsocks, Trojan, Hysteria2 (`hy2://`), TUIC v5, and HTTP / HTTPS / SOCKS5. Create, duplicate, disable, delete, test, or export nodes as links or YAML. Use YAML for advanced options that links cannot fully represent; support depends on the installed core. Testing requires the node to be applied to the current local configuration.

Nodes join their associated groups; automatic groups still apply their existing filters. Dialer dependencies must be enabled, and references must be removed before deleting a referenced node.

### Custom proxies and rules

Open **Custom proxies and rules** from the menu to manage work-network proxies and routing independently of subscriptions.

- **Proxies**: HTTP / SOCKS5, with authentication, TLS, and individual test URLs.
- **Proxy groups**: manual selection, automatic fallback, and lowest latency, with nesting and health checks.
- **Rules**: domains, IP networks, process names, and rule sets, targeting a proxy, DIRECT, or REJECT.

Enable the feature and click “Save and apply”. In Rule mode, custom rules run before subscription rules; unmatched traffic continues through the subscription. Subscription updates preserve these settings, and automatic subscription groups exclude work proxies. This editor does not import DNS, port, or TUN settings.

For work proxies, set the test URL to a reachable internal service. A failed test only means that URL is unreachable, not that all internal services are unavailable. When the core is stopped or remote control is active, settings are saved and applied the next time a local configuration is loaded.

#### Switch rules by scenario

Create groups in Custom rules, then toggle them through **Rule groups** in the status menu. Grouping preserves rule order. Ungrouped rules always participate, and deleting a group moves its rules to Ungrouped, subject to the overall custom configuration switch.

For example, place “Remote work” proxy rules before internal DIRECT rules: enable the group at home and disable it at the office. **Disabling a group skips its rules; it does not force direct routing.** Keep the subsequent DIRECT rules. Window edits require saving; menu shortcuts require a running local core, applied settings, and no unsaved draft.

#### Migration and backup

Choose “Export configuration…” in Custom proxies and rules, then “Import configuration…” on another machine, confirm, and click “Save and apply”. Export includes the current editor contents: proxies, proxy groups, rules, rule groups, and rule sets. Import replaces the entire draft. Only this feature’s v2 JSON format is accepted; subscriptions, global settings, and personal nodes are excluded. Existing local settings migrate automatically.

The two configurations are stored separately under `~/.config/clash.meta/`:

| Configuration | File |
| --- | --- |
| Personal nodes and strategy group associations | `personal-nodes.json` |
| Custom proxies and rules | `custom-proxies.json` |

Files have owner-only permissions and do not sync through iCloud. Settings and exports contain **unencrypted node credentials**; store them securely. If a file becomes unreadable, use the editor’s backup and reset/disable action to preserve the original.

Checkout the [Mihomo wiki](https://wiki.metacubex.one/) for more details.

## Advance Config

### Change the ports of ClashX

Please modify the `config.yaml` file generated by ClashX, not the other config file you created or downloaded. The `General` section settings in your custom config file will be ignored. Then relaunch ClashX to apply changes.

### Change your status menu icon

Place your icon file in `~/.config/clash.meta/menuImage.png` then restart ClashX.

### Change default system ignore list

- Change by menu -> Config -> Setting -> Bypass proxy settings for these Hosts & Domains

### URL Schemes (May not work)

- Use URL scheme to import remote config.

  ```
  clash://install-config?url=http%3A%2F%2Fexample.com&name=example
  ```

- Use URL scheme to reload current config.

  ```
  clash://update-config
  ```

## FAQ

- Q: How to get shell command with external IP?  
  A: Click the ClashX menu icon and then press `Option-Command-C`

## Disable ClashX notifications

1. Disable ClashX notification permissions in System Settings.
2. Check Reduce Notifications in the menu bar -> Config -> More Settings.

Note: This is strongly discouraged, because it may prevent many important error notifications from showing.

## Global hotkeys
- Customize hotkeys for corresponding features in the menu bar -> Config -> More Config. (Requires version v1.2.6 or later)
- Set via AppleScript, see [Global Hotkeys](Shortcuts.md)
