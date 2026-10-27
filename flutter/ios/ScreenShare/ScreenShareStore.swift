import Foundation
import Security

/// Settings and status shared between the app and the ScreenShare extension
/// through a team keychain group, which needs no App Group registration.
enum ScreenShareStore {
  static let settings = "settings"
  static let status = "status"

  private static var accessGroup: String? {
    Bundle.main.object(forInfoDictionaryKey: "AccessKeychainGroup") as? String
  }

  private static func query(_ account: String) -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "io.dafacility.access.screen-share",
      kSecAttrAccount as String: account,
      kSecAttrSynchronizable as String: false,
    ]
    if let group = accessGroup { query[kSecAttrAccessGroup as String] = group }
    return query
  }

  static func read(_ account: String) -> Data? {
    var lookup = query(account)
    lookup[kSecReturnData as String] = true
    lookup[kSecMatchLimit as String] = kSecMatchLimitOne
    var value: CFTypeRef?
    guard SecItemCopyMatching(lookup as CFDictionary, &value) == errSecSuccess else { return nil }
    return value as? Data
  }

  @discardableResult
  static func write(_ account: String, _ data: Data) -> Bool {
    let item = query(account)
    let update: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    var status = SecItemUpdate(item as CFDictionary, update as CFDictionary)
    if status == errSecItemNotFound {
      status = SecItemAdd(item.merging(update) { $1 } as CFDictionary, nil)
    }
    return status == errSecSuccess
  }
}
