import CarPlay
import CoreLocation
import Foundation
import MapKit
import NextStopCore
import SwiftData
import UIKit

@MainActor
final class NextStopCarPlaySceneDelegate: NSObject, CPTemplateApplicationSceneDelegate,
  NextStopSceneDependencyReceiving
{
  private var interfaceController: CPInterfaceController?
  private var dataContainer: ModelContainer?
  private var rideSummaryTemplate: CPListTemplate?
  private var criteriaTemplate: CPListTemplate?
  private var noResultsTemplate: CPListTemplate?
  private var noResultsAttributions: [DataAttribution] = []
  private var searchTemplateStore = CarPlaySearchTemplateStore()
  private var templateTransitionGate = CarPlayTemplateTransitionGate()
  private var searchTask: Task<Void, Never>?
  private var placeTask: Task<Void, Never>?
  private var placeRequestID: UUID?
  private var mapsLauncher: (any CarPlayAppleMapsLaunching)?
  private let placeSelectionContext = CarPlayPlaceSelectionContext()
  private var placeResolver: any CarPlayResultPlaceResolving = CarPlayResultPlaceResolver()
  private var resultsByID: [UUID: RouteSearchResult] = [:]
  private var dependencies: NextStopSceneDependencies?
  private var searchService: (any CarPlayRideSearchExecuting)?

  private let localizer = CarPlayLocalizer()
  private let presenter = CarPlayPresenter()
  private let draftController = CarPlayRideDraftController()

  func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didConnect interfaceController: CPInterfaceController
  ) {
    self.interfaceController = interfaceController
    mapsLauncher = CarPlayAppleMapsLauncher(scene: templateApplicationScene)
    templateTransitionGate.reset()
    if searchService == nil, let dependencies {
      searchService = makeSearchService(using: dependencies)
      configurePlaceResolver(using: dependencies)
    }
    showProfiles(animated: false)
  }

  func receiveSceneDependencies(_ dependencies: NextStopSceneDependencies) {
    let dependenciesChanged = self.dependencies !== dependencies
    self.dependencies = dependencies
    if dependenciesChanged || searchService == nil {
      searchService = makeSearchService(using: dependencies)
      configurePlaceResolver(using: dependencies)
    }
  }

  func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didDisconnectInterfaceController interfaceController: CPInterfaceController
  ) {
    guard self.interfaceController === interfaceController else {
      return
    }
    searchTask?.cancel()
    searchTask = nil
    cancelPlaceSelection()
    mapsLauncher = nil
    placeSelectionContext.clear()
    placeResolver = CarPlayResultPlaceResolver()
    resultsByID = [:]
    rideSummaryTemplate = nil
    criteriaTemplate = nil
    noResultsTemplate = nil
    noResultsAttributions = []
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
    cancelPlaceSelection()
    placeSelectionContext.clear()
    placeResolver = CarPlayResultPlaceResolver()
    rideSummaryTemplate = nil
    criteriaTemplate = nil
    noResultsTemplate = nil
    noResultsAttributions = []
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
    cancelPlaceSelection()
    placeSelectionContext.clear()
    placeResolver = CarPlayResultPlaceResolver()
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
    cancelPlaceSelection()
    placeSelectionContext.clear()
    placeResolver = CarPlayResultPlaceResolver()
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
      title: presenter.rideSummary(draft).destination,
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
    let search = CPListItem(
      text: presentation.searchActionTitle,
      detailText: presentation.searchActionDetail,
      image: UIImage(systemName: "magnifyingglass")
    )
    search.handler = { [weak self] _, completion in
      guard let self else {
        completion()
        return
      }
      startSearch(handlerCompletion: completion)
    }
    let edit = CPListItem(
      text: presentation.editActionTitle,
      detailText: presentation.editActionDetail,
      image: UIImage(systemName: "slider.horizontal.3")
    )
    edit.accessoryType = .disclosureIndicator
    edit.handler = { [weak self] _, completion in
      guard let self else {
        completion()
        return
      }
      showCriteria(handlerCompletion: completion)
    }
    let summary = CPListItem(
      text: presentation.criteriaSummaryTitle,
      detailText: presentation.criteriaSummaryDetail
    )
    summary.isEnabled = false
    return [
      CPListSection(items: [search, edit]),
      CPListSection(items: [summary]),
    ]
  }

  private func showCriteria(handlerCompletion: @escaping () -> Void) {
    guard let draft = draftController.draft,
      let interfaceController,
      interfaceController.templates.last === rideSummaryTemplate,
      let transitionID = templateTransitionGate.begin()
    else {
      handlerCompletion()
      return
    }
    let template = CPListTemplate(
      title: localizer.text("carplay.filters.title"),
      sections: makeCriteriaSections(draft)
    )
    template.trailingNavigationBarButtons = [
      CPBarButton(title: presenter.rideSummary(draft).searchActionTitle) { [weak self] _ in
        self?.startSearch()
      }
    ]
    criteriaTemplate = template
    interfaceController.pushTemplate(template, animated: true) { [weak self] success, _ in
      defer { handlerCompletion() }
      guard let self,
        self.interfaceController === interfaceController,
        templateTransitionGate.finish(transitionID)
      else {
        return
      }
      if !success, criteriaTemplate === template {
        criteriaTemplate = nil
      }
    }
  }

  private func makeCriteriaSections(_ draft: RideSearchDraft) -> [CPListSection] {
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

    return [CPListSection(items: criteria)]
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
    criteriaTemplate?.updateSections(makeCriteriaSections(draft))
    noResultsTemplate?.updateSections(
      makeNoResultsSections(draft, attributions: noResultsAttributions)
    )
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
    if let criteriaTemplate, topTemplate === criteriaTemplate {
      guard interfaceController.templates.contains(where: { $0 === summary }),
        let transitionID = templateTransitionGate.begin()
      else {
        handlerCompletion?()
        return
      }
      interfaceController.pop(to: summary, animated: false) { [weak self] success, _ in
        guard let self,
          self.interfaceController === interfaceController,
          templateTransitionGate.finish(transitionID),
          success,
          interfaceController.templates.last === summary
        else {
          handlerCompletion?()
          return
        }
        self.criteriaTemplate = nil
        startSearch(handlerCompletion: handlerCompletion)
      }
      return
    }
    let isSummaryVisible = topTemplate === summary
    let isSearchVisible = searchTemplateStore.current.map { topTemplate === $0 } ?? false
    guard isSummaryVisible || isSearchVisible else {
      handlerCompletion?()
      return
    }
    searchTask?.cancel()
    cancelPlaceSelection()
    placeSelectionContext.clear()
    noResultsTemplate = nil
    noResultsAttributions = []

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
      title: localizer.text("ride.results.screen.title"),
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
      showSearchError(.configurationUnavailable, in: loading)
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

  private func configurePlaceResolver(using dependencies: NextStopSceneDependencies) {
    placeResolver = CarPlayResultPlaceResolver(
      placeResolver: MapKitApplePlaceResolver(diagnostics: dependencies.diagnostics)
    )
  }

  private func makeSearchService(
    using dependencies: NextStopSceneDependencies
  ) -> any CarPlayRideSearchExecuting {
    return CarPlayRideSearchService(
      candidatePageSearcher: dependencies.candidatePageSearcher,
      diagnostics: dependencies.diagnostics
    )
  }

  private func showNoResults(
    in template: CPListTemplate,
    draft: RideSearchDraft,
    outcome: RideCandidateSearchOutcome
  ) {
    noResultsTemplate = template
    noResultsAttributions = outcome.attributions
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
      name: presentation.detailTitle
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
      title: presentation.operatorsActionTitle,
      textStyle: .confirm
    ) { [weak self] button in
      self?.showOperators(from: button)
    }
    if let restaurantActionTitle = presentation.restaurantActionTitle {
      point.secondaryButton = CPTextButton(
        title: restaurantActionTitle,
        textStyle: .normal
      ) { [weak self] button in
        guard let self,
          let template = interfaceController?.templates.last as? CPPointOfInterestTemplate,
          button.title == restaurantActionTitle,
          let resultID = placeSelectionContext.selectAction(
            button, in: template, visible: interfaceController?.templates.last
          )
        else {
          return
        }
        button.title = localizer.text("carplay.place.opening")
        openPlace(for: resultID, from: template) { [weak button] in
          button?.title = restaurantActionTitle
        }
      }
    }
    return point
  }

  private func showOperators(from button: CPTextButton) {
    guard let interfaceController,
      let resultsTemplate = interfaceController.templates.last as? CPPointOfInterestTemplate,
      !templateTransitionGate.isActive,
      let resultID = placeSelectionContext.selectAction(
        button, in: resultsTemplate, visible: interfaceController.templates.last
      ),
      let result = resultsByID[resultID],
      let transitionID = templateTransitionGate.begin()
    else {
      return
    }
    cancelPlaceSelection()
    let template = CPListTemplate(
      title: localizer.text("carplay.operators.title"),
      sections: []
    )
    template.emptyViewTitleVariants = [localizer.text("carplay.operators.empty")]
    updateOperators(in: template, result: result, offset: 0)
    interfaceController.pushTemplate(template, animated: true) { [weak self] success, _ in
      guard let self,
        self.interfaceController === interfaceController,
        templateTransitionGate.finish(transitionID)
      else {
        return
      }
      if !success {
        showPlaceFailure(message: localizer.text("carplay.search.error.presentation"))
      }
    }
  }

  private func updateOperators(
    in template: CPListTemplate,
    result: RouteSearchResult,
    offset: Int
  ) {
    let operators = presenter.operators(for: result)
    let pageSize = max(1, CPListTemplate.maximumItemCount)
    let page = operators.dropFirst(offset).prefix(pageSize)
    let items = page.map { chargingOperator in
      let item = CPListItem(
        text: chargingOperator.name,
        detailText: chargingOperator.detail,
        image: UIImage(systemName: "ev.charger")
      )
      item.accessoryType = .disclosureIndicator
      item.handler = { [weak self, weak template] _, completion in
        guard let self, let template else {
          completion()
          return
        }
        openPlace(
          for: result.id,
          operatorName: chargingOperator.name,
          from: template,
          handlerCompletion: completion
        )
      }
      return item
    }
    let context =
      result.matchingFoodPOI.map {
        localizer.format("carplay.operators.context.format", $0.name)
      } ?? result.candidate.park.name
    template.updateSections([
      CPListSection(items: items, header: context, sectionIndexTitle: nil)
    ])

    var pagingButtons: [CPBarButton] = []
    if offset > 0 {
      pagingButtons.append(
        CPBarButton(title: localizer.text("carplay.operators.previous_page")) {
          [weak self, weak template] _ in
          guard let self, let template,
            interfaceController?.templates.last === template
          else {
            return
          }
          cancelPlaceSelection()
          updateOperators(in: template, result: result, offset: max(0, offset - pageSize))
        }
      )
    }
    let nextOffset = offset + items.count
    if nextOffset < operators.count {
      pagingButtons.append(
        CPBarButton(title: localizer.text("carplay.operators.next_page")) {
          [weak self, weak template] _ in
          guard let self, let template,
            interfaceController?.templates.last === template
          else {
            return
          }
          cancelPlaceSelection()
          updateOperators(in: template, result: result, offset: nextOffset)
        }
      )
    }
    template.trailingNavigationBarButtons = pagingButtons
  }

  private func openPlace(
    for resultID: UUID,
    operatorName: String? = nil,
    from template: CPTemplate,
    handlerCompletion: (() -> Void)? = nil
  ) {
    guard let interfaceController, let mapsLauncher,
      placeSelectionContext.isCurrent(
        resultID: resultID, source: template, visible: interfaceController.templates.last
      ),
      !templateTransitionGate.isActive,
      let result = resultsByID[resultID]
    else {
      handlerCompletion?()
      return
    }
    cancelPlaceSelection()
    let requestID = UUID()
    placeRequestID = requestID
    let resolver = placeResolver
    let placeName = operatorName ?? result.matchingFoodPOI?.name ?? result.candidate.park.name
    placeTask = Task { [weak self, weak template, weak interfaceController] in
      defer {
        handlerCompletion?()
        if let self, placeRequestID == requestID {
          placeRequestID = nil
          placeTask = nil
        }
      }
      do {
        try Task.checkCancellation()
        let mapItem: MKMapItem
        if let operatorName {
          mapItem = try await resolver.resolveOperator(named: operatorName, in: result)
        } else {
          mapItem = try await resolver.resolveRestaurant(in: result)
        }
        try Task.checkCancellation()
        guard let self, let template, let interfaceController,
          self.interfaceController === interfaceController,
          self.mapsLauncher === mapsLauncher,
          placeRequestID == requestID,
          placeSelectionContext.isCurrent(
            resultID: resultID, source: template, visible: interfaceController.templates.last
          )
        else {
          return
        }
        let didOpen = await mapsLauncher.openPlace(mapItem)
        guard !Task.isCancelled,
          self.interfaceController === interfaceController,
          self.mapsLauncher === mapsLauncher,
          placeRequestID == requestID,
          placeSelectionContext.isCurrent(
            resultID: resultID, source: template, visible: interfaceController.templates.last
          )
        else {
          return
        }
        if !didOpen {
          showNavigationFailure()
        }
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled,
          let self, let template, let interfaceController,
          self.interfaceController === interfaceController,
          self.mapsLauncher === mapsLauncher,
          placeRequestID == requestID,
          placeSelectionContext.isCurrent(
            resultID: resultID, source: template, visible: interfaceController.templates.last
          )
        else {
          return
        }
        showPlaceFailure(
          message: localizer.format("ride.result.apple_place.no_match.format", placeName)
        )
      }
    }
  }

  private func cancelPlaceSelection() {
    placeTask?.cancel()
    placeTask = nil
    placeRequestID = nil
  }

  private func showNavigationFailure() {
    showPlaceFailure(message: localizer.text("carplay.navigation.error"))
  }

  private func showPlaceFailure(message: String) {
    let dismiss = CPAlertAction(
      title: localizer.text("carplay.alert.ok"),
      style: .default
    ) { [weak self] _ in
      self?.interfaceController?.dismissTemplate(animated: true) { _, _ in }
    }
    let alert = CPAlertTemplate(
      titleVariants: [message],
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
final class CarPlayPlaceSelectionContext {
  private weak var resultsTemplate: CPPointOfInterestTemplate?
  private weak var selectedPoint: CPPointOfInterest?
  private var lastSelectionEvent: ContinuousClock.Instant?

  func selectAction(
    _ button: CPTextButton,
    in source: CPPointOfInterestTemplate,
    visible: CPTemplate?,
    observedAt: ContinuousClock.Instant = .now
  ) -> UUID? {
    guard isLatest(observedAt), source === visible,
      let point = source.pointsOfInterest.first(where: {
        $0.primaryButton === button || $0.secondaryButton === button
      }),
      let resultID = point.userInfo as? UUID
    else {
      return nil
    }
    // The concrete button establishes the action's source even when selectedIndex
    // still contains the initial NSNotFound. Never accept an old template's button.
    _ = select(point, in: source, visible: visible, observedAt: observedAt)
    return resultID
  }

  /// Returns true only when a valid selection changes and pending work must stop.
  func select(
    _ point: CPPointOfInterest,
    in source: CPPointOfInterestTemplate,
    visible: CPTemplate?,
    observedAt: ContinuousClock.Instant = .now
  ) -> Bool {
    guard isLatest(observedAt), source === visible,
      source.pointsOfInterest.contains(where: { $0 === point }),
      point.userInfo is UUID
    else {
      return false
    }
    let changed = resultsTemplate !== source || selectedPoint !== point
    resultsTemplate = source
    selectedPoint = point
    lastSelectionEvent = observedAt
    return changed
  }

  func isCurrent(resultID: UUID, source: CPTemplate, visible: CPTemplate?) -> Bool {
    guard source === visible else {
      return false
    }
    guard let results = source as? CPPointOfInterestTemplate else {
      return true
    }
    guard results === resultsTemplate,
      let selectedPoint,
      results.pointsOfInterest.contains(where: { $0 === selectedPoint })
    else {
      return false
    }
    return (selectedPoint.userInfo as? UUID) == resultID
  }

  func clear() {
    resultsTemplate = nil
    selectedPoint = nil
    lastSelectionEvent = nil
  }

  private func isLatest(_ observedAt: ContinuousClock.Instant) -> Bool {
    lastSelectionEvent.map { observedAt >= $0 } ?? true
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
  nonisolated func pointOfInterestTemplate(
    _ pointOfInterestTemplate: CPPointOfInterestTemplate,
    didSelectPointOfInterest pointOfInterest: CPPointOfInterest
  ) {
    // Transfer identities only; inspect CarPlay objects and update state on the main actor.
    let templateID = ObjectIdentifier(pointOfInterestTemplate)
    let pointID = ObjectIdentifier(pointOfInterest)
    let observedAt = ContinuousClock.now
    Task { @MainActor [weak self] in
      guard let self,
        let template = interfaceController?.templates.last as? CPPointOfInterestTemplate,
        ObjectIdentifier(template) == templateID,
        let point = template.pointsOfInterest.first(where: { ObjectIdentifier($0) == pointID })
      else {
        return
      }
      if placeSelectionContext.select(
        point, in: template, visible: interfaceController?.templates.last,
        observedAt: observedAt
      ) {
        cancelPlaceSelection()
      }
    }
  }

  nonisolated func pointOfInterestTemplate(
    _ pointOfInterestTemplate: CPPointOfInterestTemplate,
    didChangeMapRegion region: MKCoordinateRegion
  ) {
    // CarPlay may deliver this callback off the main actor, so it must remain nonisolated.
    // A ride result is a stable snapshot. Panning never replaces or re-ranks its five parks.
  }
}

extension CarPlayRideSearchError {
  fileprivate var localizationKey: String {
    switch self {
    case .configurationUnavailable:
      "carplay.search.error.configuration"
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
