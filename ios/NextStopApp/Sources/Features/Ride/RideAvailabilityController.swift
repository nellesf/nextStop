import Combine
import Foundation
import NextStopCore

struct RideAvailabilityRefreshIdentity: Hashable {
  let context: String?
  let results: [RouteSearchResult]
  let isActive: Bool

  init(outcome: RideCandidateSearchOutcome, isActive: Bool) {
    context = outcome.availabilityContext
    results = outcome.results
    self.isActive = isActive
  }
}

/// An informational overlay. Search results, route evidence and Apple place caches stay immutable.
@MainActor
final class RideAvailabilityController: ObservableObject {
  typealias Sleep = @MainActor (TimeInterval) async throws -> Void
  @Published private(set) var values: [UUID: ParkAvailability] = [:]
  private let fetcher: (any ChargingAvailabilityFetching)?
  private let now: @MainActor () -> Date
  private let sleep: Sleep
  private var generation = UUID()
  private var expires: [UUID: Date] = [:]
  private var expirationTask: Task<Void, Never>?
  private var fetchTask: Task<ChargingAvailabilityBatch, Error>?

  init(
    fetcher: (any ChargingAvailabilityFetching)?,
    now: @escaping @MainActor () -> Date = Date.init,
    sleep: @escaping Sleep = { try await Task.sleep(for: .seconds($0)) }
  ) {
    self.fetcher = fetcher
    self.now = now
    self.sleep = sleep
  }

  func cancel() {
    generation = UUID()
    fetchTask?.cancel()
    fetchTask = nil
    expirationTask?.cancel()
    expirationTask = nil
    values = [:]
    expires = [:]
  }

  func availability(for result: RouteSearchResult, onDemand: Bool) -> ParkAvailability {
    guard onDemand else { return result.availability }
    var available = 0
    var unavailable = 0
    var unknown = 0
    var observations: [Date] = []
    for candidate in result.candidates {
      let count = candidate.park.operatorChargingPoints
        .filter { result.eligibleOperatorNames?.contains($0.name) ?? true }
        .reduce(0) { $0 + $1.chargingPointCount }
      guard let value = values[candidate.id], value.totalCount == count,
        let expiry = expires[candidate.id], expiry > now()
      else {
        unknown += count
        continue
      }
      available += value.knownAvailableCount
      unavailable += value.knownUnavailableCount
      unknown += value.unknownCount
      if let observed = value.lastLiveObservationAt { observations.append(observed) }
    }
    return
      (try? ParkAvailability(
        knownAvailableCount: available, knownUnavailableCount: unavailable,
        unknownCount: unknown, totalCount: result.chargingPointCount,
        lastLiveObservationAt: observations.max()
      ))
      ?? (try! ParkAvailability(
        knownAvailableCount: 0, knownUnavailableCount: 0,
        unknownCount: result.chargingPointCount, totalCount: result.chargingPointCount
      ))
  }

  func refresh(
    _ outcome: RideCandidateSearchOutcome,
    isActive: Bool = true,
    onChange: @escaping @MainActor () -> Void = {}
  ) async {
    guard !Task.isCancelled else { return }
    cancel()
    let currentGeneration = generation
    guard isActive, let context = outcome.availabilityContext, let fetcher else { return }
    let selections = ChargingAvailabilitySelection.from(outcome.results)
    guard !selections.isEmpty else { return }
    for offset in stride(from: 0, to: selections.count, by: 50) {
      let batch = Array(selections[offset..<min(offset + 50, selections.count)])
      for attempt in 0...3 {
        do {
          try Task.checkCancellation()
          guard generation == currentGeneration else { return }
          let task = Task {
            try await fetcher.fetchAvailability(context: context, candidates: batch)
          }
          fetchTask = task
          let response = try await withTaskCancellationHandler {
            try await task.value
          } onCancel: {
            task.cancel()
          }
          try Task.checkCancellation()
          guard generation == currentGeneration else { return }
          fetchTask = nil
          guard Set(response.candidates.keys) == Set(batch.map(\.id)),
            batch.allSatisfy({ response.candidates[$0.id]?.totalCount == $0.expectedChargingPoints }
            )
          else { return }
          for (id, value) in response.candidates {
            let expiry = min(
              response.contextExpiresAt,
              value.lastLiveObservationAt?.addingTimeInterval(300) ?? response.generatedAt
            )
            if expiry > now() {
              values[id] = value
              expires[id] = expiry
            } else {
              values[id] = nil
              expires[id] = nil
            }
          }
          onChange()
          scheduleExpiration(generation: currentGeneration, onChange: onChange)
          guard response.refreshPending, attempt < 3 else { break }
          // Allow one national-feed refresh to finish, without polling indefinitely.
          try await sleep(max(10, min(response.retryAfterSeconds ?? 10, 30)))
        } catch {
          // Availability failure never replaces a successful search with an error or no-results.
          return
        }
      }
    }
  }

  private func scheduleExpiration(
    generation expectedGeneration: UUID, onChange: @escaping @MainActor () -> Void
  ) {
    expirationTask?.cancel()
    guard let next = expires.values.min() else { return }
    expirationTask = Task { [weak self] in
      guard let self else { return }
      do {
        try await sleep(max(0, next.timeIntervalSince(now())))
        try Task.checkCancellation()
        guard generation == expectedGeneration else { return }
        let expired = expires.filter { $0.value <= now() }.map(\.key)
        for id in expired {
          expires[id] = nil
          values[id] = nil
        }
        onChange()
        scheduleExpiration(generation: expectedGeneration, onChange: onChange)
      } catch {}
    }
  }
}
