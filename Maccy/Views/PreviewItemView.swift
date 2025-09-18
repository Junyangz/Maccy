import KeyboardShortcuts
import SwiftUI

struct PreviewItemView: View {
  @Environment(AppState.self) private var appState

  var item: HistoryItemDecorator?

  private var webLinks: [URL] {
    (item?.linkURLs ?? []).filter { !$0.isFileURL }
  }

  private var fileURLs: [URL] { item?.fileURLs ?? [] }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(localizedPreview("PreviewTitle", defaultValue: "Preview"))
        .font(.headline)

      if let item {
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            primaryContent(for: item)

            if let primaryURL = item.primaryURL {
              Button {
                appState.history.openLink(for: item, url: primaryURL)
              } label: {
                Label(localizedPreview("PreviewOpen", defaultValue: "Open"), systemImage: "arrow.up.right.square")
              }
              .buttonStyle(.borderedProminent)
            }

            if !webLinks.isEmpty {
              sectionHeader(localizedPreview("PreviewLinks", defaultValue: "Links"))

              VStack(alignment: .leading, spacing: 8) {
                ForEach(webLinks, id: \.absoluteString) { url in
                  Button {
                    appState.history.openLink(for: item, url: url)
                  } label: {
                    Label(urlDisplayName(url), systemImage: "link")
                      .frame(maxWidth: .infinity, alignment: .leading)
                  }
                  .buttonStyle(.plain)
                  .padding(.vertical, 6)
                  .padding(.horizontal, 10)
                  .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                }
              }
            }

            if !fileURLs.isEmpty {
              sectionHeader(localizedPreview("PreviewFiles", defaultValue: "Files"))

              VStack(alignment: .leading, spacing: 8) {
                ForEach(fileURLs, id: \.absoluteString) { url in
                  Button {
                    appState.history.openLink(for: item, url: url)
                  } label: {
                    Label(urlDisplayName(url), systemImage: "doc")
                      .frame(maxWidth: .infinity, alignment: .leading)
                  }
                  .buttonStyle(.plain)
                  .padding(.vertical, 6)
                  .padding(.horizontal, 10)
                  .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                }
              }
            }

            metadataSection(for: item)
            shortcutsSection
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      } else {
        Spacer()
        Text(localizedPreview("PreviewPlaceholder", defaultValue: "Select an item to see its details."))
          .multilineTextAlignment(.center)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .center)
        Spacer()
      }
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color(nsColor: .controlBackgroundColor))
  }

  @ViewBuilder
  private func primaryContent(for item: HistoryItemDecorator) -> some View {
    if let image = item.previewImage {
      Image(nsImage: image)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .clipShape(.rect(cornerRadius: 6))
        .frame(maxWidth: .infinity)
    } else if !item.text.isEmpty {
      WrappingTextView {
        Text(item.text)
          .font(.body)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 300, alignment: .topLeading)
      .padding(10)
      .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
    } else {
      Text(localizedPreview("PreviewUnavailable", defaultValue: "No preview available."))
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private func metadataSection(for item: HistoryItemDecorator) -> some View {
    sectionHeader(localizedPreview("PreviewDetails", defaultValue: "Details"))

    VStack(alignment: .leading, spacing: 6) {
      if let application = item.application {
        HStack(spacing: 6) {
          Text("Application", tableName: "PreviewItemView")
          Image(nsImage: item.applicationImage.nsImage)
            .resizable()
            .frame(width: 14, height: 14)
          Text(application)
        }
      }

      HStack(spacing: 6) {
        Text("FirstCopyTime", tableName: "PreviewItemView")
        Text(item.item.firstCopiedAt, style: .date)
        Text(item.item.firstCopiedAt, style: .time)
      }

      HStack(spacing: 6) {
        Text("LastCopyTime", tableName: "PreviewItemView")
        Text(item.item.lastCopiedAt, style: .date)
        Text(item.item.lastCopiedAt, style: .time)
      }

      HStack(spacing: 6) {
        Text("NumberOfCopies", tableName: "PreviewItemView")
        Text(String(item.item.numberOfCopies))
      }
    }
  }

  @ViewBuilder
  private var shortcutsSection: some View {
    sectionHeader(localizedPreview("PreviewShortcuts", defaultValue: "Shortcuts"))

    VStack(alignment: .leading, spacing: 6) {
      if let pinKey = KeyboardShortcuts.Shortcut(name: .pin) {
        Text(
          NSLocalizedString("PinKey", tableName: "PreviewItemView", comment: "")
            .replacingOccurrences(of: "{pinKey}", with: pinKey.description)
        )
      }

      if let deleteKey = KeyboardShortcuts.Shortcut(name: .delete) {
        Text(
          NSLocalizedString("DeleteKey", tableName: "PreviewItemView", comment: "")
            .replacingOccurrences(of: "{deleteKey}", with: deleteKey.description)
        )
      }

      Text(localizedPreview("PreviewOpenShortcutHelp", defaultValue: "Press ⌘O to open the first detected link or file."))
    }
  }

  @ViewBuilder
  private func sectionHeader(_ title: String) -> some View {
    Text(title)
      .font(.subheadline)
      .fontWeight(.semibold)
      .padding(.top, 8)
  }

  private func urlDisplayName(_ url: URL) -> String {
    if url.isFileURL {
      return url.lastPathComponent
    }

    return url.absoluteString.removingPercentEncoding ?? url.absoluteString
  }

  private func localizedPreview(_ key: String, defaultValue: String) -> String {
    NSLocalizedString(key, tableName: "PreviewItemView", bundle: .main, value: defaultValue, comment: "")
  }
}
