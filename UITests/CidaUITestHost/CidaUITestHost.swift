import SwiftUI

/// The application the user works in when they summon Cida. Selection
/// journeys select text in its editor; capture journeys frame its line of
/// text or its empty area on the real screen.
@main
struct CidaUITestHost: App {
  var body: some Scene {
    WindowGroup("Source application") {
      SourceView()
    }
    .windowResizability(.contentSize)
  }
}

private struct SourceView: View {
  @State private var text = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      Text("CIDA CAPTURE SCENARIO")
        .font(.system(size: 40, weight: .semibold))
        .foregroundStyle(.black)
        .accessibilityIdentifier("source-capture-text")
      TextEditor(text: $text)
        .font(.system(size: 16))
        .frame(height: 96)
        .border(Color.gray.opacity(0.3))
        .accessibilityIdentifier("source-editor")
      Rectangle()
        .fill(Color.white)
        .frame(height: 180)
        .accessibilityElement()
        .accessibilityIdentifier("source-blank")
    }
    .padding(40)
    .frame(width: 760)
    .background(Color.white)
  }
}
