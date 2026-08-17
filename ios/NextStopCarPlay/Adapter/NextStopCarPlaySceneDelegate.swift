import CarPlay
import CoreLocation
import Foundation
import MapKit
import NextStopCore
import SwiftData
import UIKit

@MainActor
final class NextStopCarPlaySceneDelegate: NSObject, CPTemplateApplicationSceneDelegate {
  private var interfaceController: CPInterfaceController?
  private var dataContainer: ModelContainer?
  private var rideSummaryTemplate: CPListTemplate?
  private var noResultsTemplate: CPListTemplate?
  private var searchTask: Task<Void, Never>?
  private var resultsByID: [UUID: RouteSearchResult] = [:]

  private let localizer = CarPlayLocalizer()
  private let presenter = CarPlayPresenter()
  private let draftController = CarPlayRideDraftController()
  private let searchService: any CarPlayRideSearchExecuting = CarPlayRideSearchService()
  private let navigationLauncher: any NavigationLaunching = AppleMapsNavigationLauncher()

  func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didConnect interfaceController: CPInterfaceController
  ) {
    self.interfaceController = interfaceController
    showProfiles(animated: false)
  }

  func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didDisconnectInterfaceController interfaceController: CPInterfaceController
  ) {
    searchTask?.cancel()
    searchTask = nil
    resultsByID = [:]
    rideSummaryTemplate = nil
    noResultsTemplate = nil
    self.interfaceController = nil
  }

  private func showProfiles(animated: Bool) {
    searchTask?.cancel()
    searchTask = nil
    rideSummaryTemplate = nil
    noResultsTemplate = nil
    resultsByID = [:]

    let template: CPListTemplate
    do {
      template = try makeProfilesTemplate()
    } catch {
      template = makeProfileErrorTemplate()
    }
    interfaceController?.setRootTemplate(template, animated: animated) { _, _ in }
  }

  private func makeProfilesTemplate() throws -> CPListTemplate {
    let container = try ModelContainer(for: StoredProfile.self, StoredDestinationRecord.self)
    dataContainer = container
    let profiles = try SwiftDataProfileRepository(
      modelContext: container.mainContext
    ).fetchProfiles()
    let destinationRepository = SwiftDataDestinationRepository(
      modelContext: container.mainContext
    )
    let favorites = try destinationRepository.fetchFavorites()
    let favoriteIDs = Set(favorites.map(\.id))
    let recents = try destinationRepository.fetchRecents().filter {
      !favoriteIDs.contains($0.id)
    }
    let profileByID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
    var remainingItemCount = CPListTemplate.maximumItemCount
    let profileItems = presenter.profiles(profiles)
      .prefix(remainingItemCount)
      .map { profile in
        let item = CPListItem(text: profile.title, detailText: profile.detail)
        item.accessoryType = .disclosureIndicator
        item.handler = { [weak self] _, completion in
          defer { completion() }
          guard let selectedProfile = profileByID[profile.id] else {
            return
          }
          self?.showRideSummary(profile: selectedProfile)
        }
        return item
      }
    remainingItemCount -= profileItems.count
    let favoriteItems = makeDestinationItems(
      favorites.prefix(remainingItemCount)
    )
    remainingItemCount -= favoriteItems.count
    let recentItems = makeDestinationItems(recents.prefix(remainingItemCount))

    var sections: [CPListSection] = []
    if !profileItems.isEmpty {
      sections.append(
        CPListSection(
          items: profileItems,
          header: localizer.text("carplay.profiles.title"),
          sectionIndexTitle: nil
        )
      )
    }
    if !favoriteItems.isEmpty {
      sections.append(
        CPListSection(
          items: favoriteItems,
          header: localizer.text("destinations.favorites"),
          sectionIndexTitle: nil
        )
      )
    }
    if !recentItems.isEmpty {
      sections.append(
        CPListSection(
          items: recentItems,
          header: localizer.text("destinations.recents"),
          sectionIndexTitle: nil
        )
      )
    }
    let template = CPListTemplate(
      title: localizer.text("carplay.saved_rides.title"),
      sections: sections
    )
    template.emptyViewTitleVariants = [localizer.text("carplay.saved_rides.empty.title")]
    template.emptyViewSubtitleVariants = [
      localizer.text("carplay.saved_rides.empty.description")
    ]
    template.trailingNavigationBarButtons = [
      CPBarButton(title: localizer.text("carplay.refresh")) { [weak self] _ in
        self?.showProfiles(animated: false)
      }
    ]
    return template
  }

  private func makeDestinationItems<S: Sequence>(
    _ records: S
  ) -> [CPListItem] where S.Element == LocalDestinationRecord {
    records.map { record in
      let item = CPListItem(
        text: record.destination.displayName,
        detailText: record.destination.displayAddress
      )
      item.accessoryType = .disclosureIndicator
      item.handler = { [weak self] _, completion in
        self?.showRideSummary(destination: record.destination)
        completion()
      }
      return item
    }
  }

  private func makeProfileErrorTemplate() -> CPListTemplate {
    let retry = CPListItem(
      text: localizer.text("carplay.retry"),
      detailText: nil
    )
    retry.handler = { [weak self] _, completion in
      self?.showProfiles(animated: false)
      completion()
    }
    return CPListTemplate(
      title: localizer.text("carplay.saved_rides.title"),
      sections: [CPListSection(items: [retry])]
    )
  }

  private func showRideSummary(profile: UserProfile) {
    recordRecent(profile.destination)
    draftController.select(profile: profile)
    showRideSummary()
  }

  private func showRideSummary(destination: SavedDestination) {
    recordRecent(destination)
    draftController.select(destination: destination)
    showRideSummary()
  }

  private func showRideSummary() {
    guard let draft = draftController.draft else {
      return
    }
    let template = CPListTemplate(
      title: presenter.rideSummary(draft).title,
      sections: makeRideSummarySections(draft)
    )
    rideSummaryTemplate = template
    interfaceController?.pushTemplate(template, animated: true) { _, _ in }
  }

  private func recordRecent(_ destination: SavedDestination) {
    guard let context = dataContainer?.mainContext else {
      return
    }
    try? SwiftDataDestinationRepository(modelContext: context)
      .recordRecent(destination, at: Date())
  }

  private func makeRideSummarySections(_ draft: RideSearchDraft) -> [CPListSection] {
    let presentation = presenter.rideSummary(draft)
    let destination = CPListItem(
      text: localizer.text("profile.destination"),
      detailText: presentation.destination
    )
    destination.isEnabled = false

    let criteria = presentation.criteria.map { criterion in
      let item = CPListItem(text: criterion.title, detailText: criterion.value)
      item.accessoryType = .disclosureIndicator
      item.handler = { [weak self] _, completion in
        self?.showOptions(for: criterion.field)
        completion()
      }
      return item
    }

    let search = CPListItem(text: presentation.searchActionTitle, detailText: nil)
    search.handler = { [weak self] _, completion in
      self?.startSearch()
      completion()
    }

    return [
      CPListSection(items: [destination]),
      CPListSection(items: criteria),
      CPListSection(items: [search]),
    ]
  }

  private func showOptions(for field: CarPlayCriteriaField) {
    guard let draft = draftController.draft else {
      return
    }
    let options = presenter.options(for: field, draft: draft)
    let items = options.map { option in
      let item = CPListItem(text: option.title, detailText: nil)
      if option.selected {
        item.setAccessoryImage(UIImage(systemName: "checkmark"))
      }
      item.handler = { [weak self] _, completion in
        self?.apply(option.selection)
        self?.interfaceController?.popTemplate(animated: true) { _, _ in }
        completion()
      }
      return item
    }
    let title = presenter.rideSummary(draft).criteria
      .first(where: { $0.field == field })?.title
    let template = CPListTemplate(
      title: title,
      sections: [CPListSection(items: items)]
    )
    interfaceController?.pushTemplate(template, animated: true) { _, _ in }
  }

  private func apply(_ selection: CarPlayCriteriaSelection) {
    draftController.apply(selection)
    guard let draft = draftController.draft else {
      return
    }
    rideSummaryTemplate?.updateSections(makeRideSummarySections(draft))
    noResultsTemplate?.updateSections(makeNoResultsSections(draft))
  }

  private func startSearch() {
    guard let draft = draftController.draft else {
      return
    }
    searchTask?.cancel()
    noResultsTemplate = nil

    let loadingItem = CPListItem(
      text: localizer.text("carplay.search.loading.title"),
      detailText: localizer.text("carplay.search.loading.description")
    )
    loadingItem.isEnabled = false
    let loading = CPListTemplate(
      title: localizer.text("ride.results.title"),
      sections: [CPListSection(items: [loadingItem])]
    )
    interfaceController?.pushTemplate(loading, animated: true) { _, _ in }

    searchTask = Task { [weak self] in
      guard let self else {
        return
      }
      do {
        let outcome = try await searchService.search(draft: draft)
        try Task.checkCancellation()
        if outcome.results.isEmpty {
          showNoResults(in: loading, draft: draft)
        } else {
          showResults(outcome)
        }
      } catch is CancellationError {
        return
      } catch let error as CarPlayRideSearchError {
        showSearchError(error, in: loading)
      } catch {
        showSearchError(.serviceUnavailable, in: loading)
      }
    }
  }

  private func showNoResults(in template: CPListTemplate, draft: RideSearchDraft) {
    noResultsTemplate = template
    template.updateSections(makeNoResultsSections(draft))
    template.emptyViewTitleVariants = [localizer.text("ride.search.empty.title")]
    template.emptyViewSubtitleVariants = [localizer.text("ride.search.empty.description")]
  }

  private func makeNoResultsSections(_ draft: RideSearchDraft) -> [CPListSection] {
    let message = CPListItem(
      text: localizer.text("ride.search.empty.title"),
      detailText: localizer.text("ride.search.empty.description")
    )
    message.isEnabled = false

    let criteria = presenter.rideSummary(draft).criteria.map { criterion in
      let item = CPListItem(text: criterion.title, detailText: criterion.value)
      item.accessoryType = .disclosureIndicator
      item.handler = { [weak self] _, completion in
        self?.showOptions(for: criterion.field)
        completion()
      }
      return item
    }
    let retry = CPListItem(text: localizer.text("carplay.retry"), detailText: nil)
    retry.handler = { [weak self] _, completion in
      self?.startSearch()
      completion()
    }
    return [
      CPListSection(items: [message]),
      CPListSection(items: criteria),
      CPListSection(items: [retry]),
    ]
  }

  private func showSearchError(
    _ error: CarPlayRideSearchError,
    in template: CPListTemplate
  ) {
    let message = CPListItem(
      text: localizer.text("ride.search.error.title"),
      detailText: localizer.text(error.localizationKey)
    )
    message.isEnabled = false
    let retry = CPListItem(text: localizer.text("carplay.retry"), detailText: nil)
    retry.handler = { [weak self] _, completion in
      self?.startSearch()
      completion()
    }
    template.updateSections([
      CPListSection(items: [message]),
      CPListSection(items: [retry]),
    ])
  }

  private func showResults(_ outcome: RideCandidateSearchOutcome) {
    guard let criteria = draftController.draft?.criteria else {
      return
    }
    let presentation = presenter.results(outcome, criteria: criteria)
    resultsByID = Dictionary(
      uniqueKeysWithValues: outcome.results.map { ($0.candidate.park.id, $0) }
    )
    let points = presentation.points.map { point in
      makePointOfInterest(point, coverageMessage: presentation.coverageMessage)
    }
    let template = CPPointOfInterestTemplate(
      title: presentation.title,
      pointsOfInterest: points,
      selectedIndex: NSNotFound
    )
    template.pointOfInterestDelegate = self
    template.trailingNavigationBarButtons = [
      CPBarButton(title: localizer.text("ride.search.refresh")) { [weak self] _ in
        self?.startSearch()
      }
    ]

    guard let summary = rideSummaryTemplate else {
      interfaceController?.setRootTemplate(template, animated: false) { _, _ in }
      return
    }
    interfaceController?.pop(to: summary, animated: false) { [weak self] _, _ in
      self?.interfaceController?.pushTemplate(template, animated: true) { _, _ in }
    }
  }

  private func makePointOfInterest(
    _ presentation: CarPlayResultPresentation,
    coverageMessage: String?
  ) -> CPPointOfInterest {
    let mapItem = makeMapItem(
      coordinate: presentation.coordinate,
      name: presentation.title
    )
    let detailSummary = [presentation.detailSummary, coverageMessage]
      .compactMap { $0 }
      .joined(separator: "\n")
    let point = CPPointOfInterest(
      location: mapItem,
      title: presentation.title,
      subtitle: presentation.subtitle,
      summary: presentation.summary,
      detailTitle: presentation.detailTitle,
      detailSubtitle: presentation.detailSubtitle,
      detailSummary: detailSummary.isEmpty ? nil : detailSummary,
      pinImage: nil,
      selectedPinImage: nil
    )
    point.userInfo = presentation.id as NSUUID
    point.primaryButton = CPTextButton(
      title: presentation.navigationActionTitle,
      textStyle: .confirm
    ) { [weak self] _ in
      self?.startNavigation(to: presentation.id)
    }
    return point
  }

  private func startNavigation(to resultID: UUID) {
    guard let result = resultsByID[resultID],
      let destination = draftController.draft?.destination,
      navigationLauncher.startNavigation(
        to: result.candidate.park,
        via: result.matchingFoodPOI,
        finalDestination: destination
      )
    else {
      showNavigationFailure()
      return
    }
  }

  private func showNavigationFailure() {
    let dismiss = CPAlertAction(
      title: localizer.text("carplay.alert.ok"),
      style: .default
    ) { [weak self] _ in
      self?.interfaceController?.dismissTemplate(animated: true) { _, _ in }
    }
    let alert = CPAlertTemplate(
      titleVariants: [localizer.text("carplay.navigation.error")],
      actions: [dismiss]
    )
    interfaceController?.presentTemplate(alert, animated: true) { _, _ in }
  }

  private func makeMapItem(coordinate: Coordinate, name: String) -> MKMapItem {
    let location = CLLocation(
      latitude: coordinate.latitude,
      longitude: coordinate.longitude
    )
    let mapItem: MKMapItem
    if #available(iOS 26.0, *) {
      mapItem = MKMapItem(location: location, address: nil)
    } else {
      mapItem = makeLegacyMapItem(for: location)
    }
    mapItem.name = name
    return mapItem
  }

  @available(iOS, introduced: 18.0, obsoleted: 26.0)
  private func makeLegacyMapItem(for location: CLLocation) -> MKMapItem {
    MKMapItem(placemark: MKPlacemark(coordinate: location.coordinate))
  }
}

extension NextStopCarPlaySceneDelegate: CPPointOfInterestTemplateDelegate {
  func pointOfInterestTemplate(
    _ pointOfInterestTemplate: CPPointOfInterestTemplate,
    didChangeMapRegion region: MKCoordinateRegion
  ) {
    // A ride result is a stable snapshot. Panning never replaces or re-ranks its five parks.
  }
}

extension CarPlayRideSearchError {
  fileprivate var localizationKey: String {
    switch self {
    case .phoneSetupRequired:
      "carplay.search.error.phone_setup"
    case .locationUnavailable:
      "ride.error.location_unavailable"
    case .routeUnavailable:
      "ride.error.route_unavailable"
    case .dataPreparing:
      "ride.search.error.preparing"
    case .serviceUnavailable:
      "ride.search.error.service"
    case .snapshotExpired:
      "ride.search.error.snapshot"
    case .responseInvalid:
      "ride.search.error.response"
    case .drivingDistancesUnavailable:
      "ride.search.error.driving"
    case .foodSearchUnavailable:
      "ride.search.error.food"
    }
  }
}
