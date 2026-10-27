import Flutter
import Foundation
import ReplayKit
import UIKit

/// Prepares and starts the ScreenShare broadcast extension, which hosts the
/// RustDesk session while the user is in other apps.
final class ScreenShareChannel {
  private static let extensionId = "io.dafacility.rustdesk.glinet.ScreenShare"

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "io.dafacility.access/screen-share", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "prepare":
        guard let args = call.arguments as? [String: Any],
          let data = try? JSONSerialization.data(withJSONObject: args),
          ScreenShareStore.write(ScreenShareStore.settings, data)
        else {
          result(FlutterError(code: "invalid", message: "Could not save the share settings.", details: nil))
          return
        }
        result(nil)
      case "status":
        var status: [String: Any] = ["sharing": UIScreen.main.isCaptured]
        if let data = ScreenShareStore.read(ScreenShareStore.status),
          let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
          status.merge(saved) { current, _ in current }
        }
        result(status)
      case "start":
        showPicker()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// iOS only lets the user start a broadcast from the system picker, so tap
  /// its button on their behalf.
  private static func showPicker() {
    let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
    picker.preferredExtension = extensionId
    picker.showsMicrophoneButton = false
    let window = UIApplication.shared.connectedScenes
      .compactMap { ($0 as? UIWindowScene)?.windows.first { $0.isKeyWindow } }
      .first
    window?.addSubview(picker)
    for case let button as UIButton in picker.subviews {
      button.sendActions(for: .touchUpInside)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { picker.removeFromSuperview() }
  }
}
