import Foundation

enum CidaResourceBundle {
  static let bundle: Bundle = {
    if let packagedURL = Bundle.main.resourceURL?
      .appendingPathComponent("Cida_Cida.bundle", isDirectory: true),
      let packagedBundle = Bundle(url: packagedURL)
    {
      return packagedBundle
    }

    return Bundle.module
  }()
}
