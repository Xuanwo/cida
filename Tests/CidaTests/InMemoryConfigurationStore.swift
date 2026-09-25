import Foundation

@testable import Cida

/// Settings, Keychain, preferences, stdin, files and output for command-line tests, all in
/// memory, so no test reads or writes the user's settings or Keychain.
final class InMemoryConfigurationStore: @unchecked Sendable {
  private let lock = NSLock()
  private var storedSettings = CidaSettings()
  private var storedAPIKey: String?
  private var storedLastCheck: ModelServiceCheckRecord?
  private var storedAutomaticUpdates = true
  private var storedLaunchAtLogin = false
  private var notifications = 0
  private var outputLines: [String] = []
  private var errorLines: [String] = []

  var standardInput = Data()
  var files: [String: Data] = [:]
  var environment: [String: String] = [:]

  init(settings: CidaSettings = CidaSettings(), apiKey: String? = nil) {
    storedSettings = settings
    storedSettings.apiKey = ""
    storedAPIKey = apiKey
  }

  private func locked<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }

  var settings: CidaSettings { locked { storedSettings } }
  var apiKey: String? { locked { storedAPIKey } }
  var lastCheck: ModelServiceCheckRecord? { locked { storedLastCheck } }
  var automaticUpdates: Bool { locked { storedAutomaticUpdates } }
  var launchAtLogin: Bool { locked { storedLaunchAtLogin } }
  var notificationCount: Int { locked { notifications } }
  var output: String { locked { outputLines.joined(separator: "\n") } }
  var errorOutput: String { locked { errorLines.joined(separator: "\n") } }

  var settingsWithAPIKey: CidaSettings {
    locked {
      var settings = storedSettings
      settings.apiKey = storedAPIKey ?? ""
      return settings
    }
  }

  func clearOutput() {
    locked {
      outputLines = []
      errorLines = []
    }
  }

  var store: ConfigurationStore {
    ConfigurationStore(
      loadSettings: { self.settings },
      saveSettings: { settings in
        self.locked {
          self.storedSettings = settings
          self.storedSettings.apiKey = ""
        }
      },
      hasAPIKey: { self.apiKey != nil },
      readAPIKey: { self.apiKey },
      saveAPIKey: { key in self.locked { self.storedAPIKey = key } },
      clearAPIKey: { self.locked { self.storedAPIKey = nil } },
      loadLastCheck: { self.lastCheck },
      saveLastCheck: { record in self.locked { self.storedLastCheck = record } },
      automaticUpdates: { self.automaticUpdates },
      setAutomaticUpdates: { enabled in self.locked { self.storedAutomaticUpdates = enabled } },
      launchAtLogin: { _ in self.launchAtLogin },
      setLaunchAtLogin: { enabled in self.locked { self.storedLaunchAtLogin = enabled } },
      notifyChange: { self.locked { self.notifications += 1 } }
    )
  }

  func context(
    check: @escaping @Sendable (CidaSettings) async -> ModelServiceCheckResult = {
      await ModelServiceCheck.run(settings: $0)
    }
  ) -> CommandLineInterface.Context {
    CommandLineInterface.Context(
      store: store,
      environment: environment,
      readStandardInput: { self.standardInput },
      readFile: { path in
        guard let data = self.files[path] else {
          throw CocoaError(.fileReadNoSuchFile)
        }
        return data
      },
      output: { line in self.locked { self.outputLines.append(line) } },
      errorOutput: { line in self.locked { self.errorLines.append(line) } },
      check: check
    )
  }
}
