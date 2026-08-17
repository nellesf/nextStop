import NextStopCore
import SwiftUI

private struct ProfileEditorAlert: Identifiable {
  let id = UUID()
  let localizationKey: String
}

struct ProfileEditorView: View {
  let profile: UserProfile?
  let onSave: (UserProfile) throws -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var form: ProfileFormState
  @State private var isDestinationSearchPresented = false
  @State private var alert: ProfileEditorAlert?

  init(profile: UserProfile?, onSave: @escaping (UserProfile) throws -> Void) {
    self.profile = profile
    self.onSave = onSave
    _form = State(initialValue: ProfileFormState(profile: profile))
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("profile.section.general") {
          TextField("profile.name", text: $form.name)
            .textInputAutocapitalization(.words)

          Button {
            isDestinationSearchPresented = true
          } label: {
            LabeledContent("profile.destination") {
              Text(form.destination?.displayName ?? String(localized: "destination.empty"))
                .multilineTextAlignment(.trailing)
                .foregroundStyle(form.destination == nil ? .secondary : .primary)
            }
          }
          .foregroundStyle(.primary)
        }

        Section("profile.section.charging") {
          Picker("profile.distance_range", selection: $form.distanceRange) {
            ForEach(DistanceRangeOption.allCases, id: \.self) { option in
              Text(LocalizedStringKey(option.localizationKey)).tag(option)
            }
          }

          Picker("profile.minimum_charging_points", selection: $form.minimumChargingPoints) {
            ForEach(MinimumChargingPointsOption.allCases, id: \.self) { option in
              Text(LocalizedFormat.minimumCount(option.rawValue)).tag(option)
            }
          }

          Picker("profile.minimum_power", selection: $form.minimumPower) {
            ForEach(MinimumPowerOption.allCases, id: \.self) { option in
              Text(LocalizedFormat.kilowatts(option.rawValue)).tag(option)
            }
          }

          Picker("profile.fast_food", selection: $form.foodChain) {
            Text("food.any").tag(nil as FoodChain?)
            ForEach(FoodChain.allCases, id: \.self) { option in
              Text(LocalizedStringKey(option.localizationKey)).tag(Optional(option))
            }
          }
        }
      }
      .navigationTitle(
        Text(
          LocalizedStringKey(
            profile == nil ? "profile.new.title" : "profile.edit.title"
          )
        )
      )
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("action.cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("action.save") { save() }
        }
      }
      .sheet(isPresented: $isDestinationSearchPresented) {
        DestinationSearchView { result in
          form.destination = result.destination
        }
      }
      .alert(item: $alert) { alert in
        Alert(
          title: Text(LocalizedStringKey(alert.localizationKey)),
          dismissButton: .default(Text("action.done"))
        )
      }
    }
  }

  private func save() {
    do {
      let savedProfile = try form.makeProfile(now: Date())
      try onSave(savedProfile)
      dismiss()
    } catch let validationError as ProfileFormValidationError {
      alert = ProfileEditorAlert(localizationKey: validationError.localizationKey)
    } catch {
      alert = ProfileEditorAlert(localizationKey: "error.generic")
    }
  }
}
