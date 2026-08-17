import Foundation
import LocalAuthentication
import Security

enum SettingsStore {
  private static let defaultsKey = "cida.settings.v1"
  private static let productionNamespace = "com.xuanwo.Cida"

  static var storageNamespace: String {
    storageNamespace(for: Bundle.main.bundleIdentifier)
  }

  static func storageNamespace(for bundleIdentifier: String?) -> String {
    guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
      return productionNamespace
    }
    return bundleIdentifier
  }

  static func load(namespace: String = storageNamespace) -> CidaSettings {
    var settings =
      userDefaults(for: namespace).data(forKey: defaultsKey)
      .flatMap { try? JSONDecoder().decode(CidaSettings.self, from: $0) }
      ?? CidaSettings()
    settings.apiKey =
      KeychainStore.readAPIKey(service: namespace, allowsInteraction: false) ?? ""
    return settings
  }

  static func loadAPIKeyAllowingInteraction(
    namespace: String = storageNamespace
  ) -> String? {
    KeychainStore.readAPIKey(service: namespace, allowsInteraction: true)
  }

  static func save(
    _ settings: CidaSettings,
    namespace: String = storageNamespace
  ) {
    var persistedSettings = settings
    persistedSettings.apiKey = ""

    if let data = try? JSONEncoder().encode(persistedSettings) {
      userDefaults(for: namespace).set(data, forKey: defaultsKey)
    }

    if !settings.apiKey.isEmpty {
      KeychainStore.writeAPIKey(settings.apiKey, service: namespace)
    }
  }

  static func clearAPIKey(namespace: String = storageNamespace) {
    KeychainStore.deleteAPIKey(service: namespace)
  }

  static func reset(namespace: String) {
    userDefaults(for: namespace).removeObject(forKey: defaultsKey)
    KeychainStore.deleteAPIKey(service: namespace)
  }

  private static func userDefaults(for namespace: String) -> UserDefaults {
    if namespace == storageNamespace {
      return .standard
    }
    guard let defaults = UserDefaults(suiteName: namespace) else {
      preconditionFailure("Invalid settings storage namespace: \(namespace)")
    }
    return defaults
  }
}

private enum KeychainStore {
  private static let account = "provider-api-key"

  static func readAPIKey(service: String, allowsInteraction: Bool) -> String? {
    let authenticationContext = LAContext()
    authenticationContext.interactionNotAllowed = !allowsInteraction
    authenticationContext.localizedReason = "允许辞达继续使用已保存的 API Key"

    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
      kSecReturnData: true,
      kSecMatchLimit: kSecMatchLimitOne,
      kSecUseAuthenticationContext: authenticationContext,
    ]

    var result: CFTypeRef?
    guard
      SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data
    else {
      return nil
    }
    return String(data: data, encoding: .utf8)
  }

  static func writeAPIKey(_ apiKey: String, service: String) {
    let identity: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
    ]

    guard !apiKey.isEmpty else { return }

    let attributes: [CFString: Any] = [
      kSecValueData: Data(apiKey.utf8),
      kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]

    let status = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      var newItem = identity
      for (key, value) in attributes {
        newItem[key] = value
      }
      SecItemAdd(newItem as CFDictionary, nil)
    }
  }

  static func deleteAPIKey(service: String) {
    let identity: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
    ]
    SecItemDelete(identity as CFDictionary)
  }
}
