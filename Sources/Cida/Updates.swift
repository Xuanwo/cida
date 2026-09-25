import AppKit
import Sparkle

/// What Settings and the menu bar show about updates (`Design/spec/updates.md`).
@MainActor
@Observable
final class UpdateState {
  /// Whether Cida checks the feed once a day on its own.
  private(set) var automaticallyChecks: Bool
  /// A newer version a scheduled check found while the user was elsewhere; the menu bar item and
  /// Settings offer to install it instead of interrupting with a window.
  var availableVersion: String?

  @ObservationIgnored var performCheck: @MainActor () -> Void = {}
  @ObservationIgnored var applyAutomaticChecks: @MainActor (Bool) -> Void = { _ in }

  init(automaticallyChecks: Bool = true, availableVersion: String? = nil) {
    self.automaticallyChecks = automaticallyChecks
    self.availableVersion = availableVersion
  }

  /// Checks now, or installs the version a scheduled check found, in Sparkle's window.
  func checkForUpdates() {
    performCheck()
  }

  func setAutomaticallyChecks(_ enabled: Bool) {
    automaticallyChecks = enabled
    applyAutomaticChecks(enabled)
  }

  /// A scheduled check found `version` and Sparkle leaves showing it to Cida.
  func remindLater(of version: String) {
    availableVersion = version
  }

  /// The update session ended: installed, skipped, or dismissed.
  func clearReminder() {
    availableVersion = nil
  }
}

/// Runs Sparkle against the feed and public key in Info.plist. A release candidate
/// (`CidaUpdateChannel` = beta) also receives later candidates; any other build receives only
/// releases. Scheduled checks never open a window while the user works elsewhere: they leave
/// `UpdateState.availableVersion` for the menu bar item instead.
@MainActor
final class CidaUpdater: NSObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
  let state: UpdateState
  private let channel: String?
  private var controller: SPUStandardUpdaterController?

  init(bundle: Bundle = .main) {
    channel = bundle.object(forInfoDictionaryKey: "CidaUpdateChannel") as? String
    state = UpdateState()
    super.init()
  }

  /// Whether this build can update itself: an app bundle with a feed and a public key. `swift
  /// run` and automation builds without them never talk to the feed.
  static func isConfigured(in bundle: Bundle = .main) -> Bool {
    bundle.bundleURL.pathExtension == "app"
      && bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String != nil
      && !((bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String) ?? "").isEmpty
  }

  /// Starts Sparkle; `state` then follows the preference Sparkle keeps.
  func start() {
    let controller = SPUStandardUpdaterController(
      startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
    self.controller = controller
    state.setAutomaticallyChecks(controller.updater.automaticallyChecksForUpdates)
    state.performCheck = { [weak self] in
      guard let controller = self?.controller else { return }
      // Sparkle's window belongs in front: the user asked for it.
      NSApp.activate(ignoringOtherApps: true)
      controller.checkForUpdates(nil)
    }
    state.applyAutomaticChecks = { [weak self] enabled in
      self?.controller?.updater.automaticallyChecksForUpdates = enabled
    }
  }

  /// Sparkle channels beyond the default one that this build accepts.
  var allowedChannels: Set<String> {
    channel == "beta" ? ["beta"] : []
  }

  // MARK: SPUUpdaterDelegate

  func allowedChannels(for updater: SPUUpdater) -> Set<String> {
    allowedChannels
  }

  // MARK: SPUStandardUserDriverDelegate

  var supportsGentleScheduledUpdateReminders: Bool { true }

  func standardUserDriverShouldHandleShowingScheduledUpdate(
    _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
  ) -> Bool {
    // Right after launch the user is looking at Cida; otherwise wait for them.
    immediateFocus
  }

  func standardUserDriverWillHandleShowingUpdate(
    _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
  ) {
    if !handleShowingUpdate {
      self.state.remindLater(of: update.displayVersionString)
    }
  }

  func standardUserDriverWillFinishUpdateSession() {
    state.clearReminder()
  }
}
