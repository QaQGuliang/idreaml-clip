# 桌面打包

版本取自 `pubspec.yaml`。Windows 仅生成 x86-64 Release 包，不生成 32 位或 ARM64 包。输出目录为项目根目录下的 `dist/windows/`，内含 ZIP、SHA-256 校验文件和解压后的运行目录。

## Windows

正常完整构建需要 Flutter SDK、Visual Studio 的“使用 C++ 的桌面开发”工具和 Windows SDK。在项目根目录运行：

```powershell
./scripts/package-windows.ps1 -Flutter 'C:\tools\flutter\bin\flutter.bat'
```

脚本会重新构建 Release，收集应用、插件、资源和三个 Microsoft 签名的 x64 Visual C++ 运行库，并检查 PE 架构。运行库默认取自 `C:\Windows\System32`，也可通过 `-RuntimeDirectory` 指定已安装工具链的 x64 可再发行运行库目录。ZIP 解压后运行 `idreaml_clip.exe`，保留整个目录。

输出存在时脚本会停止，不覆盖已有包。重新打同一版本时使用 `-OutputDirectory 'dist/windows/rebuild-2'` 等新目录。

### 缺少 C++ 工具链时复用原生文件

当已有与当前原生代码、插件版本相符且经过运行验证的 Windows Release 目录时，可以显式复用其启动器和插件，同时重新编译当前 Dart AOT、Flutter 资源并更新 Flutter 引擎：

```powershell
./scripts/package-windows.ps1 `
  -Flutter 'C:\tools\flutter\bin\flutter.bat' `
  -PrebuiltNativeDirectory 'build/windows-preview-json-tree'
```

这种方式要求依赖已解析，并且原生插件和 runner 没有需要重新编译的变更；不替代完整原生构建。`build-info.json` 会明确记录 `prebuilt-native-with-fresh-dart-aot`，文件清单包含 SHA-256。本次本机构建采用此方式，因为本机没有 Visual Studio C++ 工具链。

`assets/release-info.json` 保存当前版本的简短更新说明和待解决问题，显示在设置页中。打包时会校验它与 `pubspec.yaml` 一致，并生成包内 `RELEASE-NOTES.txt`。复用原生启动器时，只更新暂存副本的 Windows 版本资源，使 EXE 文件属性与包版本一致；原始预构建文件、图标、清单和程序代码保持不变，版本资源更新必须在代码签名前进行。

Windows 的文件布局依据 [Flutter ZIP 分发说明](https://docs.flutter.dev/platform-integration/windows/building#building-your-own-zip-file-for-windows)。

### EXE 安装包

先生成上述 ZIP 和运行目录，再使用 Inno Setup 7.1 或更新版本包装同一份已校验的 Release 文件：

```powershell
./scripts/package-windows-installer.ps1 `
  -InnoCompiler 'build/tools/innosetup/ISCC.exe'
```

默认读取 `dist/windows/Idreaml-Clip-<版本>-windows-x64/`，可用 `-BundleDirectory` 指定其他已校验目录。安装包输出为 `dist/windows/Idreaml-Clip-<版本>-windows-x64-setup.exe`，并附带 SHA-256 文件；原有 ZIP 保留。

安装器和应用均为 x86-64，要求 Windows 10 或更新版本。当前已知受 Flutter 支持的 Windows 版本为 10、11；后续系统版本仍需验证。安装包包含本地 Visual C++ 运行库，安装过程无需下载 Flutter、Dart 或其他依赖。

支持简体中文和英文，可选择当前用户或所有用户安装、安装目录及桌面快捷方式。安装完成后可从开始菜单启动，并在 Windows 应用管理中卸载。沿用旧版安装 ID，因此使用与旧版相同的安装范围可覆盖升级。覆盖安装和卸载会先请求目标安装目录内的程序正常退出，并等待进程结束；旧版或无响应进程在等待 8 秒后按已验证的完整 EXE 路径结束，其他目录下的便携副本不受影响。无法关闭时中止安装或卸载，不继续修改安装文件。卸载保留应用数据目录中的历史与配置，只移除安装文件、快捷方式和指向该安装副本的开机启动项。

Windows 程序在打开数据库、注册快捷键之前获取会话级命名互斥量。安装版和解压版共享单实例，重复启动通知已有程序打开全部历史；退出或崩溃后锁由系统释放。安装/卸载期间，目标路径的维护事件阻止该副本再次启动。该协议通过现有 Win32 FFI 实现，复用原生 runner 的打包方式同样有效。

可运行 `scripts/check-windows-lifecycle.ps1` 验证并发启动、跨目录重复启动、退出通知、崩溃后重启以及旧版重复进程的路径隔离。脚本只编译并操作 `build/lifecycle-test-*` 下的测试进程，不读写用户历史，不安装或卸载真实应用。

本地生成的安装器尚未进行发布者代码签名。发布前若需要显示经过验证的发布者，需要使用自己的 Windows 代码签名证书签名。

构建工具可从 [Inno Setup 官方下载页](https://jrsoftware.org/isdl.php) 获取；其安装程序支持 `/PORTABLE=1 /CURRENTUSER /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /NOICONS /DIR="<工具目录>"`，可解压到本项目的 `build/tools/innosetup/` 使用。

## macOS / Apple Silicon

通过 `.github/workflows/macos-arm64.yml` 在 GitHub 标准 `macos-15` ARM64 构建机生成免费本地签名的测试包。固定 Flutter 3.47.4，最低 macOS 13，不包含 Intel 架构，不需要 Apple Developer 会员、证书或公证凭证。

公开仓库可使用免费的标准构建机。私有仓库必须先确认剩余免费额度且未启用超额付费；工作流默认跳过私有仓库构建。确认后，手动运行时勾选 `confirm_free_allowance`，或在构建分支 `codex/macos-arm64-package` 的提交说明中加入 `[use-free-actions]`。此标记只表示本次已确认额度，不会修改账户的计费设置。工作流进入默认分支后可在 Actions 页面手动启动。

Flutter 3.47.4 的原生资产构建目标固定为 macOS 13，`objective_c.framework` 实际生成的最低版本也是 13，因此本包统一以 macOS 13 为最低版本，未宣称支持 12。

依赖包随附的 libgit2 动态库最低要求 macOS 26，不能直接用于本项目的 macOS 13 目标。CI 会先从 libgit2 v1.9.7 源码重新编译 arm64 / macOS 13 版本，保留 Dart 绑定需要的 experimental SHA256 ABI，HTTPS 使用系统 SecureTransport，不引入 Homebrew 运行依赖；应用仅接受 HTTPS 同步地址，因此不启用 SSH。构建信息中记录源码提交和动态库校验值。

构建流程执行静态检查、Flutter 测试和 Release 构建，逐个检查 Mach-O 文件是否支持 arm64，必要时去掉 Intel 切片，再从内到外执行 ad-hoc 本地签名。验证版本、最低系统版本、签名、应用进程启动存活和 DMG 完整性。它不是实机交互验收，也不会声称通过 Gatekeeper 的 Developer ID / 公证检查。

产物上传到 Actions 运行页面的 `Idreaml-Clip-macos-arm64-<运行编号>` artifact，保留 7 天。下载并解压后含：

- `Idreaml-Clip-1.0.3+1-macos-arm64.dmg`：拖入 Applications 安装。
- `Idreaml-Clip-1.0.3+1-macos-arm64.zip`：保留完整 `.app` 的压缩包。
- `SHA256SUMS.txt`、`build-info.json`、`安装说明.txt` 和独立离线 `使用指南.html`。

本地 Apple Silicon Mac 可以先执行 `flutter pub get`，再运行 `bash scripts/prepare-macos-libgit2.sh` 和 `bash scripts/package-macos.sh`，结果写入 `dist/macos/`。脚本不覆盖已有同版本产物；准备新的输出目录后再重新构建。通过 `ditto` 打包 ZIP，保留应用结构、权限与符号链接。Windows 上可以保存或转发产物，但不能运行 Mac 应用。

首次打开时，未公证软件可能被系统拦截。在确认来源后，可查看“系统设置 → 隐私与安全性”中该应用的“仍要打开”。不要求关闭系统安全机制。正式面向所有用户发布前，仍需要在 M 系列 Mac 上验证快捷键、文本采集、菜单栏和窗口交互。

当前 Mac 版仅实现本地文本采集、历史搜索/收藏、JSON 预览和快捷面板；默认快捷键 Control + Option + V，选择后回到目标位置按 Command + V。图片采集与写回、自动粘贴以及同步令牌安全存储仍未完成 Mac 适配。包内说明和 HTML 教程明确列出了这些限制。

参考：[GitHub 构建机](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)、[Flutter macOS](https://docs.flutter.dev/deployment/macos)、[苹果首次打开说明](https://support.apple.com/102445)。
