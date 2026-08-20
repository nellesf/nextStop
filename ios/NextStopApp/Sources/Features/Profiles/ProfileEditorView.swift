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
      ScrollView {
        VStack(spacing: 18) {
          generalCard
          chargingCard
          foodCard
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 24)
      }
      .scrollDismissesKeyboard(.interactively)
      .background(Color(.systemGroupedBackground))
      .navigationTitle(
        Text(
          LocalizedStringKey(
            profile == nil ? "profile.new.title" : "profile.edit.title"
          )
        )
      )
      .navigationBarTitleDisplayMode(.large)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("action.cancel") { dismiss() }
        }
      }
      .safeAreaInset(edge: .bottom) {
        saveButton
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

  private var generalCard: some View {
    EditorCard {
      Text("profile.section.general")
        .font(.title3.weight(.bold))

      VStack(alignment: .leading, spacing: 6) {
        Text("profile.name")
          .font(.subheadline.weight(.medium))

        TextField("profile.name", text: $form.name)
          .textInputAutocapitalization(.words)
          .padding(.horizontal, 14)
          .frame(minHeight: 48)
          .background(Color(.tertiarySystemGroupedBackground))
          .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      }

      Divider()

      Button {
        isDestinationSearchPresented = true
      } label: {
        HStack(alignment: .center, spacing: 12) {
          Image(systemName: "mappin.and.ellipse")
            .foregroundStyle(.tint)
            .frame(width: 22)
            .accessibilityHidden(true)

          VStack(alignment: .leading, spacing: 3) {
            Text("profile.destination")
              .font(.caption)
              .foregroundStyle(.secondary)

            Text(form.destination?.displayName ?? String(localized: "destination.empty"))
              .font(.body.weight(.medium))
              .foregroundStyle(form.destination == nil ? .secondary : .primary)

            if let address = form.destination?.displayAddress {
              Text(address)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)

          Image(systemName: "chevron.right")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
    }
  }

  private var chargingCard: some View {
    EditorCard {
      Text("profile.section.charging")
        .font(.title3.weight(.bold))

      VStack(alignment: .leading, spacing: 3) {
        Picker("profile.minimum_power", selection: $form.minimumPower) {
          ForEach(MinimumPowerOption.allCases, id: \.self) { option in
            Text(LocalizedFormat.kilowatts(option.rawValue)).tag(option)
          }
        }
        .pickerStyle(.menu)

        Text(verbatim: LocalizedFormat.powerOptionCount(MinimumPowerOption.allCases.count))
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Divider()

      Picker("profile.distance_to_stop", selection: $form.distanceRange) {
        ForEach(DistanceRangeOption.allCases, id: \.self) { option in
          Text(LocalizedStringKey(option.localizationKey)).tag(option)
        }
      }
      .pickerStyle(.menu)

      Divider()

      Stepper(
        value: minimumChargingPointsBinding,
        in: minimumChargingPointBounds,
        step: 1
      ) {
        LabeledContent("profile.charging_points") {
          Text(
            verbatim: LocalizedFormat.chargingPoints(
              form.minimumChargingPoints.rawValue
            )
          )
          .font(.body.monospacedDigit())
        }
      }

      Divider()

      Label {
        Text(
          verbatim: LocalizedFormat.maximumRouteCorridor(
            SearchConfiguration.maximumDistanceFromRoute.value
          )
        )
      } icon: {
        Image(systemName: "road.lanes")
      }
      .font(.subheadline)
      .foregroundStyle(.secondary)
    }
  }

  private var foodCard: some View {
    EditorCard {
      Text("profile.section.break")
        .font(.title3.weight(.bold))

      Picker("profile.preferred_food_chain", selection: $form.foodChain) {
        Text("food.any").tag(nil as FoodChain?)
        ForEach(FoodChain.allCases, id: \.self) { option in
          Text(LocalizedStringKey(option.localizationKey)).tag(Optional(option))
        }
      }
      .pickerStyle(.menu)

      if form.foodChain != nil {
        Divider()

        Label {
          Text(
            verbatim: LocalizedFormat.maximumFoodDistance(
              SearchConfiguration.maximumFoodDistance.value
            )
          )
        } icon: {
          Image(systemName: "figure.walk")
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
      }
    }
  }

  private var saveButton: some View {
    Button {
      save()
    } label: {
      HStack(spacing: 12) {
        Text("profile.save.action")
          .font(.headline)
        Spacer()
        Image(systemName: "arrow.right")
          .font(.headline)
          .accessibilityHidden(true)
      }
      .frame(maxWidth: .infinity)
      .padding(.horizontal, 4)
      .padding(.vertical, 6)
    }
    .buttonStyle(.borderedProminent)
    .controlSize(.large)
    .foregroundStyle(.black)
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(.ultraThinMaterial)
  }

  private var minimumChargingPointBounds: ClosedRange<Int> {
    let values = MinimumChargingPointsOption.allCases.map(\.rawValue)
    let lowerBound = values.first ?? form.minimumChargingPoints.rawValue
    let upperBound = values.last ?? form.minimumChargingPoints.rawValue
    return lowerBound...upperBound
  }

  private var minimumChargingPointsBinding: Binding<Int> {
    Binding(
      get: { form.minimumChargingPoints.rawValue },
      set: { proposedValue in
        if proposedValue > form.minimumChargingPoints.rawValue {
          form.selectNextMinimumChargingPoints()
        } else if proposedValue < form.minimumChargingPoints.rawValue {
          form.selectPreviousMinimumChargingPoints()
        }
      }
    )
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

private struct EditorCard<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      content
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(.secondarySystemGroupedBackground))
    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
    }
    .shadow(color: Color.black.opacity(0.05), radius: 10, y: 3)
  }
}
