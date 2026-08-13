import Foundation
import NextStopCore

@MainActor
protocol ProfileRepository {
  func fetchProfiles() throws -> [UserProfile]
  func save(_ profile: UserProfile) throws
  func delete(id: UUID) throws
}

@MainActor
final class InMemoryProfileRepository: ProfileRepository {
  private var profilesByID: [UUID: UserProfile]

  init(profiles: [UserProfile] = []) {
    profilesByID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
  }

  func fetchProfiles() -> [UserProfile] {
    profilesByID.values.sorted { lhs, rhs in
      if lhs.updatedAt == rhs.updatedAt {
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
      }
      return lhs.updatedAt > rhs.updatedAt
    }
  }

  func save(_ profile: UserProfile) {
    profilesByID[profile.id] = profile
  }

  func delete(id: UUID) {
    profilesByID[id] = nil
  }
}
