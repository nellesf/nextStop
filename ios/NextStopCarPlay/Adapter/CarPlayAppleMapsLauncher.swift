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
  private let measurement: AppDiagnosticMeasurement

  convenience init(scene: UIScene, diagnostics: any AppDiagnosticRecording = NoopAppDiagnostics()) {
    self.init(sceneOpener: CarPlayMapsSceneOpener(scene: scene), diagnostics: diagnostics)
  }

  init(
    sceneOpener: any CarPlayMapsSceneOpening,
    diagnostics: any AppDiagnosticRecording = NoopAppDiagnostics(),
    now: @escaping AppDiagnosticMeasurement.Now = Date.init,
    placeURL: @escaping @MainActor (MKMapItem) -> URL? = { mapItem in
      guard #available(iOS 18.4, *), let identifier = mapItem.identifier?.rawValue else {
        return nil
      }
      return AppleMapsLauncher.placeURL(placeIdentifier: identifier)
    }
  ) {
    self.sceneOpener = sceneOpener
    self.placeURL = placeURL
    measurement = AppDiagnosticMeasurement(recorder: diagnostics, now: now)
  }

  func openPlace(_ mapItem: MKMapItem) async -> Bool {
    guard !Task.isCancelled else {
      return false
    }
    let startedAt = measurement.now()
    let succeeded: Bool
    if let url = placeURL(mapItem) {
      succeeded = await sceneOpener.openPlaceURL(url)
    } else {
      succeeded = await sceneOpener.openMapItem(mapItem)
    }
    if !succeeded, !Task.isCancelled {
      measurement.recordFailure(.mapsLaunch, startedAt: startedAt)
    }
    return succeeded
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
