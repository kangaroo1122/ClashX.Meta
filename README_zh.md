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
