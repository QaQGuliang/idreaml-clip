import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var directoryChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    directoryChannel = FlutterMethodChannel(
      name: "idreaml_clip/directories", messenger: flutterViewController.engine.binaryMessenger)
    directoryChannel?.setMethodCallHandler { [weak self] call, result in
      guard call.method == "chooseDirectory" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let self = self else {
        result(FlutterError(code: "directory_dialog", message: "窗口已关闭", details: nil))
        return
      }
      let panel = NSOpenPanel()
      panel.title = "选择数据存储目录"
      panel.prompt = "选择文件夹"
      panel.canChooseFiles = false
      panel.canChooseDirectories = true
      panel.canCreateDirectories = true
      panel.allowsMultipleSelection = false
      if let initial = call.arguments as? String, !initial.isEmpty {
        panel.directoryURL = URL(fileURLWithPath: initial, isDirectory: true)
      }
      panel.beginSheetModal(for: self) { response in
        result(response == .OK ? panel.url?.path : nil)
      }
    }

    super.awakeFromNib()
  }
}
