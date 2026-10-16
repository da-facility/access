import Flutter
import Foundation
import Security

final class KvmKeychain {
  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "io.dafacility.access/kvm-passwords", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard let args = call.arguments as? [String: Any],
            let account = args["account"] as? String, !account.isEmpty else {
        result(FlutterError(code: "invalid_account", message: "Missing KVM account.", details: nil))
        return
      }
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "io.dafacility.access.kvm-passwords",
        kSecAttrAccount as String: account,
        kSecAttrSynchronizable as String: false,
      ]
      var status: OSStatus
      switch call.method {
      case "read":
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        status = SecItemCopyMatching(lookup as CFDictionary, &value)
        if status == errSecItemNotFound {
          result(nil)
          return
        }
        if status == errSecSuccess, let data = value as? Data,
           let password = String(data: data, encoding: .utf8) {
          result(password)
          return
        }
      case "write":
        guard let password = args["password"] as? String else {
          result(FlutterError(code: "invalid_password", message: "Missing KVM password.", details: nil))
          return
        }
        let attributes: [String: Any] = [
          kSecValueData as String: Data(password.utf8),
          kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
          status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        if status == errSecSuccess {
          result(nil)
          return
        }
      case "delete":
        status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
          result(nil)
          return
        }
      default:
        result(FlutterMethodNotImplemented)
        return
      }
      result(FlutterError(code: "keychain", message: "Could not access the saved KVM password.", details: Int(status)))
    }
  }
}
