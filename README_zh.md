<h1 align="center">
  <img src="https://github.com/MetaCubeX/mihomo/raw/Meta/Meta.png" alt="Clash" width="200">
  <br>
  ClashX Meta
  <br>
</h1>

基于 [Mihomo](https://wiki.metacubex.one/) 的 macOS 规则代理工具。

## 注意
- ClashX / ClashX Pro / ClashX Meta 只是一个代理工具，不提供任何代理服务器。如果服务器不可用，或遇到续费相关问题，请联系你的服务提供商。
- ClashX / ClashX Pro / ClashX Meta 目前没有官网。凡是声称是官方站点的，都是骗子。

## 功能

- Mihomo Core
- 支持 Tun 模式

## 安装

可以从 [Release](https://github.com/MetaCubeX/Clash.Meta/releases) 页面下载。

## 构建

- 安装 GH
  ```
  brew install gh
  ```

- 下载依赖
  ```
  bash install_dependency.sh
  ```

- 编译并运行。

## 应用更新

菜单中的“检查更新”会检查当前 fork 的 GitHub 正式 Release，并显示新版说明。
点击“下载安装包”后，应用内显示 DMG 下载进度，支持取消和失败后重试。完成的安装包固定保存为 `~/Downloads/ClashX.Meta.dmg`，下载成功并校验大小后覆盖旧安装包；下载失败或取消时保留旧文件。
下载完成可选择“立即安装”“稍后安装”或“在 Finder 中显示”。立即安装会打开 DMG，再正常退出应用；将应用拖入映像内的 Applications 快捷方式并确认替换，完成后重新打开应用。下载期间使用系统临时文件，保存时使用 `.download` 后缀，完成后改为 `.dmg`。
分支构建的 Artifact 下载后为 `ClashX-Meta-artifact.zip`，解压即可得到 DMG；Release 附件直接提供 DMG。旧版 ZIP 附件仍可通过更新检查下载。
应用不会自动安装更新，也不会把 Actions Artifact 作为正式版本。

GitHub Actions 保留分支构建只上传 Artifact、`v*` 标签构建发布 Release 的行为，标签构建默认标记为 **Pre-release**。
验证后，在 GitHub 编辑该 Release，取消预发布标记并设为 **Latest**，客户端才会将其作为最新正式版检查。
客户端使用 GitHub 的最新正式 Release 接口，忽略预发布和草稿。数字后缀表示修订号，例如 `v1.4.46 < v1.4.46-1 < v1.4.46-2 < v1.4.47`；同版本不会重复提示，也不会提示降级。
更新功能无需 `ED_KEY` 或更新订阅文件；CI 会将当前仓库名称写入 `GitHubUpdateRepository`。
本地构建时该字段位于 `ClashX/Info.plist`。版本标签请使用递增的数字版本，例如 `v1.3.1` 或 `v1.3.1-1`。

## 配置

默认配置目录是 `$HOME/.config/clash.meta`

TUN 协议栈默认使用 System，仍可在 Meta 设置中选择其他协议栈或“跟随配置文件”；已有的手动协议栈选择会保留。独立的“TUN IPv6”开关默认关闭，此时运行配置设置 `inet6-address: []`，只接管 IPv4，与本机 ClashX Pro 的增强模式行为对齐。开启后为 TUN 配置 IPv6 地址，仍受内核全局 IPv6 设置限制；切换会重载配置，保留 TUN 启停状态，失败时回退；不关闭 macOS 的 IPv6，也不覆盖订阅自带的 DNS 设置。升级后请退出旧版再启动新版，重新开启 TUN，以释放旧网卡和路由。

本地运行的配置（包括远程订阅）若完全没有 `dns` 字段，应用会在临时运行配置中补充以下 DNS 设置，原配置文件不变。已有 `dns` 时原样保留，包括显式关闭、空对象或 `null`，不会合并或覆盖其中的字段：

```yaml
dns:
  enable: true
  ipv6: false
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  nameserver:
    - https://dns.alidns.com/dns-query
```

可在设置 → Meta → DNS 覆写 中修改上述 nameserver 地址（DNS over HTTPS，每行一个），点击统一的“保存 DNS 设置”后，在下次加载本地配置时生效；“恢复默认”同时将 DNS 1 设为 `8.8.8.8`、清空 DNS 2，并将 DNS 覆写填回默认地址，仍需点击保存，不影响 TUN 协议栈或 IPv6 开关。已有 DNS 配置不受影响。

默认配置文件名是 `config.yaml`。你也可以使用自定义配置名，并在菜单的 `Config` 栏中切换配置。

### 自有节点

通过菜单 → **自有节点**，将个人节点加入订阅中的策略组，无需修改订阅文件。

1. 导入分享链接或节点 YAML，预览后确认导入。
2. 选择节点，编辑参数，并在“策略组关联”中勾选目标配置和策略组。
3. 点击“保存并应用”。订阅更新后会自动重新加入；目标组改名或删除时需重新关联。

支持 VLESS、VMess、Shadowsocks、Trojan、Hysteria2（`hy2://`）、TUIC v5，以及 HTTP / HTTPS / SOCKS5 链接。支持新建、复制、停用、删除、测速和导出分享链接或 YAML；链接无法完整表达的高级参数请使用 YAML，具体支持取决于当前内核。测速需先将节点应用到当前本地配置。

节点按关联加入策略组，自动收集节点的组仍受原有筛选条件限制。使用链式代理时，依赖节点必须启用；删除前需先解除引用。

### 自定义代理与规则

通过菜单 → **自定义代理与规则**，管理公司内网等场景的代理和分流，配置独立于订阅保存。

- **代理**：HTTP / SOCKS5，支持认证、TLS 和独立测速网址。
- **代理组**：手动选择、自动回退、最低延迟，支持嵌套与健康检查。
- **规则**：域名、IP 网段、进程名和规则集，可指定代理出口、DIRECT 或 REJECT。

启用后点击“保存并应用”。在规则模式下，自定义规则优先匹配，未命中时继续使用订阅规则。订阅更新不会覆盖这些设置，订阅的自动节点组也不会自动选入内网代理。此入口不导入 DNS、端口或 TUN 设置。

内网代理可将测速网址设为可访问的内网服务。测速失败只表示该网址不可达，不代表所有内网服务都不可用。内核停止或远程控制期间只保存设置，下次加载本地配置时应用。

#### 按场景切换规则

在“自定义规则”中创建分组，通过状态栏 → **规则分组** 快速启用或停用。分组不改变规则顺序；未分组规则始终参与匹配，删除分组会将其规则移到“未分组”（均受自定义配置总开关控制）。

例如，将“远程办公”代理规则排在内网 DIRECT 规则之前：在家启用，到公司停用。**停用分组只是跳过其规则，不会自动直连**，需保留后续 DIRECT 规则。窗口内的修改需保存；菜单快捷切换要求本地内核运行、配置已应用且没有未保存草稿。

#### 迁移与备份

在“自定义代理与规则”窗口选择“导出配置…”，到另一台机器“导入配置…”，确认后点击“保存并应用”。导出包含当前编辑内容，包括代理、代理组、规则、规则分组及规则集；导入会整份替换草稿。仅支持本功能的 v2 JSON 格式，不包含订阅、全局设置或自有节点。本机旧配置会自动迁移。

两类配置分别保存在 `~/.config/clash.meta/` 下：

| 配置 | 文件 |
| --- | --- |
| 自有节点及策略组关联 | `personal-nodes.json` |
| 自定义代理与规则 | `custom-proxies.json` |

文件仅当前用户可读写，不随 iCloud 同步。配置及导出文件包含**未加密的节点凭据**，请妥善保管。文件损坏时，可使用窗口提供的备份与重置／停用操作保留原文件。

更多细节请查看 [Mihomo wiki](https://wiki.metacubex.one/)。

## 进阶配置

### 修改 ClashX 端口

请修改 ClashX 生成的 `config.yaml`，不要修改你自己创建或下载的其他配置文件。自定义配置文件里的 `General` 相关设置会被忽略。修改后重新启动 ClashX 生效。

### 修改状态栏图标

把图标文件放到 `~/.config/clash.meta/menuImage.png`，然后重启 ClashX。

### 修改默认系统忽略列表

- 菜单 -> Config -> Setting -> Bypass proxy settings for these Hosts & Domains

### URL Schemes（可能不可用）

- 使用 URL Scheme 导入远程配置

  ```
  clash://install-config?url=http%3A%2F%2Fexample.com&name=example
  ```

- 使用 URL Scheme 重新加载当前配置

  ```
  clash://update-config
  ```

## FAQ

- Q: 如何获取外网 IP 的 shell 命令？  
  A: 点击 ClashX 菜单图标，然后按 `Option-Command-C`

## 关闭 ClashX 通知

1. 在系统设置中关闭 ClashX 的通知权限。
2. 在菜单栏 -> Config -> More Settings 中勾选减少通知。

注意：强烈不建议这么做，这可能导致 ClashX 的很多重要错误提醒无法显示。

## 全局快捷键
- 在菜单栏 -> Config -> More Config 中，自定义对应功能的快捷键。（需要 v1.2.6 之后的版本）
- 使用 AppleScript 设置，详情见 [全局快捷键](Shortcuts.md)
