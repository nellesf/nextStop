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
        VStack(spacing: 14) {
          identitySection
          destinationCard
          chargingCard
          foodCard
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 18)
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

  private var identitySection: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text("profile.name")
        .font(.subheadline.weight(.semibold))

      TextField("profile.name", text: $form.name)
        .textInputAutocapitalization(.words)
        .padding(.horizontal, 14)
        .frame(minHeight: 48)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var destinationCard: some View {
    EditorCard {
      Button {
        isDestinationSearchPresented = true
      } label: {
        HStack(alignment: .center, spacing: 12) {
          Image(systemName: "mappin.and.ellipse")
            .foregroundStyle(.primary)
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
        .frame(minHeight: 44)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(Text("profile.destination"))
      .accessibilityValue(
        Text(
          verbatim: form.destination?.displayName
            ?? String(localized: "destination.empty")
        )
      )
    }
  }

  private var chargingCard: some View {
    EditorCard {
      Text("profile.section.charging")
        .font(.title3.weight(.bold))

      minimumPowerMenu

      Divider()

      distanceRangeMenu

      Divider()

      chargingPointControl

      Divider()

      Label {
        Text(
          verbatim: LocalizedFormat.maximumRouteCorridor(
            SearchConfiguration.maximumDistanceFromRoute.value
          )
        )
      } icon: {
        Image(systemName: "info.circle")
      }
      .font(.footnote)
      .foregroundStyle(.secondary)
    }
  }

  private var minimumPowerMenu: some View {
    Menu {
      ForEach(MinimumPowerOption.allCases, id: \.self) { option in
        Button {
          form.minimumPower = option
        } label: {
          if form.minimumPower == option {
            Label {
              Text(verbatim: LocalizedFormat.kilowatts(option.rawValue))
            } icon: {
              Image(systemName: "checkmark")
            }
          } else {
            Text(verbatim: LocalizedFormat.kilowatts(option.rawValue))
          }
        }
      }
    } label: {
      EditorSelectionRow {
        VStack(alignment: .leading, spacing: 3) {
          Text("profile.minimum_power")
            .font(.body)

          Text(verbatim: LocalizedFormat.powerOptionCount(MinimumPowerOption.allCases.count))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } selection: {
        Text(verbatim: LocalizedFormat.kilowatts(form.minimumPower.rawValue))
          .font(.body.weight(.medium))
          .foregroundStyle(Color.black.opacity(0.86))
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(Color.nextStopHighlight, in: Capsule())
      }
    }
    .buttonStyle(.plain)
    .accessibilityLabel(Text("profile.minimum_power"))
    .accessibilityValue(
      Text(verbatim: LocalizedFormat.kilowatts(form.minimumPower.rawValue))
    )
  }

  private var distanceRangeMenu: some View {
    Menu {
      ForEach(DistanceRangeOption.allCases, id: \.self) { option in
        Button {
          form.distanceRange = option
        } label: {
          if form.distanceRange == option {
            Label {
              Text(LocalizedStringKey(option.localizationKey))
            } icon: {
              Image(systemName: "checkmark")
            }
          } else {
            Text(LocalizedStringKey(option.localizationKey))
          }
        }
      }
    } label: {
      EditorSelectionRow {
        Text("profile.distance_to_stop")
          .font(.body)
      } selection: {
        Text(LocalizedStringKey(form.distanceRange.localizationKey))
          .font(.body.weight(.medium))
      }
    }
    .buttonStyle(.plain)
    .accessibilityLabel(Text("profile.distance_to_stop"))
    .accessibilityValue(Text(LocalizedStringKey(form.distanceRange.localizationKey)))
  }

  private var chargingPointControl: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("profile.charging_points")
        .font(.subheadline.weight(.medium))

      HStack(spacing: 0) {
        Button {
          form.selectPreviousMinimumChargingPoints()
        } label: {
          Image(systemName: "minus")
            .font(.body.weight(.medium))
            .frame(maxWidth: .infinity, minHeight: 46)
            .contentShape(Rectangle())
        }
        .disabled(!canSelectPreviousMinimumChargingPoints)
        .foregroundStyle(
          canSelectPreviousMinimumChargingPoints
            ? Color.primary
            : Color.secondary.opacity(0.4)
        )

        Divider()
          .frame(height: 46)

        Text(verbatim: form.minimumChargingPoints.rawValue.formatted())
          .font(.body.weight(.semibold).monospacedDigit())
          .frame(maxWidth: .infinity, minHeight: 46)

        Divider()
          .frame(height: 46)

        Button {
          form.selectNextMinimumChargingPoints()
        } label: {
          Image(systemName: "plus")
            .font(.body.weight(.medium))
            .frame(maxWidth: .infinity, minHeight: 46)
            .contentShape(Rectangle())
        }
        .disabled(!canSelectNextMinimumChargingPoints)
        .foregroundStyle(
          canSelectNextMinimumChargingPoints
            ? Color.primary
            : Color.secondary.opacity(0.4)
        )
      }
      .background(Color(.tertiarySystemGroupedBackground))
      .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
          .stroke(Color.primary.opacity(0.12), lineWidth: 1)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(Text("profile.charging_points"))
      .accessibilityValue(
        Text(
          verbatim: LocalizedFormat.chargingPoints(
            form.minimumChargingPoints.rawValue
          )
        )
      )
      .accessibilityAdjustableAction { direction in
        switch direction {
        case .increment:
          form.selectNextMinimumChargingPoints()
        case .decrement:
          form.selectPreviousMinimumChargingPoints()
        @unknown default:
          break
        }
      }
    }
  }

  private var foodCard: some View {
    EditorCard {
      Text("profile.section.break")
        .font(.title3.weight(.bold))

      Toggle(isOn: $form.requiresNearbyRestaurant) {
        VStack(alignment: .leading, spacing: 3) {
          Text("profile.restaurant.required")
            .font(.body.weight(.medium))

          Text("profile.restaurant.required.description")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .tint(Color.nextStopHighlight)
      .accessibilityLabel(Text("profile.restaurant.required"))
      .accessibilityHint(Text("profile.restaurant.required.description"))

      Divider()

      if form.requiresNearbyRestaurant {
        Menu {
          ForEach(FoodChain.allCases, id: \.self) { option in
            Button {
              form.foodChain = option
            } label: {
              if form.foodChain == option {
                Label {
                  Text(LocalizedStringKey(option.localizationKey))
                } icon: {
                  Image(systemName: "checkmark")
                }
              } else {
                Text(LocalizedStringKey(option.localizationKey))
              }
            }
          }
        } label: {
          EditorSelectionRow {
            Text("profile.restaurant.chain")
              .font(.body)
          } selection: {
            selectedFoodChainText
              .font(.body.weight(.medium))
          }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("profile.restaurant.chain"))
        .accessibilityValue(selectedFoodChainAccessibilityValue)

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
        .font(.footnote)
        .foregroundStyle(.secondary)
      } else {
        Label("profile.restaurant.not_required.explanation", systemImage: "info.circle")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  @ViewBuilder
  private var selectedFoodChainText: some View {
    if let foodChain = form.foodChain {
      Text(LocalizedStringKey(foodChain.localizationKey))
    } else {
      Text("profile.restaurant.chain.placeholder")
        .foregroundStyle(.secondary)
    }
  }

  private var selectedFoodChainAccessibilityValue: Text {
    if let foodChain = form.foodChain {
      Text(LocalizedStringKey(foodChain.localizationKey))
    } else {
      Text("profile.restaurant.chain.placeholder")
    }
  }

  private var canSelectPreviousMinimumChargingPoints: Bool {
    guard
      let currentIndex = MinimumChargingPointsOption.allCases.firstIndex(
        of: form.minimumChargingPoints
      )
    else {
      return false
    }
    return currentIndex > MinimumChargingPointsOption.allCases.startIndex
  }

  private var canSelectNextMinimumChargingPoints: Bool {
    guard
      let currentIndex = MinimumChargingPointsOption.allCases.firstIndex(
        of: form.minimumChargingPoints
      )
    else {
      return false
    }
    return MinimumChargingPointsOption.allCases.index(after: currentIndex)
      < MinimumChargingPointsOption.allCases.endIndex
  }

  private var saveButton: some View {
    Button {
      save()
    } label: {
      HStack(spacing: 12) {
        Image(systemName: "arrow.right")
          .font(.headline.weight(.bold))
          .hidden()
          .accessibilityHidden(true)

        Text("profile.save.action")
          .font(.headline)
          .frame(maxWidth: .infinity)

        Image(systemName: "arrow.right")
          .font(.headline.weight(.bold))
          .foregroundStyle(Color.nextStopHighlight)
          .accessibilityHidden(true)
      }
      .frame(maxWidth: .infinity)
      .padding(.horizontal, 18)
      .frame(minHeight: 56)
      .foregroundStyle(Color(.systemBackground))
      .background(
        Color(.label),
        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
      )
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(.bar)
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

private struct EditorSelectionRow<Leading: View, Selection: View>: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  let leading: Leading
  let selection: Selection

  init(
    @ViewBuilder leading: () -> Leading,
    @ViewBuilder selection: () -> Selection
  ) {
    self.leading = leading()
    self.selection = selection()
  }

  var body: some View {
    Group {
      if dynamicTypeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 8) {
          leading

          HStack(alignment: .firstTextBaseline, spacing: 8) {
            selection
              .multilineTextAlignment(.leading)

            Spacer(minLength: 8)
            chevron
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      } else {
        HStack(alignment: .center, spacing: 12) {
          leading
            .frame(maxWidth: .infinity, alignment: .leading)

          selection
            .multilineTextAlignment(.trailing)

          chevron
        }
      }
    }
    .frame(minHeight: 44)
    .contentShape(Rectangle())
  }

  private var chevron: some View {
    Image(systemName: "chevron.right")
      .font(.caption.weight(.bold))
      .foregroundStyle(.tertiary)
      .accessibilityHidden(true)
  }
}

private struct EditorCard<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      content
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(.secondarySystemGroupedBackground))
    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .stroke(Color.primary.opacity(0.07), lineWidth: 1)
    }
    .shadow(color: Color.black.opacity(0.04), radius: 8, y: 2)
  }
}
