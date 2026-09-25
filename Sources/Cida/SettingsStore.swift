import Foundation
import LocalAuthentication
import Security
import ServiceManagement

/// Where settings live: the JSON of `CidaSettings` and the last check in UserDefaults, the API
/// key in the Keychain, all under one namespace (the bundle identifier, or an isolated
/// `com.xuanwo.Cida.Automation.*` one for tests).
enum SettingsStore {
  private static let defaultsKey = "cida.settings.v1"
  private static let lastCheckKey = "cida.model-service.last-check"
  /// Sparkle's own preference for daily checks, in the application's domain.
  private static let automaticUpdatesKey = "SUEnableAutomaticChecks"
  private static let productionNamespace = "com.xuanwo.Cida"
  static let automationNamespacePrefix = "com.xuanwo.Cida.Automation."

  static var storageNamespace: String {
    storageNamespace(for: Bundle.main.bundleIdentifier)
  }

  static func storageNamespace(for bundleIdentifier: String?) -> String {
    guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
      return productionNamespace
    }
    return bundleIdentifier
  }

  /// The command line works on the application's own settings. UI automation points it at the
  /// isolated namespace of the instance under test instead.
  static func commandLineNamespace(environment: [String: String]) -> String {
    if environment["CIDA_ISOLATED_AUTOMATION"] == "1",
      let namespace = environment["CIDA_AUTOMATION_SETTINGS_NAMESPACE"],
      namespace.hasPrefix(automationNamespacePrefix)
    {
      return namespace
    }
    return storageNamespace
  }

  static func load(namespace: String = storageNamespace) -> CidaSettings {
    var settings = loadWithoutAPIKey(namespace: namespace)
    settings.apiKey =
      KeychainStore.readAPIKey(service: namespace, allowsInteraction: false) ?? ""
    return settings
  }

  static func loadWithoutAPIKey(namespace: String = storageNamespace) -> CidaSettings {
    userDefaults(for: namespace).data(forKey: defaultsKey)
      .flatMap { try? JSONDecoder().decode(CidaSettings.self, from: $0) }
      ?? CidaSettings()
  }

  static func loadAPIKeyAllowingInteraction(
    namespace: String = storageNamespace
  ) -> String? {
    KeychainStore.readAPIKey(service: namespace, allowsInteraction: true)
  }

  /// Writes everything but the key, which only the command line changes.
  static func save(
    _ settings: CidaSettings,
    namespace: String = storageNamespace
  ) {
    if let data = try? JSONEncoder().encode(settings) {
      userDefaults(for: namespace).set(data, forKey: defaultsKey)
    }
  }

  /// Writes what the application itself changes (prompts, shortcuts, launch at login) over the
  /// stored settings. The model service is left as stored: only the command line writes it, and
  /// an older copy in memory must not undo its change.
  static func saveApplicationSettings(
    _ settings: CidaSettings,
    namespace: String = storageNamespace
  ) {
    var stored = loadWithoutAPIKey(namespace: namespace)
    stored.translationPrompt = settings.translationPrompt
    stored.improvementPrompt = settings.improvementPrompt
    stored.shortcut = settings.shortcut
    stored.captureShortcut = settings.captureShortcut
    stored.launchAtLogin = settings.launchAtLogin
    save(stored, namespace: namespace)
  }

  static func hasAPIKey(namespace: String = storageNamespace) -> Bool {
    KeychainStore.containsAPIKey(service: namespace)
  }

  static func saveAPIKey(_ apiKey: String, namespace: String = storageNamespace) throws {
    try KeychainStore.writeAPIKey(apiKey, service: namespace)
  }

  static func clearAPIKey(namespace: String = storageNamespace) {
    KeychainStore.deleteAPIKey(service: namespace)
  }

  static func loadLastCheck(namespace: String = storageNamespace) -> ModelServiceCheckRecord? {
    userDefaults(for: namespace).data(forKey: lastCheckKey)
      .flatMap { try? JSONDecoder().decode(ModelServiceCheckRecord.self, from: $0) }
  }

  static func saveLastCheck(
    _ record: ModelServiceCheckRecord?, namespace: String = storageNamespace
  ) {
    let defaults = userDefaults(for: namespace)
    if let record, let data = try? JSONEncoder().encode(record) {
      defaults.set(data, forKey: lastCheckKey)
    } else {
      defaults.removeObject(forKey: lastCheckKey)
    }
  }

  /// Whether Sparkle checks daily; Info.plist turns it on until the user says otherwise.
  static func automaticUpdatesEnabled(namespace: String = storageNamespace) -> Bool {
    userDefaults(for: namespace).object(forKey: automaticUpdatesKey) as? Bool ?? true
  }

  static func setAutomaticUpdatesEnabled(_ enabled: Bool, namespace: String = storageNamespace) {
    userDefaults(for: namespace).set(enabled, forKey: automaticUpdatesKey)
  }

  /// Hands this process's writes to the preferences daemon and drops what it cached. Another
  /// process wrote or will read the settings: the command line calls this before it announces a
  /// change, and a running Cida before it reloads, since each process caches its preferences.
  static func synchronize(namespace: String) {
    // `userDefaults(for:)` uses the standard defaults for the storage namespace.
    CFPreferencesAppSynchronize(
      namespace == storageNamespace ? kCFPreferencesCurrentApplication : namespace as CFString)
  }

  static func reset(namespace: String) {
    let defaults = userDefaults(for: namespace)
    defaults.removeObject(forKey: defaultsKey)
    defaults.removeObject(forKey: lastCheckKey)
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

/// Tells a running Cida that the command line changed its settings or recorded a check, so an
/// open Settings window refreshes and the next request uses the new configuration. The object
/// is the settings namespace, so a test instance hears only its own changes.
enum ConfigurationChangeNotification {
  static let name = Notification.Name("com.xuanwo.Cida.configuration-did-change")

  static func post(namespace: String) {
    DistributedNotificationCenter.default().postNotificationName(
      name, object: namespace, userInfo: nil, deliverImmediately: true)
  }

  /// Calls `handler` on the main queue for every change in `namespace`; keep the token.
  static func observe(
    namespace: String,
    handler: @escaping @MainActor () -> Void
  ) -> NSObjectProtocol {
    DistributedNotificationCenter.default().addObserver(
      forName: name, object: namespace, queue: .main
    ) { _ in
      MainActor.assumeIsolated { handler() }
    }
  }
}

/// Everything the command line reads and writes, as closures so tests can run the commands
/// against memory. `production` binds them to `SettingsStore`, the Keychain, Sparkle's
/// preference, the login item and the change notification.
struct ConfigurationStore: Sendable {
  var loadSettings: @Sendable () -> CidaSettings
  var saveSettings: @Sendable (CidaSettings) -> Void
  var hasAPIKey: @Sendable () -> Bool
  /// Only `check` reads the key, to send it.
  var readAPIKey: @Sendable () -> String?
  var saveAPIKey: @Sendable (String) throws -> Void
  var clearAPIKey: @Sendable () -> Void
  var loadLastCheck: @Sendable () -> ModelServiceCheckRecord?
  var saveLastCheck: @Sendable (ModelServiceCheckRecord?) -> Void
  var automaticUpdates: @Sendable () -> Bool
  var setAutomaticUpdates: @Sendable (Bool) -> Void
  /// The login item's state; outside an app bundle, the stored preference.
  var launchAtLogin: @Sendable (CidaSettings) -> Bool
  var setLaunchAtLogin: @Sendable (Bool) throws -> Void
  var notifyChange: @Sendable () -> Void

  static func production(namespace: String) -> ConfigurationStore {
    let managesLoginItem =
      namespace == SettingsStore.storageNamespace
      && Bundle.main.bundleURL.pathExtension == "app"
    return ConfigurationStore(
      loadSettings: { SettingsStore.loadWithoutAPIKey(namespace: namespace) },
      saveSettings: { SettingsStore.save($0, namespace: namespace) },
      hasAPIKey: { SettingsStore.hasAPIKey(namespace: namespace) },
      readAPIKey: {
        KeychainStore.readAPIKey(service: namespace, allowsInteraction: false)
      },
      saveAPIKey: { try SettingsStore.saveAPIKey($0, namespace: namespace) },
      clearAPIKey: { SettingsStore.clearAPIKey(namespace: namespace) },
      loadLastCheck: { SettingsStore.loadLastCheck(namespace: namespace) },
      saveLastCheck: { SettingsStore.saveLastCheck($0, namespace: namespace) },
      automaticUpdates: { SettingsStore.automaticUpdatesEnabled(namespace: namespace) },
      setAutomaticUpdates: { SettingsStore.setAutomaticUpdatesEnabled($0, namespace: namespace) },
      launchAtLogin: { settings in
        managesLoginItem ? SMAppService.mainApp.status == .enabled : settings.launchAtLogin
      },
      setLaunchAtLogin: { enabled in
        guard managesLoginItem else { return }
        if enabled {
          try SMAppService.mainApp.register()
        } else {
          try SMAppService.mainApp.unregister()
        }
      },
      notifyChange: {
        SettingsStore.synchronize(namespace: namespace)
        ConfigurationChangeNotification.post(namespace: namespace)
      }
    )
  }
}

enum KeychainStoreError: LocalizedError {
  case status(OSStatus)

  var errorDescription: String? {
    switch self {
    case .status(let status):
      let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
      return "钥匙串拒绝写入：\(message)"
    }
  }
}

private enum KeychainStore {
  private static let account = "provider-api-key"

  private static func identity(service: String) -> [CFString: Any] {
    [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
    ]
  }

  static func readAPIKey(service: String, allowsInteraction: Bool) -> String? {
    let authenticationContext = LAContext()
    authenticationContext.interactionNotAllowed = !allowsInteraction
    authenticationContext.localizedReason = "允许辞达继续使用已保存的 API Key"

    var query = identity(service: service)
    query[kSecReturnData] = true
    query[kSecMatchLimit] = kSecMatchLimitOne
    query[kSecUseAuthenticationContext] = authenticationContext

    var result: CFTypeRef?
    guard
      SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data
    else {
      return nil
    }
    return String(data: data, encoding: .utf8)
  }

  /// Asks for the item's attributes only, so the key itself is never read.
  static func containsAPIKey(service: String) -> Bool {
    var query = identity(service: service)
    query[kSecReturnAttributes] = true
    query[kSecMatchLimit] = kSecMatchLimitOne
    return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
  }

  static func writeAPIKey(_ apiKey: String, service: String) throws {
    guard !apiKey.isEmpty else { return }

    let attributes: [CFString: Any] = [
      kSecValueData: Data(apiKey.utf8),
      kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]

    var status = SecItemUpdate(
      identity(service: service) as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      var newItem = identity(service: service)
      for (key, value) in attributes {
        newItem[key] = value
      }
      status = SecItemAdd(newItem as CFDictionary, nil)
    }
    guard status == errSecSuccess else { throw KeychainStoreError.status(status) }
  }

  static func deleteAPIKey(service: String) {
    SecItemDelete(identity(service: service) as CFDictionary)
  }
}
