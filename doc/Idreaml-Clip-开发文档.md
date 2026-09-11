# Idreaml Clip（理梦剪藏）开发文档

> 项目类型：跨平台桌面剪切板管理器  
> 核心定位：Local First + 长期剪切板历史 + 可选 Git 云同步  
> 主要平台：Windows、macOS  
> 次要平台：Linux（deb / rpm）  
> 首选技术栈：Dart + Flutter Desktop  
> 次选技术栈：JavaFX  
> V1 数据类型：文本剪切板

---

# 1. 项目背景

Windows 11 的 `Win + V` 剪切板体验很好，但存在几个明显限制：

1. 历史记录不是长期保存；
2. 系统重启或部分场景下历史可能丢失；
3. 缺少真正的跨设备云同步；
4. 不同系统之间没有统一的剪切板历史体验。

因此开发 **Idreaml Clip（理梦剪藏）**：

> 一个跨平台、本地优先、可以长期保存历史，并支持用户使用自己的 Git 仓库进行多设备同步的桌面剪切板管理器。

应用不是重新实现操作系统的 `Ctrl + C / Ctrl + V`，而是在系统剪切板之上提供增强能力。

---

# 2. 项目核心原则

## 2.1 Local First

应用必须可以完全脱离云端使用。

即使用户：

- 不登录；
- 不配置 Git；
- 不开启云同步；
- 当前没有网络；

仍然可以完整使用：

- 剪切板监听；
- 历史记录；
- 搜索；
- 收藏；
- 删除；
- 快捷面板；
- 本地持久化。

---

## 2.2 本地数据是主数据

本地数据库是应用真正的数据源。

```text
系统剪切板
    ↓
本地监听
    ↓
本地数据库
    ↓
应用功能
```

Git 仓库只作为：

- 云端副本；
- 多设备同步介质；
- 备份；
- 恢复来源。

不能让 Git 成为应用正常运行的前置条件。

---

## 2.3 用户自己拥有云端数据

云同步开启后：

```text
本地数据
    ⇅
应用内置 Git 能力
    ⇅
用户自己的 Git 仓库
```

远端仓库属于用户本人。

应用开发者：

- 不提供用户业务数据服务器；
- 不集中保存用户剪切板内容；
- 不要求用户把数据上传到开发者自己的数据库。

---

## 2.4 Git 对用户透明

用户不需要：

- 安装 Git；
- 配置 Git；
- 学习 Git；
- 执行 `clone`；
- 执行 `pull`；
- 执行 `commit`；
- 执行 `push`；
- 理解分支和合并。

Git 能力由应用内部实现。

---

# 3. 产品名称

英文名：

```text
Idreaml Clip
```

中文名：

```text
理梦剪藏
```

品牌关系：

```text
Idreaml
   ↓
Idreaml Clip
```

后续如果继续扩展产品，可以保持统一命名：

```text
Idreaml Clip
Idreaml Notes
Idreaml Todo
...
```

---

# 4. V1 功能范围

## 4.1 V1 必须完成

- [ ] Windows 支持
- [ ] macOS 支持
- [ ] Linux 基础支持
- [ ] 文本剪切板监听
- [ ] 文本剪切板长期保存
- [ ] 历史记录查看
- [ ] 历史搜索
- [ ] 收藏
- [ ] 删除
- [ ] 清空历史
- [ ] 快速剪切板面板
- [ ] 全局快捷键
- [ ] 键盘选择
- [ ] 重新写入系统剪切板
- [ ] 系统托盘
- [ ] 开机启动
- [ ] 本地模式完整可用
- [ ] Git 云同步可选
- [ ] 应用不依赖系统 Git
- [ ] Git 凭证安全保存
- [ ] 基础多设备同步
- [ ] 同步失败不影响本地剪切板

---

## 4.2 V1 暂不实现

- 图片剪切板
- 文件剪切板
- HTML
- RTF / 富文本
- 手机端
- Web 端
- 实时推送
- 团队共享
- AI
- OCR
- 自建用户数据服务器

V1 先把：

```text
文本剪切板
+
长期本地历史
+
快捷使用
+
Git 云同步
```

这个闭环做完整。

---

# 5. 应用界面模型

Idreaml Clip 不是单窗口应用。

整个产品分为两个主要界面：

```text
Idreaml Clip
     │
     ├── 快捷剪切板
     │
     └── 应用管理页面
```

两个页面职责完全不同。

---

# 6. 快捷剪切板页面

这是用户日常使用频率最高的页面。

目标体验类似 Windows 11：

```text
Win + V
```

用户正在：

- IDEA；
- 浏览器；
- Word；
- VS Code；
- 聊天工具；

中工作时，按 Idreaml Clip 自定义全局快捷键：

```text
Ctrl + Shift + V
```

弹出一个小型浮动窗口。

---

## 6.1 页面目标

快捷页面只做：

- 最近剪切内容；
- 快速搜索；
- 收藏；
- 键盘选择；
- 使用剪切内容；
- 进入全部历史。

不要放：

- Git 配置；
- 同步策略；
- 设备管理；
- 历史清理；
- 系统设置；
- 高级管理功能。

---

## 6.2 最近记录数量

快捷页面不展示全部历史。

建议默认：

```text
最近 30 条
```

设置允许：

```text
20
30
40
50
```

推荐默认值：

```text
30
```

---

## 6.3 搜索行为

默认打开：

```text
只加载最近 30 条
```

用户没有输入搜索内容时，不需要查询全部历史。

当用户开始输入关键词后：

```text
最近列表
    ↓
切换到全部历史搜索
```

这样兼顾：

- 打开速度；
- 日常使用效率；
- 长期历史检索。

---

## 6.4 快捷页面键盘操作

至少支持：

```text
↑
↓
Enter
Esc
```

目标行为：

```text
↑ / ↓
    ↓
选择历史记录

Enter
    ↓
写入系统剪切板
    ↓
关闭快捷窗口
```

后续可以继续实现：

```text
Enter
    ↓
写入系统剪切板
    ↓
自动粘贴到当前应用
```

---

# 7. 应用管理页面

应用管理页面不是高频剪切板入口。

主要负责：

- 全部历史；
- 高级搜索；
- 收藏管理；
- 删除；
- 清空；
- 云同步；
- 设备；
- 隐私；
- 设置；
- 应用状态。

结构：

```text
应用管理页面

├── 全部历史
├── 收藏
├── 云同步
├── 设备
├── 隐私
└── 设置
```

---

# 8. 两个原型

本文档配套两个 HTML 原型。

---

## 8.1 原型一：应用管理页面

用途：

> 表示用户主动打开 Idreaml Clip 应用后的管理界面。

包含：

- 历史列表；
- 搜索；
- 收藏；
- 删除；
- 内容详情；
- 云同步状态；
- 设置。

打开：

[Idreaml Clip 应用管理页面原型](./Idreaml-Clip-应用管理页面原型.html)

对应文件：

```text
Idreaml-Clip-应用管理页面原型.html
```

---

## 8.2 原型二：快捷剪切板页面

用途：

> 表示用户日常通过全局快捷键呼出的剪切板浮动页面。

这是应用最重要、最高频的交互入口。

主要体现：

- 类似 Win + V 的浮窗；
- 最近记录；
- 收藏；
- 搜索；
- ↑ / ↓；
- Enter；
- Esc；
- 查看全部历史；
- 快捷面板数量配置。

打开：

[Idreaml Clip 快捷剪切板原型](./Idreaml-Clip-快捷剪切板原型.html)

对应文件：

```text
Idreaml-Clip-快捷剪切板原型.html
```

---

# 9. 总体技术架构

```text
                系统剪切板
                     │
                     ▼
            Clipboard Monitor
                     │
                     ▼
            Clipboard Service
                     │
                     ▼
                 SQLite
             本地主数据源
                     │
          ┌──────────┴──────────┐
          │                     │
          ▼                     ▼
     快捷剪切板              应用管理页面
          │                     │
          └──────────┬──────────┘
                     │
                     ▼
                Sync Service
                     │
                     ▼
             本地隐藏 Git 仓库
                     │
                     ▼
             App 内置 Git 能力
                     │
          ┌──────────┼──────────┐
          ▼          ▼          ▼
        Gitee      GitHub     GitLab
          │          │          │
          └──── 用户自己的仓库 ────┘
```

---

# 10. 技术栈

## 10.1 首选

```text
Dart
+
Flutter Desktop
```

目标平台：

```text
Windows
macOS
Linux
```

---

## 10.2 次选

```text
JavaFX
```

如果后续 Flutter 在桌面系统能力或 Git 集成上遇到明显问题，可以重新评估 JavaFX。

---

## 10.3 推荐基础组件

| 功能 | 技术方向 |
|---|---|
| UI | Flutter Desktop |
| 本地数据库 | SQLite |
| ORM | Drift |
| 剪切板 | Flutter Clipboard / 桌面剪切板插件 |
| 剪切板监听 | clipboard watcher 类插件或平台实现 |
| 全局快捷键 | hotkey manager 类插件 |
| 窗口管理 | window manager 类插件 |
| 系统托盘 | tray manager 类插件 |
| 开机启动 | launch at startup 类插件 |
| 凭证 | flutter secure storage |
| Git | libgit2 对应 Dart / Flutter 绑定 |
| JSON | dart:convert |
| 唯一 ID | UUID |

所有第三方插件都必须通过自己的 Service / Adapter 层封装。

---

# 11. 为什么不依赖系统 Git

正式应用不能要求用户：

```text
先安装 Git
→ 配置 PATH
→ 配置账号
→ 再使用云同步
```

目标是：

```text
Idreaml Clip
    ↓
内置 Git 能力
    ↓
Git Remote
```

用户只需要在应用里完成：

```text
连接 Gitee / GitHub / GitLab
```

不需要操作 Git 客户端。

---

# 12. 本地数据设计

SQLite 是主数据。

第一版至少包含：

```text
clipboard_item
app_setting
device
sync_state
```

---

## 12.1 clipboard_item

建议字段：

```text
id
type
content
content_hash
created_at
updated_at
last_used_at
copy_count
favorite
deleted
device_id
sync_state
```

V1：

```text
type = text
```

---

## 12.2 软删除

历史删除建议先采用：

```text
deleted = true
```

而不是直接物理删除。

原因：

多设备同步必须知道：

> 某条历史已经被用户删除。

否则其他设备可能把已经删除的数据重新同步回来。

---

# 13. 剪切板监听流程

```text
用户 Ctrl + C
    ↓
系统剪切板变化
    ↓
Clipboard Monitor
    ↓
读取内容
    ↓
检查类型
    ↓
计算 Hash
    ↓
去重判断
    ↓
写入 SQLite
    ↓
更新快捷页面 / 历史页面
```

这个流程不能依赖：

- 网络；
- Git；
- 云同步。

---

# 14. 去重策略

V1 推荐：

> 相同内容只保留一条，通过 Hash 判断重复。

例如：

```text
A
A
A
```

最终：

```text
A
copy_count = 3
last_used_at = 最新时间
```

后面如果觉得需要保留“同一内容不同复制时间”，再调整策略。

---

# 15. 高频路径原则

每次剪切板变化时，只做：

```text
读取
Hash
判断
SQLite 写入
```

禁止在这个流程里直接执行：

```text
Git Commit
Git Push
网络请求
大规模 JSON 序列化
复杂同步
```

否则会影响剪切板体验。

---

# 16. Git 同步定位

Git 不是数据库。

Git 是：

```text
同步层
+
远端副本
```

因此禁止：

```text
SQLite 文件
    ↓
直接提交 Git
```

SQLite 是二进制文件，多设备会非常难合并。

正确方向：

```text
SQLite
    ↓
导出同步数据
    ↓
JSON / JSONL
    ↓
Git
```

---

# 17. Git 同步目录

本地建议：

```text
Application Data/
└── idreaml_clip/
    ├── database/
    │   └── clipboard.db
    │
    ├── sync/
    │   └── repository/
    │       ├── .git/
    │       └── data/
    │
    └── logs/
```

用户一般不需要看到：

```text
.git
```

---

# 18. 云端 Git 数据结构

为了减少多设备冲突，可以按设备拆分。

例如：

```text
clipboard-data/
├── schema.json
├── devices/
│   ├── DEVICE-A.json
│   └── DEVICE-B.json
│
├── records/
│   ├── DEVICE-A/
│   │   └── 2026-09.jsonl
│   │
│   └── DEVICE-B/
│       └── 2026-09.jsonl
│
└── tombstones/
    ├── DEVICE-A/
    └── DEVICE-B/
```

每台设备主要写自己的数据区域。

这样可以降低 Git 文件冲突概率。

---

# 19. 多设备同步

例如：

```text
Windows A
macOS B
Linux C
```

共同使用：

```text
同一个用户 Git 仓库
```

每台设备拥有唯一：

```text
device_id
```

同步过程：

```text
本地新增
    ↓
导出当前设备变化
    ↓
Commit
    ↓
Pull / Fetch
    ↓
读取其他设备数据
    ↓
Merge 到 SQLite
    ↓
Push
```

---

# 20. 删除同步

删除必须同步“删除事件”。

例如：

```text
设备 A 删除记录
    ↓
SQLite deleted = true
    ↓
生成 tombstone
    ↓
Git
    ↓
设备 B 拉取
    ↓
设备 B 将同一记录标记为 deleted
```

---

# 21. 收藏同步

收藏属于用户业务状态。

因此应该同步：

```text
favorite
updated_at
```

后续可以单独增加：

```text
favorite_updated_at
```

让收藏状态和内容更新时间互不干扰。

---

# 22. 云同步触发

V1 推荐：

## 手动

```text
立即同步
```

## 启动后

```text
启动
→ 后台延迟
→ 同步一次
```

## 定时

```text
5 分钟
10 分钟
30 分钟
```

---

## 不建议

每复制一次都：

```text
Commit
+
Push
```

剪切板是高频业务，这样会产生大量 Git 提交和网络请求。

---

# 23. 凭证安全

Git Token、OAuth Token、密码等不能存放在：

```text
SQLite 明文
普通 JSON
Git 仓库
日志
配置文件明文
```

应该使用系统安全存储：

```text
Windows 安全凭证能力
macOS Keychain
Linux Secret Service
```

Flutter 侧统一封装：

```text
CredentialService
```

---

# 24. 隐私能力

剪切板可能包含：

- 密码；
- 验证码；
- Token；
- API Key；
- 身份信息；
- 公司内部内容。

V1 至少支持：

```text
暂停记录
恢复记录
清空历史
历史数量限制
自动清理
```

后续可以增加：

```text
隐私模式
敏感应用排除
敏感内容规则
```

---

# 25. 日志原则

日志可以记录：

```text
recordId
contentHash
contentLength
事件
错误
```

日志禁止记录：

```text
完整剪切板正文
Token
密码
Authorization Header
```

---

# 26. 开发顺序

开发不要先做 Git。

严格按照以下顺序推进：

```text
Milestone 1  Flutter Desktop 基础
Milestone 2  SQLite
Milestone 3  Clipboard Core
Milestone 4  快捷剪切板
Milestone 5  历史管理
Milestone 6  快捷键 / 托盘 / 开机启动
Milestone 7  本地版稳定
Milestone 8  Git Core
Milestone 9  Sync Format
Milestone 10 Gitee / GitHub / GitLab 其中一个
Milestone 11 多设备同步
Milestone 12 Windows 发布
Milestone 13 macOS 发布
Milestone 14 Linux 发布
```

---

# 27. Milestone 1：Flutter Desktop

完成：

- [ ] 安装 Flutter
- [ ] Windows Desktop 可运行
- [ ] macOS Desktop 可运行
- [ ] 建立基础项目
- [ ] 建立模块目录
- [ ] Release Build 成功

第一阶段优先 Windows。

---

# 28. Milestone 2：SQLite

完成：

- [ ] Drift
- [ ] clipboard_item
- [ ] app_setting
- [ ] device
- [ ] sync_state
- [ ] CRUD
- [ ] migration
- [ ] 重启应用数据不丢失

---

# 29. Milestone 3：Clipboard Core

先实现：

```text
读取当前剪切板
写入系统剪切板
```

之后实现：

```text
Clipboard Monitor
```

完成：

- [ ] 文本读取
- [ ] 文本写入
- [ ] 自动监听
- [ ] SQLite 写入
- [ ] Hash 去重
- [ ] 防止应用自己写入形成循环

---

# 30. Milestone 4：快捷剪切板

这是整个产品最核心的使用页面。

完成：

- [ ] 小型浮窗
- [ ] 最近 30 条
- [ ] 设置 20 / 30 / 40 / 50
- [ ] 全局快捷键
- [ ] 搜索
- [ ] 收藏
- [ ] ↑
- [ ] ↓
- [ ] Enter
- [ ] Esc
- [ ] 选择后关闭
- [ ] 查看全部历史

完成后，已经具备类似 Win + V 的核心体验。

---

# 31. Milestone 5：应用管理页面

完成：

- [ ] 全部历史
- [ ] 搜索
- [ ] 收藏
- [ ] 删除
- [ ] 清空
- [ ] 内容详情
- [ ] 云同步页面
- [ ] 设备页面
- [ ] 隐私页面
- [ ] 设置页面

---

# 32. Milestone 6：桌面体验

完成：

- [ ] 系统托盘
- [ ] 关闭到托盘
- [ ] 开机启动
- [ ] 后台监听
- [ ] 快捷键稳定
- [ ] 主窗口与快捷窗口独立

目标：

> 主窗口关闭以后，快捷剪切板依然可以正常使用。

---

# 33. Milestone 7：本地版验收

在没有网络、没有 Git 的情况下连续测试。

必须全部正常：

- [ ] 记录
- [ ] 搜索
- [ ] 快捷面板
- [ ] 收藏
- [ ] 删除
- [ ] 重启
- [ ] 托盘
- [ ] 开机启动
- [ ] 长时间后台运行

本地版稳定以后再开始 Git。

---

# 34. Milestone 8：Git Core

目标：

> 在没有安装系统 Git 的电脑中，Idreaml Clip 自己完成 Git 操作。

完成：

- [ ] init
- [ ] status
- [ ] add
- [ ] commit
- [ ] remote
- [ ] fetch
- [ ] pull
- [ ] push

正式方案不要直接依赖：

```text
Process.run("git")
```

---

# 35. Milestone 9：同步数据格式

完成：

- [ ] schema version
- [ ] device_id
- [ ] record JSON / JSONL
- [ ] tombstone
- [ ] SQLite → Git
- [ ] Git → SQLite
- [ ] 幂等处理
- [ ] Hash 去重

---

# 36. Milestone 10：第一个 Git 平台

第一版不要同时实现：

```text
Gitee
GitHub
GitLab
```

先选择一个平台完整跑通。

如果主要考虑国内开发测试，可以先：

```text
Gitee
```

完成：

- [ ] 用户凭证配置
- [ ] 安全存储
- [ ] Remote
- [ ] Push
- [ ] Pull
- [ ] 手动同步
- [ ] 定时同步
- [ ] 启动同步

---

# 37. Milestone 11：多设备

至少使用两台设备测试：

```text
Windows A
macOS B
```

场景：

```text
A 复制内容 1
B 复制内容 2

A 同步
B 同步
A 再同步
```

最终：

```text
A 有 1、2
B 有 1、2
```

继续测试：

- 删除；
- 收藏；
- 重复；
- 离线；
- 同时同步；
- 凭证失效；
- Remote 不可用。

---

# 38. Windows 发布

优先完成 Windows。

目标：

```text
.exe / .msi
```

纯净 Windows 11 测试机必须：

```text
没有 Flutter
没有 Dart
没有 Git
```

安装 Idreaml Clip 后：

- [ ] 启动成功
- [ ] Clipboard 正常
- [ ] 快捷键正常
- [ ] SQLite 正常
- [ ] Tray 正常
- [ ] Git 正常
- [ ] Push 正常

---

# 39. macOS 发布

目标：

```text
.dmg / .pkg
```

重点：

- 剪切板；
- 全局快捷键；
- Menu Bar；
- Keychain；
- 后台运行；
- Git Native Library；
- 开机启动；
- Code Signing；
- Notarization。

---

# 40. Linux 发布

目标：

```text
.deb
.rpm
```

重点验证：

```text
GNOME
KDE
X11
Wayland
```

尤其关注：

- 剪切板监听；
- 全局快捷键；
- 托盘；
- 开机启动。

---

# 41. V1 最终验收

## 场景 1

```text
复制 100 条文本
→ 历史全部存在
```

## 场景 2

```text
重启系统
→ 历史仍然存在
```

## 场景 3

```text
断网
→ 剪切板继续正常工作
```

## 场景 4

```text
按全局快捷键
→ 快速剪切板立即出现
```

## 场景 5

```text
快速剪切板
→ ↑ / ↓
→ Enter
→ 内容可继续粘贴
```

## 场景 6

```text
快捷面板只显示最近 20～50 条
```

## 场景 7

```text
输入搜索
→ 可以查到长期历史
```

## 场景 8

```text
没有安装 Git
→ 云同步成功
```

## 场景 9

```text
Windows A
→ Sync
→ macOS B
→ 获得 A 的内容
```

## 场景 10

```text
Git 故障
→ Sync 失败
→ Clipboard 功能不受影响
```

## 场景 11

```text
关闭云同步
→ 应用完整可用
```

---

# 42. 最终确定的 V1 技术路线

```text
产品
    Idreaml Clip
    理梦剪藏

类型
    跨平台桌面剪切板管理器

主要平台
    Windows
    macOS

次要平台
    Linux
      ├── deb
      └── rpm

框架
    Dart + Flutter Desktop

数据模式
    Local First

本地数据库
    SQLite + Drift

剪切板
    系统 Clipboard + Clipboard Monitor

日常入口
    快捷剪切板浮窗

管理入口
    应用管理页面

快捷面板
    最近 20～50 条
    默认 30 条

历史
    长期保存
    可搜索全部历史

快捷键
    用户可配置

后台
    Tray
    开机启动

云同步
    Optional

远端
    用户自己的 Git Repository

Git
    App 内置 Git 能力
    不依赖系统 Git

V1 数据类型
    Text

服务端
    不提供用户业务数据服务器
```

---

# 43. 开发起点

正式编码从：

```text
Flutter Desktop
    ↓
SQLite
    ↓
Clipboard Read / Write
    ↓
Clipboard Monitor
    ↓
快捷剪切板
```

开始。

不要先做：

```text
Git
云同步
多设备
```

当“本地剪切板 + 快捷面板”已经可以长期稳定使用后，再加入 Git。

---

# 44. 配套文件

本开发文档建议与以下两个文件放在同一个目录：

```text
Idreaml-Clip-开发文档.md
Idreaml-Clip-应用管理页面原型.html
Idreaml-Clip-快捷剪切板原型.html
```

这样 Markdown 中的原型链接可以直接打开对应 HTML 文件。
