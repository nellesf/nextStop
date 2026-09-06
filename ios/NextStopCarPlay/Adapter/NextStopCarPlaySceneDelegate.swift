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
  private var searchTemplateStore = CarPlaySearchTemplateStore()
  private var templateTransitionGate = CarPlayTemplateTransitionGate()
  private var searchTask: Task<Void, Never>?
  private var resultsByID: [UUID: RouteSearchResult] = [:]
  private var searchService: (any CarPlayRideSearchExecuting)?

  private let localizer = CarPlayLocalizer()
  private let presenter = CarPlayPresenter()
  private let draftController = CarPlayRideDraftController()
  private let navigationLauncher: any AppleMapsLaunching = AppleMapsLauncher()

  func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didConnect interfaceController: CPInterfaceController
  ) {
    self.interfaceController = interfaceController
    templateTransitionGate.reset()
    if let appDelegate = UIApplication.shared.delegate as? NextStopAppDelegate {
      searchService = CarPlayRideSearchService(
        candidatePageSearcher: appDelegate.candidatePageSearcher
      )
    }
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
    searchTemplateStore.clear()
    templateTransitionGate.reset()
    searchService = nil
    self.interfaceController = nil
  }

  private func showProfiles(animated: Bool, handlerCompletion: (() -> Void)? = nil) {
    guard let interfaceController,
      let transitionID = templateTransitionGate.begin()
    else {
      handlerCompletion?()
      return
    }
    searchTask?.cancel()
    searchTask = nil
    rideSummaryTemplate = nil
    noResultsTemplate = nil
    searchTemplateStore.clear()
    resultsByID = [:]

    let template: CPListTemplate
    do {
      template = try makeProfilesTemplate()
    } catch {
      template = makeProfileErrorTemplate()
    }
    interfaceController.setRootTemplate(template, animated: animated) { [weak self] _, _ in
      defer { handlerCompletion?() }
      guard let self, self.interfaceController === interfaceController else {
        return
      }
      _ = templateTransitionGate.finish(transitionID)
    }
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
          guard let self, let selectedProfile = profileByID[profile.id] else {
            completion()
            return
          }
          showRideSummary(profile: selectedProfile, handlerCompletion: completion)
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
        guard let self else {
          completion()
          return
        }
        showRideSummary(destination: record.destination, handlerCompletion: completion)
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
      guard let self else {
        completion()
        return
      }
      showProfiles(animated: false, handlerCompletion: completion)
    }
    return CPListTemplate(
      title: localizer.text("carplay.saved_rides.title"),
      sections: [CPListSection(items: [retry])]
    )
  }

  private func showRideSummary(
    profile: UserProfile,
    handlerCompletion: @escaping () -> Void
  ) {
    guard !templateTransitionGate.isActive else {
      handlerCompletion()
      return
    }
    recordRecent(profile.destination)
    draftController.select(profile: profile)
    showRideSummary(handlerCompletion: handlerCompletion)
  }

  private func showRideSummary(
    destination: SavedDestination,
    handlerCompletion: @escaping () -> Void
  ) {
    guard !templateTransitionGate.isActive else {
      handlerCompletion()
      return
    }
    recordRecent(destination)
    draftController.select(destination: destination)
    showRideSummary(handlerCompletion: handlerCompletion)
  }

  private func showRideSummary(handlerCompletion: @escaping () -> Void) {
    guard let draft = draftController.draft,
      let interfaceController,
      let transitionID = templateTransitionGate.begin()
    else {
      handlerCompletion()
      return
    }
    let template = CPListTemplate(
      title: presenter.rideSummary(draft).title,
      sections: makeRideSummarySections(draft)
    )
    rideSummaryTemplate = template
    interfaceController.pushTemplate(template, animated: true) { [weak self] success, _ in
      defer { handlerCompletion() }
      guard let self,
        self.interfaceController === interfaceController,
        templateTransitionGate.finish(transitionID)
      else {
        return
      }
      if !success, rideSummaryTemplate === template {
        rideSummaryTemplate = nil
      }
    }
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
        guard let self else {
          completion()
          return
        }
        showOptions(for: criterion.field, handlerCompletion: completion)
      }
      return item
    }

    let search = CPListItem(text: presentation.searchActionTitle, detailText: nil)
    search.handler = { [weak self] _, completion in
      guard let self else {
        completion()
        return
      }
      startSearch(handlerCompletion: completion)
    }

    return [
      CPListSection(items: [destination]),
      CPListSection(items: criteria),
      CPListSection(items: [search]),
    ]
  }

  private func showOptions(
    for field: CarPlayCriteriaField,
    handlerCompletion: @escaping () -> Void
  ) {
    guard let draft = draftController.draft,
      let interfaceController,
      let transitionID = templateTransitionGate.begin()
    else {
      handlerCompletion()
      return
    }
    let options = presenter.options(for: field, draft: draft)
    let items = options.map { option in
      let item = CPListItem(text: option.title, detailText: nil)
      if option.selected {
        item.setAccessoryImage(UIImage(systemName: "checkmark"))
      }
      item.handler = { [weak self] _, completion in
        guard let self else {
          completion()
          return
        }
        applyAndDismiss(option.selection, handlerCompletion: completion)
      }
      return item
    }
    let title = presenter.rideSummary(draft).criteria
      .first(where: { $0.field == field })?.title
    let template = CPListTemplate(
      title: title,
      sections: [CPListSection(items: items)]
    )
    interfaceController.pushTemplate(template, animated: true) { [weak self] _, _ in
      defer { handlerCompletion() }
      guard let self, self.interfaceController === interfaceController else {
        return
      }
      _ = templateTransitionGate.finish(transitionID)
    }
  }

  private func applyAndDismiss(
    _ selection: CarPlayCriteriaSelection,
    handlerCompletion: @escaping () -> Void
  ) {
    guard let interfaceController,
      let transitionID = templateTransitionGate.begin()
    else {
      handlerCompletion()
      return
    }
    apply(selection)
    interfaceController.popTemplate(animated: true) { [weak self] _, _ in
      defer { handlerCompletion() }
      guard let self, self.interfaceController === interfaceController else {
        return
      }
      _ = templateTransitionGate.finish(transitionID)
    }
  }

  private func apply(_ selection: CarPlayCriteriaSelection) {
    draftController.apply(selection)
    guard let draft = draftController.draft else {
      return
    }
    rideSummaryTemplate?.updateSections(makeRideSummarySections(draft))
    noResultsTemplate?.updateSections(makeNoResultsSections(draft))
  }

  private func startSearch(handlerCompletion: (() -> Void)? = nil) {
    guard let draft = draftController.draft,
      let interfaceController,
      let summary = rideSummaryTemplate,
      !templateTransitionGate.isActive
    else {
      handlerCompletion?()
      return
    }
    let topTemplate = interfaceController.templates.last
    let isSummaryVisible = topTemplate === summary
    let isSearchVisible = searchTemplateStore.current.map { topTemplate === $0 } ?? false
    guard isSummaryVisible || isSearchVisible else {
      handlerCompletion?()
      return
    }
    searchTask?.cancel()
    noResultsTemplate = nil

    let resolution = searchTemplateStore.resolve(in: interfaceController.templates) {
      makeLoadingTemplate()
    }
    let loading = resolution.template

    guard resolution.requiresPush else {
      showLoading(in: loading)
      performSearch(draft: draft, in: loading)
      handlerCompletion?()
      return
    }

    guard let transitionID = templateTransitionGate.begin() else {
      handlerCompletion?()
      return
    }
    interfaceController.pushTemplate(loading, animated: true) { [weak self] success, _ in
      defer { handlerCompletion?() }
      guard let self,
        self.interfaceController === interfaceController,
        templateTransitionGate.finish(transitionID)
      else {
        return
      }
      guard success else {
        if interfaceController.templates.last === loading {
          showPresentationError(in: loading)
        } else {
          searchTemplateStore.clear(ifCurrent: loading)
        }
        if interfaceController.templates.last === summary {
          showPresentationError(in: summary)
        }
        return
      }
      guard interfaceController.templates.last === loading,
        searchTemplateStore.current === loading
      else {
        searchTemplateStore.clear(ifCurrent: loading)
        return
      }
      performSearch(draft: draft, in: loading)
    }
  }

  private func makeLoadingTemplate() -> CPListTemplate {
    CPListTemplate(
      title: localizer.text("ride.results.title"),
      sections: makeLoadingSections()
    )
  }

  private func showLoading(in template: CPListTemplate) {
    template.updateSections(makeLoadingSections())
  }

  private func makeLoadingSections() -> [CPListSection] {
    let loadingItem = CPListItem(
      text: localizer.text("carplay.search.loading.title"),
      detailText: localizer.text("carplay.search.loading.description")
    )
    loadingItem.isEnabled = false
    return [CPListSection(items: [loadingItem])]
  }

  private func performSearch(draft: RideSearchDraft, in loading: CPListTemplate) {
    guard let searchService else {
      showSearchError(.authenticationUnavailable, in: loading)
      return
    }

    searchTask = Task { [weak self] in
      guard let self else {
        return
      }
      do {
        let outcome = try await searchService.search(draft: draft)
        try Task.checkCancellation()
        if outcome.results.isEmpty {
          showNoResults(in: loading, draft: draft, outcome: outcome)
        } else {
          showResults(outcome)
        }
      } catch is CancellationError {
        return
      } catch let error as CarPlayRideSearchError {
        guard !Task.isCancelled else {
          return
        }
        showSearchError(error, in: loading)
      } catch {
        guard !Task.isCancelled else {
          return
        }
        showSearchError(.serviceUnavailable, in: loading)
      }
    }
  }

  private func showNoResults(
    in template: CPListTemplate,
    draft: RideSearchDraft,
    outcome: RideCandidateSearchOutcome
  ) {
    noResultsTemplate = template
    template.updateSections(makeNoResultsSections(draft, attributions: outcome.attributions))
    template.emptyViewTitleVariants = [localizer.text("ride.search.empty.title")]
    template.emptyViewSubtitleVariants = [localizer.text("ride.search.empty.description")]
  }

  private func makeNoResultsSections(
    _ draft: RideSearchDraft,
    attributions: [DataAttribution] = []
  ) -> [CPListSection] {
    let message = CPListItem(
      text: localizer.text("ride.search.empty.title"),
      detailText: localizer.text("ride.search.empty.description")
    )
    message.isEnabled = false

    let criteria = presenter.rideSummary(draft).criteria.map { criterion in
      let item = CPListItem(text: criterion.title, detailText: criterion.value)
      item.accessoryType = .disclosureIndicator
      item.handler = { [weak self] _, completion in
        guard let self else {
          completion()
          return
        }
        showOptions(for: criterion.field, handlerCompletion: completion)
      }
      return item
    }
    let retry = CPListItem(text: localizer.text("carplay.retry"), detailText: nil)
    retry.handler = { [weak self] _, completion in
      guard let self else {
        completion()
        return
      }
      startSearch(handlerCompletion: completion)
    }
    var sections = [
      CPListSection(items: [message]),
      CPListSection(items: criteria),
      CPListSection(items: [retry]),
    ]
    if !attributions.isEmpty {
      let attribution = CPListItem(
        text: attributions.map(\.notice).joined(separator: " · "),
        detailText: localizer.text("carplay.attribution.detail")
      )
      attribution.isEnabled = false
      sections.append(CPListSection(items: [attribution]))
    }
    return sections
  }

  private func showSearchError(
    _ error: CarPlayRideSearchError,
    in template: CPListTemplate
  ) {
    showSearchError(detailKey: error.localizationKey, in: template)
  }

  private func showPresentationError(in template: CPListTemplate) {
    showSearchError(detailKey: "carplay.search.error.presentation", in: template)
  }

  private func showSearchError(detailKey: String, in template: CPListTemplate) {
    let message = CPListItem(
      text: localizer.text("ride.search.error.title"),
      detailText: localizer.text(detailKey)
    )
    message.isEnabled = false
    let retry = CPListItem(text: localizer.text("carplay.retry"), detailText: nil)
    retry.handler = { [weak self] _, completion in
      guard let self else {
        completion()
        return
      }
      startSearch(handlerCompletion: completion)
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
      uniqueKeysWithValues: outcome.results.map { ($0.id, $0) }
    )
    let points = presentation.points.map { point in
      makePointOfInterest(
        point,
        coverageMessage: presentation.coverageMessage,
        attributionMessage: presentation.attributionMessage
      )
    }
    let template = CPPointOfInterestTemplate(
      title: presentation.title,
      pointsOfInterest: points,
      selectedIndex: NSNotFound
    )
    template.pointOfInterestDelegate = self
    template.trailingNavigationBarButtons = [
      CPBarButton(title: localizer.text("ride.search.refresh")) { [weak self, weak template] _ in
        guard let template else {
          return
        }
        self?.refreshSearchFromResults(from: template)
      }
    ]

    guard let interfaceController,
      let summary = rideSummaryTemplate,
      let searchTemplate = searchTemplateStore.current,
      interfaceController.templates.contains(where: { $0 === summary }),
      interfaceController.templates.last === searchTemplate,
      let transitionID = templateTransitionGate.begin()
    else {
      return
    }

    interfaceController.pop(to: summary, animated: false) { [weak self] success, _ in
      guard let self,
        self.interfaceController === interfaceController,
        templateTransitionGate.isActive(transitionID)
      else {
        return
      }
      guard success, interfaceController.templates.last === summary else {
        _ = templateTransitionGate.finish(transitionID)
        if interfaceController.templates.last === searchTemplate {
          showPresentationError(in: searchTemplate)
        } else if interfaceController.templates.last === summary {
          searchTemplateStore.clear(ifCurrent: searchTemplate)
          noResultsTemplate = nil
          showPresentationError(in: summary)
        }
        return
      }
      if let draft = draftController.draft {
        summary.updateSections(makeRideSummarySections(draft))
      }
      interfaceController.pushTemplate(template, animated: true) { [weak self] success, _ in
        guard let self,
          self.interfaceController === interfaceController,
          templateTransitionGate.finish(transitionID)
        else {
          return
        }
        searchTemplateStore.clear(ifCurrent: searchTemplate)
        noResultsTemplate = nil
        let didShowResults = success && interfaceController.templates.last === template
        if !didShowResults, interfaceController.templates.last === summary {
          showPresentationError(in: summary)
        }
      }
    }
  }

  private func refreshSearchFromResults(from resultTemplate: CPPointOfInterestTemplate) {
    guard let interfaceController,
      let summary = rideSummaryTemplate,
      interfaceController.templates.contains(where: { $0 === summary }),
      interfaceController.templates.last === resultTemplate,
      let transitionID = templateTransitionGate.begin()
    else {
      return
    }

    searchTask?.cancel()
    interfaceController.pop(to: summary, animated: false) { [weak self] _, _ in
      guard let self,
        self.interfaceController === interfaceController,
        templateTransitionGate.finish(transitionID)
      else {
        return
      }
      guard interfaceController.templates.last === summary else {
        return
      }
      startSearch()
    }
  }

  private func makePointOfInterest(
    _ presentation: CarPlayResultPresentation,
    coverageMessage: String?,
    attributionMessage: String?
  ) -> CPPointOfInterest {
    let mapItem = makeMapItem(
      coordinate: presentation.coordinate,
      name: presentation.title
    )
    let detailSummary = [presentation.detailSummary, coverageMessage, attributionMessage]
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

@MainActor
struct CarPlaySearchTemplateStore {
  struct Resolution {
    let template: CPListTemplate
    let requiresPush: Bool
  }

  private(set) var current: CPListTemplate?

  mutating func resolve(
    in hierarchy: [CPTemplate],
    make: () -> CPListTemplate
  ) -> Resolution {
    if let current, hierarchy.last === current {
      return Resolution(template: current, requiresPush: false)
    }

    let template = make()
    current = template
    return Resolution(template: template, requiresPush: true)
  }

  mutating func clear(ifCurrent template: CPListTemplate? = nil) {
    if let template, let current, current !== template {
      return
    }
    current = nil
  }
}

struct CarPlayTemplateTransitionGate {
  private var activeID: UUID?

  var isActive: Bool {
    activeID != nil
  }

  mutating func begin() -> UUID? {
    guard activeID == nil else {
      return nil
    }
    let id = UUID()
    activeID = id
    return id
  }

  func isActive(_ id: UUID) -> Bool {
    activeID == id
  }

  mutating func finish(_ id: UUID) -> Bool {
    guard activeID == id else {
      return false
    }
    activeID = nil
    return true
  }

  mutating func reset() {
    activeID = nil
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
    case .authenticationUnavailable:
      "ride.search.error.authentication"
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
