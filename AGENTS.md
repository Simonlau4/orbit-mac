# Orbit 开发说明

先读 `README.md`，再按任务阅读相关模块。

## 项目依据

- 功能与适用条件：`docs/feature-parity.md`。
- 扫描范围、读取权限与计量：`docs/scan-differences.md`。
- 变更前核对当前源码与相关测试。

## 代码与验证

- `Sources/Orbit`：SwiftUI 界面与应用状态；`Sources/OrbitCore`：扫描、恢复及系统能力。
- `Sources/OrbitFanAgent`、`Sources/OrbitUpdateAgent`：用途固定的管理员组件，变更须核对签名、授权与验证范围。
- `Tests/OrbitCoreTests`、`Tests/OrbitAppTests`：使用独立 fixture 的回归测试；构建与签名步骤见 README。
- 扫描范围变化须使旧结果和选择失效。占用、候选、已选、保留、未知及部分覆盖分开处理。
- 系统数据与已有废纸篓只统计；AI 数据单独审阅。权限拒绝不记零，补充占用统计时维持现有执行准入。
- 真实用户文件清理、永久删除、系统维护及恢复按具体选择与确认执行；测试使用自建文件。
- 保持改动集中，沿用现有代码风格，运行与变更对应的检查。

## 构建与数据

- 应用输出为 `dist/Orbit.app`，默认构建中间文件位于 `.build/orbit`，可通过 `ORBIT_RUNTIME` 指定位置。
- 测试 fixture 使用系统临时目录。
- 运行数据与恢复记录位于用户的 `~/Library/Application Support/Orbit`。
- 管理员组件、锁文件与签名要求使用一致的应用标识；修改标识时同步构建脚本与测试。
- 提交只包含源码、测试、资源和项目说明。
