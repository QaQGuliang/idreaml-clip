Idreaml Clip — macOS Apple Silicon 测试版

系统要求：Apple Silicon（M 系列）Mac，macOS 13 或更新版本。
架构为 arm64，不支持 Intel Mac。无需安装 Flutter、Dart 或 Git。

安装：
1. 打开 Idreaml-Clip-<版本>-macos-arm64.dmg。
2. 将“Idreaml Clip.app”拖入旁边的 Applications（应用程序）文件夹。
3. 等待复制完成，推出磁盘映像，然后从“应用程序”启动 Idreaml Clip。
ZIP 方式：解压后将完整的 Idreaml Clip.app 拖入“应用程序”，不要拆开 .app 内部文件。

首次打开：
本包使用免费本地签名（ad-hoc），没有 Developer ID 签名或苹果公证。
如果系统提示无法验证开发者，在确认文件来自本项目并核对校验值后，
可到“系统设置 → 隐私与安全性”查看针对这个应用的“仍要打开”选项。
公司管理的设备可能禁止手动允许，请遵循管理员的配置。
无需关闭 Gatekeeper、SIP，也不要对来源不明的软件移除安全保护。
苹果说明：https://support.apple.com/102445

使用：
默认快捷键为 Control + Option + V，设置中可修改完整组合。
点击快捷条目后，回到目标输入位置按 Command + V 粘贴。
当前 Mac 版本支持本地文本记录、搜索、收藏、JSON 预览、快捷面板。
图片采集和写回、自动向其他应用粘贴、云同步令牌存储尚未适配 macOS。
不要将这些 Windows 功能当作本测试包已经提供的 Mac 功能。

验证范围：构建机检查应用架构、签名、DMG 完整性和启动进程存活。
仍需在真实 M 系列 Mac 上验证快捷键、文本采集、菜单栏和窗口交互。

更新：退出旧版本后，用新版本替换“应用程序”中的 Idreaml Clip.app。
卸载：退出应用，将 Idreaml Clip.app 移入废纸篓；本地历史与设置不会自动删除。

