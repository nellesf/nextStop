import Foundation
import NextStopCore
import SwiftData

@MainActor
struct SwiftDataDestinationRepository: DestinationRepository {
  private let modelContext: ModelContext

  init(modelContext: ModelContext) {
    self.modelContext = modelContext
  }

  func fetchFavorites() throws -> [LocalDestinationRecord] {
    let descriptor = FetchDescriptor<StoredDestinationRecord>(
      predicate: #Predicate { record in record.isFavorite },
      sortBy: [SortDescriptor(\StoredDestinationRecord.favoriteAddedAt, order: .reverse)]
    )
    return try modelContext.fetch(descriptor).map(domainRecord)
  }

  func fetchRecents() throws -> [LocalDestinationRecord] {
    var descriptor = FetchDescriptor<StoredDestinationRecord>(
      predicate: #Predicate { record in record.lastUsedAt != nil },
      sortBy: [SortDescriptor(\StoredDestinationRecord.lastUsedAt, order: .reverse)]
    )
    descriptor.fetchLimit = SearchConfiguration.recentDestinationLimit
    return try modelContext.fetch(descriptor).map(domainRecord)
  }

  func recordRecent(_ destination: SavedDestination, at date: Date) throws {
    let record = try upsert(destination)
    record.lastUsedAt = date
    try pruneRecents()
    try modelContext.save()
  }

  func setFavorite(_ destination: SavedDestination, isFavorite: Bool, at date: Date) throws {
    let record = try upsert(destination)
    record.isFavorite = isFavorite
    record.favoriteAddedAt = isFavorite ? date : nil
    if !isFavorite, record.lastUsedAt == nil {
      modelContext.delete(record)
    }
    try modelContext.save()
  }

  private func upsert(_ destination: SavedDestination) throws -> StoredDestinationRecord {
    let lookupKey = StoredDestinationRecord.makeLookupKey(destination)
    let descriptor = FetchDescriptor<StoredDestinationRecord>(
      predicate: #Predicate { record in record.lookupKey == lookupKey }
    )
    if let existing = try modelContext.fetch(descriptor).first {
      existing.updateDestination(destination)
      return existing
    }
    let record = StoredDestinationRecord(destination: destination)
    modelContext.insert(record)
    return record
  }

  private func pruneRecents() throws {
    let descriptor = FetchDescriptor<StoredDestinationRecord>(
      predicate: #Predicate { record in record.lastUsedAt != nil },
      sortBy: [SortDescriptor(\StoredDestinationRecord.lastUsedAt, order: .reverse)]
    )
    let records = try modelContext.fetch(descriptor)
    for record in records.dropFirst(SearchConfiguration.recentDestinationLimit) {
      if record.isFavorite {
        record.lastUsedAt = nil
      } else {
        modelContext.delete(record)
      }
    }
  }

  private func domainRecord(_ stored: StoredDestinationRecord) throws -> LocalDestinationRecord {
    LocalDestinationRecord(
      id: stored.id,
      destination: try stored.domainDestination(),
      isFavorite: stored.isFavorite,
      favoriteAddedAt: stored.favoriteAddedAt,
      lastUsedAt: stored.lastUsedAt
    )
  }
}
