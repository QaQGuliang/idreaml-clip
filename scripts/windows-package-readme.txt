Idreaml Clip（理梦剪藏）— Windows x86-64

使用方法
1. 将整个 ZIP 解压到一个固定目录。
2. 双击 idreaml_clip.exe 启动；请保留旁边的 DLL 和 data 目录。
3. 默认 Ctrl + Shift + V 呼出快捷剪切板，可在设置中更换完整组合。
4. 关闭主窗口后仍在托盘运行；完全退出请使用托盘右键菜单的“退出应用程序”。
5. 同一 Windows 登录会话只运行一个实例，重复启动会打开已有程序的全部历史。

支持 Windows 10 / Windows 11 的 x86-64 系统。
已附带所需的 Visual C++ x64 运行库，无需安装 Flutter 或 Dart。
ZIP 为免安装分发包；应用数据仍保存在当前 Windows 用户的应用数据目录，
不会随此文件夹一起迁移。更新前请退出旧版本，再将新版解压到新目录。
开机自启：在“设置”中开启“开机自动启动”，应用会在当前账户的 Windows
启动文件夹创建 Idreaml Clip.lnk，并在保存后延迟校验。无需手动修改注册表。
1.0.4 构建 2 会迁移此前已开启自启的选择，并清理旧的 Run 项以避免重复启动。
回到主窗口或进入设置时会刷新实际状态，启动项丢失时会提示重新开启。
移动程序后请先打开新目录中的应用；若旧目录仍保留，请在新版设置中开启自启，
将启动项指向新版。Windows 中主动禁用的启动项不会被自动重新开启。

包内不包含开发机器的剪切板历史、访问令牌或同步配置。
版本更新说明见 RELEASE-NOTES.txt，也可在应用“设置 → 版本信息”中查看。
版本及文件校验信息见 build-info.json。
本项目许可见 LICENSE；依赖许可随 Flutter 资源保存在 data/flutter_assets/NOTICES.Z。

Windows ZIP 分发说明：
https://docs.flutter.dev/platform-integration/windows/building#building-your-own-zip-file-for-windows
