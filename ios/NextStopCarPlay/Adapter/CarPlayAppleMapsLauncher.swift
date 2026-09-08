import MapKit
import UIKit

@MainActor
protocol CarPlayAppleMapsLaunching: AnyObject {
  func openPlace(_ mapItem: MKMapItem) async -> Bool
}

@MainActor
protocol CarPlayMapsSceneOpening: AnyObject {
  func openPlaceURL(_ url: URL) async -> Bool
  func openMapItem(_ mapItem: MKMapItem) async -> Bool
}

@MainActor
final class CarPlayAppleMapsLauncher: CarPlayAppleMapsLaunching {
  private let sceneOpener: any CarPlayMapsSceneOpening
  private let placeURL: @MainActor (MKMapItem) -> URL?

  convenience init(scene: UIScene) {
    self.init(sceneOpener: CarPlayMapsSceneOpener(scene: scene))
  }

  init(
    sceneOpener: any CarPlayMapsSceneOpening,
    placeURL: @escaping @MainActor (MKMapItem) -> URL? = { mapItem in
      guard #available(iOS 18.4, *), let identifier = mapItem.identifier?.rawValue else {
        return nil
      }
      return AppleMapsLauncher.placeURL(placeIdentifier: identifier)
    }
  ) {
    self.sceneOpener = sceneOpener
    self.placeURL = placeURL
  }

  func openPlace(_ mapItem: MKMapItem) async -> Bool {
    guard !Task.isCancelled else {
      return false
    }
    if let url = placeURL(mapItem) {
      return await sceneOpener.openPlaceURL(url)
    }
    return await sceneOpener.openMapItem(mapItem)
  }
}

@MainActor
private final class CarPlayMapsSceneOpener: CarPlayMapsSceneOpening {
  private weak var scene: UIScene?

  init(scene: UIScene) {
    self.scene = scene
  }

  func openPlaceURL(_ url: URL) async -> Bool {
    guard !Task.isCancelled, let scene else {
      return false
    }
    let options = UIScene.OpenExternalURLOptions()
    options.universalLinksOnly = true
    return await withCheckedContinuation { continuation in
      // Open the native place card on this CarPlay scene, never the phone or a browser.
      scene.open(url, options: options) { success in
        continuation.resume(returning: success)
      }
    }
  }

  func openMapItem(_ mapItem: MKMapItem) async -> Bool {
    guard !Task.isCancelled, let scene else {
      return false
    }
    return await withCheckedContinuation { continuation in
      // Keep the resolved native item on older iOS versions too. Nil options do not
      // request directions, and the scene must not fall back to the iPhone context.
      mapItem.openInMaps(launchOptions: nil, from: scene) { success in
        continuation.resume(returning: success)
      }
    }
  }
}
