import Flutter
import UIKit
import UniformTypeIdentifiers

@main
@objc class AppDelegate: FlutterAppDelegate, UIDocumentPickerDelegate {
  private var pendingPick: FlutterResult?
  private var pendingExport: FlutterResult?
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(name: "ipa_assert_repair/files", binaryMessenger: controller.binaryMessenger)
      channel.setMethodCallHandler { [weak self] call, result in
        guard let self = self else { return }
        switch call.method {
        case "pickIpa":
          guard self.pendingPick == nil, self.pendingExport == nil else {
            result(FlutterError(code: "busy", message: "文件窗口已打开", details: nil)); return
          }
          self.pendingPick = result
          let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
          picker.delegate = self
          picker.allowsMultipleSelection = false
          self.presenter()?.present(picker, animated: true)
        case "workspace":
          do {
            let directory = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
              .appendingPathComponent("Repairs", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            result(directory.path)
          } catch {
            result(FlutterError(code: "workspace", message: error.localizedDescription, details: nil))
          }
        case "exportFile":
          guard let arguments = call.arguments as? [String: String], let path = arguments["path"],
                FileManager.default.fileExists(atPath: path), self.pendingPick == nil, self.pendingExport == nil else {
            result(FlutterError(code: "export", message: "文件不存在或窗口正忙", details: nil)); return
          }
          self.pendingExport = result
          let picker = UIDocumentPickerViewController(forExporting: [URL(fileURLWithPath: path)], asCopy: true)
          picker.delegate = self
          self.presenter()?.present(picker, animated: true)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func presenter() -> UIViewController? {
    var controller = window?.rootViewController
    while let presented = controller?.presentedViewController { controller = presented }
    return controller
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    pendingPick?(nil); pendingPick = nil
    pendingExport?(false); pendingExport = nil
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    if let exportResult = pendingExport {
      pendingExport = nil; exportResult(!urls.isEmpty); return
    }
    guard let result = pendingPick else { return }
    pendingPick = nil
    guard let url = urls.first else { result(nil); return }
    guard url.pathExtension.lowercased() == "ipa" else {
      result(FlutterError(code: "fileType", message: "请选择 .ipa 安装包", details: nil)); return
    }
    DispatchQueue.global(qos: .userInitiated).async {
      let scoped = url.startAccessingSecurityScopedResource()
      defer { if scoped { url.stopAccessingSecurityScopedResource() } }
      do {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("IpaImports", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(UUID().uuidString + ".ipa")
        var copyError: Error?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { coordinatedURL in
          do { try FileManager.default.copyItem(at: coordinatedURL, to: destination) }
          catch { copyError = error }
        }
        if let error = coordinationError { throw error }
        if let error = copyError { throw error }
        let size = (try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
        DispatchQueue.main.async { result(["path": destination.path, "name": url.lastPathComponent, "bytes": size]) }
      } catch {
        DispatchQueue.main.async { result(FlutterError(code: "import", message: error.localizedDescription, details: nil)) }
      }
    }
  }
}
