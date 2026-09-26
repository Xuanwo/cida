import SwiftUI

enum CapturePresentation: String, CaseIterable, Codable, Sendable {
  case overlay
  case imageWindow = "image-window"

  var title: String {
    switch self {
    case .overlay: "原屏幕覆盖"
    case .imageWindow: "独立图片窗口"
    }
  }
}

struct CapturePresentationRow: View {
  @Bindable var model: AppModel

  var body: some View {
    SettingsRow(title: "截图结果", caption: "下次截图生效") {
      Picker("截图结果", selection: $model.settings.capturePresentation) {
        ForEach(CapturePresentation.allCases, id: \.self) { presentation in
          Text(presentation.title).tag(presentation)
            .accessibilityIdentifier("capture-presentation-\(presentation.rawValue)")
        }
      }
      .labelsHidden()
      .pickerStyle(.segmented)
      .accessibilityIdentifier("settings-capture-presentation")
    }
  }
}
