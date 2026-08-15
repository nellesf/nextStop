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

  func removeRecent(_ destination: SavedDestination) throws {
    guard let record = try find(destination) else {
      return
    }
    record.lastUsedAt = nil
    deleteIfUnused(record)
    try modelContext.save()
  }

  func clearRecents() throws {
    let descriptor = FetchDescriptor<StoredDestinationRecord>(
      predicate: #Predicate { record in record.lastUsedAt != nil }
    )
    for record in try modelContext.fetch(descriptor) {
      record.lastUsedAt = nil
      deleteIfUnused(record)
    }
    try modelContext.save()
  }

  func clearFavorites() throws {
    let descriptor = FetchDescriptor<StoredDestinationRecord>(
      predicate: #Predicate { record in record.isFavorite }
    )
    for record in try modelContext.fetch(descriptor) {
      record.isFavorite = false
      record.favoriteAddedAt = nil
      deleteIfUnused(record)
    }
    try modelContext.save()
  }

  private func upsert(_ destination: SavedDestination) throws -> StoredDestinationRecord {
    if let existing = try find(destination) {
      existing.updateDestination(destination)
      return existing
    }
    let record = StoredDestinationRecord(destination: destination)
    modelContext.insert(record)
    return record
  }

  private func find(_ destination: SavedDestination) throws -> StoredDestinationRecord? {
    let lookupKey = StoredDestinationRecord.makeLookupKey(destination)
    let descriptor = FetchDescriptor<StoredDestinationRecord>(
      predicate: #Predicate { record in record.lookupKey == lookupKey }
    )
    return try modelContext.fetch(descriptor).first
  }

  private func deleteIfUnused(_ record: StoredDestinationRecord) {
    if !record.isFavorite, record.lastUsedAt == nil {
      modelContext.delete(record)
    }
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
