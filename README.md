# Orbit

Orbit 是使用 SwiftUI 构建的 macOS 磁盘清理与系统监测工具，提供缓存扫描、软件管理、目录分析、系统维护和温控。扫描结果按“推荐清理”和“需要你决定”分组，每项说明用途与清理后果；普通文件移入废纸篓后可在清理记录中恢复。

![Orbit 主界面](docs/orbit-preview.png)

## 功能

| 页面 | 功能 |
| --- | --- |
| 清理 | 应用、浏览器、通讯与开发缓存，旧安装包、项目构建产物，搜索与逐项选择，独立 AI 工具清理 |
| 软件 | 应用清单、关联数据与残留审阅、官方更新源检查、更新安装与回退、个人启动项管理 |
| 优化 | 17 项系统维护检查、DNS 与 Quick Look 操作、定时常亮、屏幕清洁模式 |
| 分析 | 目录树图、文件夹下钻、大文件列表、隐藏项、名称与大小排序 |
| 状态 | CPU、内存、交换空间、磁盘与网络、进程、电池、温度与风扇、菜单栏指标 |

运行要求为 macOS 14 或更新版本。温度传感器与风扇功能取决于硬件支持；风扇控制使用独立的管理员组件。扫描、监测与恢复可离线使用，软件更新检查需要联网。

## 构建与运行

需要 Swift 5.9 或更新版本及 macOS SDK，可使用 Xcode 或 Command Line Tools。项目使用系统提供的 AppKit、SwiftUI、SceneKit、IOKit、CryptoKit 和 libarchive，没有第三方包依赖。

```sh
git clone https://github.com/Simonlau4/orbit-mac.git
cd orbit-mac
./Scripts/build.sh
open dist/Orbit.app
```

构建产物位于 `dist/Orbit.app`，中间文件默认位于 `.build/orbit`。可通过 `ORBIT_RUNTIME` 指定构建目录。

默认使用 ad-hoc 签名。启用风扇控制等需要校验开发者身份的功能时，使用本机钥匙串中的签名身份构建：

```sh
ORBIT_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./Scripts/build.sh
```

将应用复制到 `~/Applications` 或 `/Applications` 后即可启动。关闭窗口后仍可从菜单栏打开，退出入口也在菜单栏。

## 清理与恢复

1. 扫描后审阅结果。“推荐清理”中的可重建缓存、日志和软件包下载默认勾选；旧安装包、构建产物和应用旧更新包位于“需要你决定”，默认不选。
2. 调整选择，点击“移入废纸篓”并确认。可搜索项目，或打开“逐个文件查看”按文件选择。
3. 点击右上角时钟图标打开清理记录，逐项恢复。恢复时保留已有同名文件。

运行中应用的缓存与近期缓存按规则保留。项目构建产物需要至少 7 天无改动且没有进程在项目中工作；移动前会重新核对。AI 对话、记忆、技能、模型与工具程序包在 AI 清理入口单独审阅。

系统数据、已有废纸篓、数据库、离线内容和归属未核实的数据只统计占用。权限不足或扫描达到预算时会显示部分覆盖；“读取权限”提供检测与 macOS 设置入口。修改扫描范围后需重新扫描。

移入废纸篓后仍占磁盘空间，清空后才释放。恢复依赖废纸篓中的文件及对应记录；AI、维护和程序包操作使用独立恢复副本。

## 软件管理与维护

应用卸载与残留清理先展示关联文件，再按选择执行。个人 `~/Library/LaunchAgents` 支持停用与恢复，系统启动项可在系统设置中管理。

软件更新读取应用声明的 HTTPS Sparkle 更新源，核对签名、开发者、应用标识和版本。ZIP/DMG 更新保留旧版以便恢复；PKG 交给系统安装器。自动更新等待应用退出后安装，需要管理员权限的安装由用户确认并完成系统认证。

系统维护先检查与预览，再按选择执行。风扇控制提供自动、降温和强冷模式；租约失效、睡眠、退出或达到 30 分钟上限时恢复自动控制。

## 快捷键

| 快捷键 | 操作 |
| --- | --- |
| ⌘1–⌘5 | 切换页面 |
| ⌘F | 搜索当前结果或应用 |
| ⌘R | 扫描 |
| ⌘⇧H | 打开清理记录 |
| ⌘, | 打开设置 |
| Esc | 关闭弹窗或退出屏幕清洁模式 |

文件行右键菜单可在 Finder 中显示项目或拷贝路径。设置支持清理类别、近期缓存、监测频率与菜单栏指标。

## 测试

```sh
swift test --scratch-path .build/orbit/build
```

测试使用独立 fixture，覆盖扫描范围、选择策略、文件变化、恢复冲突、更新安装、启动项与管理员组件校验。

原生界面检查可使用自建目录生成截图：

```sh
open -n dist/Orbit.app --args --ui-smoke /absolute/path/to/screenshots --disk-fixture /absolute/path/to/fixture
```

该检查依次打开五个页面、分析指定目录并执行只读扫描。SceneKit 的 Metal 图层需使用原生窗口截图检查。

## 项目结构

- `Sources/Orbit`：SwiftUI 界面与应用状态。
- `Sources/OrbitCore`：扫描、恢复、系统监测与维护。
- `Sources/OrbitFanAgent`：温控管理员组件。
- `Sources/OrbitUpdateAgent`：软件更新管理员组件。
- `Tests`：核心与应用层测试。
- `Scripts`、`Resources`：构建脚本、图标与应用配置。

[功能说明](docs/feature-parity.md) · [扫描范围与计量](docs/scan-differences.md) · [开发说明](AGENTS.md) · [影像来源](Sources/Orbit/Assets/CREDITS.md)
