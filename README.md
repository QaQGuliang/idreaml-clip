<p align="center">
  <img src="/idreaml/idreaml-clip/raw/branch/main/website/assets/logo.png" width="76" height="76" alt="理梦剪藏 Logo">
</p>

<h1 align="center">Idreaml Clip · 理梦剪藏</h1>

<p align="center">找回复制过的内容，把灵感和计划留在桌面。</p>

<p align="center">
  <a href="/idreaml/idreaml-clip/src/branch/main/website/guide.md"><strong>完整图文介绍与使用指南 ↗</strong></a>
  &nbsp;·&nbsp;
  <a href="/idreaml/idreaml-clip/releases/tag/v1.2.0">下载 Windows 版</a>
  &nbsp;·&nbsp;
  <a href="/idreaml/idreaml-clip/src/branch/main/docs/user-guide.md">详细使用说明</a>
</p>

理梦剪藏是一款本地优先的桌面工具，提供剪切板历史、快捷粘贴、截图与贴图，以及独立的桌面便签和待办。无需注册账号，未配置云同步也能使用。

<a href="/idreaml/idreaml-clip/src/branch/main/website/guide.md"><img src="/idreaml/idreaml-clip/raw/branch/main/website/assets/main-history.png" alt="全部历史：搜索、收藏与内容预览"></a>

> **[打开完整图文指南 →](website/guide.md)** 通过界面截图、操作步骤和快捷键说明，了解每项功能。

## 下载

当前版本 **1.2.0**，支持 **Windows 10 / 11 x64**。本次仅发布 Windows 版本。

本版为待办增加可选的时间与提醒，同步记录改为折叠摘要并可打开明细页；截图编辑器默认使用“选择 / 调整”工具，工具栏收拢为单行优先并避免遮挡选区；便签、待办与设置统一使用 18 色色板和 HEX 自定义颜色。

| 安装方式 | 下载与使用 |
| --- | --- |
| 安装版 | [下载 EXE 安装包](/idreaml/idreaml-clip/releases/download/v1.2.0/Idreaml-Clip-1.2.0%2B1-windows-x64-setup.exe)，按向导完成安装 |
| 便携版 | [下载 ZIP](/idreaml/idreaml-clip/releases/download/v1.2.0/Idreaml-Clip-1.2.0%2B1-windows-x64.zip)，完整解压后运行 `idreaml_clip.exe` |

运行所需组件随包提供，无需额外安装 Flutter、Dart 或 Git。便携版请保留旁边的 DLL 和 `data` 目录；升级前从托盘退出旧版并保留原数据目录。当前安装器尚未进行发布者代码签名。

[完整发布说明与 SHA-256 校验文件](/idreaml/idreaml-clip/releases/tag/v1.2.0) · [本版更新记录](assets/release-info.json)

## 能做什么

| 功能 | 用途 |
| --- | --- |
| 剪切板历史 | 自动保存文字和图片，支持搜索、收藏、去重与历史管理 |
| 快捷剪切板 | 在鼠标附近查找并使用记录，悬停预览图片和 JSON |
| 截图与取色 | 区域、窗口、全屏及跨屏截图，多种标注工具，HEX / RGB 取色 |
| 贴图与长截图 | 将截图贴在桌面参考，调整边框、位置和缩放；滚动拼接长页面 |
| 桌面便签与待办 | 固定区域展示，独立管理、完成与恢复，自定义文字和毛玻璃外观 |
| 可选 Git 同步 | 连接自己的 Gitee、GitHub 或 GitLab 仓库，跨设备同步内容 |

<details>
<summary>查看快捷剪切板与 JSON 预览</summary>

<p align="center"><img src="/idreaml/idreaml-clip/raw/branch/main/website/assets/quick-panel.png" width="347" alt="快捷剪切板：搜索、收藏与便签待办快捷入口"></p>

<img src="/idreaml/idreaml-clip/raw/branch/main/website/assets/json-preview.png" alt="JSON 详情：左侧原文，右侧格式化与层级折叠">

</details>

## 三步开始

1. **启动应用**，像平时一样复制文字或图片；新内容会出现在“全部历史”。
2. **点击目标输入框**，按 `Ctrl + Shift + V` 打开快捷面板，输入关键词查找内容。
3. **单击记录**，或用 `↑` / `↓` 选择后按 `Enter` 使用；按 `Esc` 收起面板。

部分应用的输入框或权限会限制自动粘贴，内容仍在剪切板时可手动按 `Ctrl + V`。关闭主窗口后，应用继续在托盘运行；左击托盘图标打开全部历史，右击选择“退出应用程序”才会完全退出。

## 常用快捷键

| 按键 | 作用与使用范围 |
| --- | --- |
| `Ctrl + Shift + V` | 打开快捷剪切板；可在设置中修改，或启用固定 `Win + V` |
| `F1` | 进入截图，也可通过快捷面板顶部的截图图标打开 |
| `F2` | 普通截图中显示或隐藏取色框，文字输入期间除外 |
| `C` | 普通截图取色框显示时复制 HEX 并结束，文字输入期间除外 |
| 单按 `F3` | 开启便签功能后，快速新建便签 |
| 快速双按 `F3` | 开启待办功能后，快速新建待办；两次间隔在 330 毫秒内 |
| `Ctrl + Enter` / `Esc` | 在 F3 或快捷面板打开的快速新增窗口中保存 / 关闭并保留草稿 |

启用固定 `Win + V` 后，原快捷面板组合暂时停用；关闭开关后恢复。更多标注快捷键与操作边界见[详细使用说明](docs/user-guide.md)。

## 便签与待办

在 **设置 → 便签与待办** 分别启用，才会显示对应的导航、快捷面板图标和桌面列表。可指定显示器及展示区域；列表平时位于普通应用下方，`Win + D` 后仍可查看，快捷键添加时临时置顶。

| 便签 | 待办 |
| --- | --- |
| <img src="/idreaml/idreaml-clip/raw/branch/main/website/assets/desk-notes.png" alt="便签管理界面"> | <img src="/idreaml/idreaml-clip/raw/branch/main/website/assets/desk-todos.png" alt="待办管理界面"> |
| 记录标题与多行正文，集中搜索、编辑和删除 | 勾选完成后从桌面隐藏，在管理页查看和恢复 |

两个模块分别支持默认字体、10–32 字号和文字颜色；管理页新增或编辑可设置单条样式，也可恢复“跟随列表”。快速新增支持选色；按 `Esc` 或直接离开窗口会保留本机草稿，点击“取消”才会清除。快速新增会显示在对应桌面列表所在的显示器，添加期间列表临时置顶；保存或取消后不弹出主窗口，焦点回到之前的应用。

新建或编辑待办时可设置可选的开始、结束时间与提醒。应用运行期间到点会弹出 Windows 系统通知，错过的提醒在下次启动时汇总提示一次；完成后不再提醒。管理页与桌面卡片会显示时间，逾期标红，有开始时间的未完成待办按开始时间排在前面。

选色使用应用内 18 色色板，也可输入 6 位 HEX 值自定义，设置页、管理页和快速新增保持一致。

卡片采用无边框毛玻璃，背景色、渐变和透明度均可调整。100% 透明仍保留静态壁纸的模糊效果与少量底色，文字保持不透明。

## 数据与同步

- **本地独立保存**：便签和待办存入 `database/desktop.db`，不计入剪切板历史；清空历史或关闭模块不会删除这些内容。
- **按需同步**：在“云同步”连接自己的私有 Git 仓库，再分别开启便签、待办的同步开关。支持手动同步及 5、10、30 分钟定时同步。同步记录默认折叠显示最近结果，可查看全部并按天筛选成功或失败。
- **内容与偏好分开**：同步便签待办内容、时间与提醒、单条文字样式、完成和删除状态；显示器、位置、列表默认主题、草稿和已提醒状态只保存在本机。并发修改保留双方版本，在管理页处理。
- **数据目录可迁移**：默认位于程序目录下的 `data/idreaml_clip`。在“设置 → 快捷面板与历史 → 数据存储目录”更改位置，由应用迁移并校验；备份时保留整个数据目录。

## 文档与开发

- [完整图文指南](website/guide.md)：应用介绍、下载安装、界面截图与使用步骤。
- [详细使用说明](docs/user-guide.md)：功能边界、同步配置、存储迁移及其他平台的当前范围。
- [网站源码](website/) · [版本信息](assets/release-info.json)。
- [Windows 打包脚本](scripts/package-windows.ps1) · [Windows 安装器脚本](scripts/package-windows-installer.ps1)。
