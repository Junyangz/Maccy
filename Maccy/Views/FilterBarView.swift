import SwiftUI

struct FilterBarView: View {
  @Environment(AppState.self) private var appState

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(History.ContentFilter.allCases) { filter in
          FilterChip(filter: filter, isSelected: appState.history.contentFilter == filter)
        }
      }
      .padding(.vertical, 6)
      .padding(.horizontal, 4)
    }
    .frame(height: 36)
  }
}

private struct FilterChip: View {
  @Environment(AppState.self) private var appState

  var filter: History.ContentFilter
  var isSelected: Bool

  var body: some View {
    Button {
      appState.history.contentFilter = filter
    } label: {
      Label(title: {
        Text(title)
          .font(.footnote)
      }, icon: {
        Image(systemName: filter.iconName)
          .font(.footnote)
      })
      .padding(.vertical, 6)
      .padding(.horizontal, 12)
      .frame(minHeight: 28)
      .background(backgroundColor)
      .foregroundStyle(foregroundColor)
      .overlay(
        Capsule()
          .strokeBorder(borderColor, lineWidth: 1)
      )
      .clipShape(Capsule())
    }
    .buttonStyle(.plain)
  }

  private var title: String {
    NSLocalizedString(
      filter.localizationKey,
      tableName: nil,
      bundle: .main,
      value: filter.defaultTitle,
      comment: "Clipboard filter title"
    )
  }

  private var backgroundColor: Color {
    isSelected ? Color.accentColor.opacity(0.2) : Color.clear
  }

  private var foregroundColor: Color {
    isSelected ? Color.accentColor : Color.primary
  }

  private var borderColor: Color {
    isSelected ? Color.accentColor : Color.secondary.opacity(0.3)
  }
}
