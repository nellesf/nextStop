import Foundation
import NextStopCore
import SwiftData

@MainActor
struct SwiftDataProfileRepository: ProfileRepository {
  private let modelContext: ModelContext

  init(modelContext: ModelContext) {
    self.modelContext = modelContext
  }

  func fetchProfiles() throws -> [UserProfile] {
    let descriptor = FetchDescriptor<StoredProfile>(
      sortBy: [
        SortDescriptor(\StoredProfile.updatedAt, order: .reverse)
      ]
    )
    return try modelContext.fetch(descriptor).map { try $0.domainProfile() }
  }

  func save(_ profile: UserProfile) throws {
    let profileID = profile.id
    let descriptor = FetchDescriptor<StoredProfile>(
      predicate: #Predicate { storedProfile in
        storedProfile.id == profileID
      }
    )

    if let existingProfile = try modelContext.fetch(descriptor).first {
      existingProfile.update(from: profile)
    } else {
      modelContext.insert(StoredProfile(profile: profile))
    }
    try modelContext.save()
  }

  func delete(id: UUID) throws {
    let profileID = id
    let descriptor = FetchDescriptor<StoredProfile>(
      predicate: #Predicate { storedProfile in
        storedProfile.id == profileID
      }
    )
    if let profile = try modelContext.fetch(descriptor).first {
      modelContext.delete(profile)
      try modelContext.save()
    }
  }
}
