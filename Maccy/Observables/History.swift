// swiftlint:disable file_length
import AppKit.NSRunningApplication
import AppKit.NSWorkspace
import Defaults
import Foundation
import Logging
import Observation
import Sauce
import Settings
import SwiftData

@Observable
class History { // swiftlint:disable:this type_body_length
  static let shared = History()
  let logger = Logger(label: "org.p0deje.Maccy")

  enum ContentFilter: CaseIterable, Identifiable {
    case all
    case text
    case links
    case images
    case files

    var id: Self { self }

    var iconName: String {
      switch self {
      case .all:
        return "square.grid.2x2"
      case .text:
        return "text.alignleft"
      case .links:
        return "link"
      case .images:
        return "photo"
      case .files:
        return "doc"
      }
    }

    var localizationKey: String {
      switch self {
      case .all:
        return "filter_all"
      case .text:
        return "filter_text"
      case .links:
        return "filter_links"
      case .images:
        return "filter_images"
      case .files:
        return "filter_files"
      }
    }

    var defaultTitle: String {
      switch self {
      case .all:
        return "All"
      case .text:
        return "Text"
      case .links:
        return "Links"
      case .images:
        return "Images"
      case .files:
        return "Files"
      }
    }

    func matches(_ item: HistoryItemDecorator) -> Bool {
      switch self {
      case .all:
        return true
      case .text:
        return item.matchesTextFilter
      case .links:
        return item.matchesLinksFilter
      case .images:
        return item.matchesImagesFilter
      case .files:
        return item.matchesFilesFilter
      }
    }
  }

  var items: [HistoryItemDecorator] = []
  var selectedItem: HistoryItemDecorator? {
    willSet {
      selectedItem?.isSelected = false
      newValue?.isSelected = true
    }
  }

  var pinnedItems: [HistoryItemDecorator] { items.filter(\.isPinned) }
  var unpinnedItems: [HistoryItemDecorator] { items.filter(\.isUnpinned) }

  var searchQuery: String = "" {
    didSet {
      throttler.throttle { [self] in
        Task { @MainActor [self] in
          self.applyFilterAndSearch()
        }
      }
    }
  }

  var contentFilter: ContentFilter = .all {
    didSet {
      Task { @MainActor [self] in
        self.applyFilterAndSearch()
      }
    }
  }

  var pressedShortcutItem: HistoryItemDecorator? {
    guard let event = NSApp.currentEvent else {
      return nil
    }

    let modifierFlags = event.modifierFlags
      .intersection(.deviceIndependentFlagsMask)
      .subtracting(.capsLock)

    guard HistoryItemAction(modifierFlags) != .unknown else {
      return nil
    }

    let key = Sauce.shared.key(for: Int(event.keyCode))
    return items.first { $0.shortcuts.contains(where: { $0.key == key }) }
  }

  private let search = Search()
  private let sorter = Sorter()
  private let throttler = Throttler(minimumDelay: 0.2)

  @ObservationIgnored
  private var sessionLog: [Int: HistoryItem] = [:]

  // The distinction between `all` and `items` is the following:
  // - `all` stores all history items, even the ones that are currently hidden by a search
  // - `items` stores only visible history items, updated during a search
  @ObservationIgnored
  var all: [HistoryItemDecorator] = []

  init() {
    Task {
      for await _ in Defaults.updates(.pasteByDefault, initial: false) {
        updateShortcuts()
      }
    }

    Task {
      for await _ in Defaults.updates(.sortBy, initial: false) {
        try? await load()
      }
    }

    Task {
      for await _ in Defaults.updates(.pinTo, initial: false) {
        try? await load()
      }
    }

    Task {
      for await _ in Defaults.updates(.showSpecialSymbols, initial: false) {
        for item in items {
          await updateTitle(item: item, title: item.item.generateTitle())
        }
      }
    }

    Task {
      for await _ in Defaults.updates(.imageMaxHeight, initial: false) {
        for item in items {
          await item.cleanupImages()
        }
      }
    }
  }

  @MainActor
  func load() async throws {
    let descriptor = FetchDescriptor<HistoryItem>()
    let results = try Storage.shared.context.fetch(descriptor)
    all = sorter.sort(results).map { HistoryItemDecorator($0) }

    limitHistorySize(to: Defaults[.size])
    applyFilterAndSearch()

    // Ensure that panel size is proper *after* loading all items.
    Task {
      AppState.shared.popup.needsResize = true
    }
  }

  @MainActor
  private func limitHistorySize(to maxSize: Int) {
    let unpinned = all.filter(\.isUnpinned)
    if unpinned.count > maxSize {
      unpinned.dropFirst(maxSize).forEach(delete)
    }
  }

  @MainActor
  func insertIntoStorage(_ item: HistoryItem) throws {
    logger.info("Inserting item with id '\(item.title)'")
    Storage.shared.context.insert(item)
    Storage.shared.context.processPendingChanges()
    try? Storage.shared.context.save()
  }

  @discardableResult
  @MainActor
  func add(_ item: HistoryItem) -> HistoryItemDecorator {
    if #available(macOS 15.0, *) {
      try? History.shared.insertIntoStorage(item)
    } else {
      // On macOS 14 the history item needs to be inserted into storage directly after creating it.
      // It was already inserted after creation in Clipboard.swift
    }

    var removedItemIndex: Int?
    if let existingHistoryItem = findSimilarItem(item) {
      if isModified(item) == nil {
        item.contents = existingHistoryItem.contents
      }
      item.firstCopiedAt = existingHistoryItem.firstCopiedAt
      item.numberOfCopies += existingHistoryItem.numberOfCopies
      item.pin = existingHistoryItem.pin
      item.title = existingHistoryItem.title
      if !item.fromMaccy {
        item.application = existingHistoryItem.application
      }
      logger.info("Removing duplicate item '\(item.title)'")
      Storage.shared.context.delete(existingHistoryItem)
      removedItemIndex = all.firstIndex(where: { $0.item == existingHistoryItem })
      if let removedItemIndex {
        all.remove(at: removedItemIndex)
      }
    } else {
      Task {
        Notifier.notify(body: item.title, sound: .write)
      }
    }

    // Remove exceeding items. Do this after the item is added to avoid removing something
    // if a duplicate was found as then the size already stayed the same.
    limitHistorySize(to: Defaults[.size] - 1)

    sessionLog[Clipboard.shared.changeCount] = item

    var itemDecorator: HistoryItemDecorator
    if let pin = item.pin {
      itemDecorator = HistoryItemDecorator(item, shortcuts: KeyShortcut.create(character: pin))
      // Keep pins in the same place.
      if let removedItemIndex {
        all.insert(itemDecorator, at: removedItemIndex)
      }
    } else {
      itemDecorator = HistoryItemDecorator(item)

      let sortedItems = sorter.sort(all.map(\.item) + [item])
      if let index = sortedItems.firstIndex(of: item) {
        all.insert(itemDecorator, at: index)
      }
    }

    applyFilterAndSearch(shouldUpdateSelection: searchQuery.isEmpty && contentFilter.matches(itemDecorator))

    return itemDecorator
  }

  @MainActor
  private func withLogging(_ msg: String, _ block: () throws -> Void) rethrows {
    func dataCounts() -> String {
      let historyItemCount = try? Storage.shared.context.fetchCount(FetchDescriptor<HistoryItem>())
      let historyContentCount = try? Storage.shared.context.fetchCount(FetchDescriptor<HistoryItemContent>())
      return "HistoryItem=\(historyItemCount ?? 0) HistoryItemContent=\(historyContentCount ?? 0)"
    }

    logger.info("\(msg) Before: \(dataCounts())")
    try? block()
    logger.info("\(msg) After: \(dataCounts())")
  }

  @MainActor
  func clear() {
    withLogging("Clearing history") {
      all.forEach { item in
        if item.isUnpinned {
          cleanup(item)
        }
      }
      all.removeAll(where: \.isUnpinned)
      sessionLog.removeValues { $0.pin == nil }

      try? Storage.shared.context.transaction {
        try? Storage.shared.context.delete(
          model: HistoryItem.self,
          where: #Predicate { $0.pin == nil }
        )
        try? Storage.shared.context.delete(
          model: HistoryItemContent.self,
          where: #Predicate { $0.item?.pin == nil }
        )
      }
      Storage.shared.context.processPendingChanges()
      try? Storage.shared.context.save()
    }

    applyFilterAndSearch()

    Clipboard.shared.clear()
    AppState.shared.popup.close()
    Task {
      AppState.shared.popup.needsResize = true
    }
  }

  @MainActor
  func clearAll() {
    withLogging("Clearing all history") {
      all.forEach { item in
        cleanup(item)
      }
      all.removeAll()
      sessionLog.removeAll()
      items.removeAll()

      try? Storage.shared.context.delete(model: HistoryItem.self)
      Storage.shared.context.processPendingChanges()
      try? Storage.shared.context.save()
    }

    applyFilterAndSearch()

    Clipboard.shared.clear()
    AppState.shared.popup.close()
    Task {
      AppState.shared.popup.needsResize = true
    }
  }

  @MainActor
  func delete(_ item: HistoryItemDecorator?) {
    guard let item else { return }

    cleanup(item)
    withLogging("Removing history item") {
      Storage.shared.context.delete(item.item)
      Storage.shared.context.processPendingChanges()
      try? Storage.shared.context.save()
    }

    all.removeAll { $0 == item }
    items.removeAll { $0 == item }
    sessionLog.removeValues { $0 == item.item }

    applyFilterAndSearch()
  }

  @MainActor
  private func cleanup(_ item: HistoryItemDecorator) {
    item.cleanupImages()
  }

  @MainActor
  func select(_ item: HistoryItemDecorator?) {
    guard let item else {
      return
    }

    let modifierFlags = NSApp.currentEvent?.modifierFlags
      .intersection(.deviceIndependentFlagsMask)
      .subtracting([.capsLock, .numericPad, .function]) ?? []

    if modifierFlags.isEmpty {
      AppState.shared.popup.close()
      Clipboard.shared.copy(item.item, removeFormatting: Defaults[.removeFormattingByDefault])
      if Defaults[.pasteByDefault] {
        Clipboard.shared.paste()
      }
    } else {
      switch HistoryItemAction(modifierFlags) {
      case .copy:
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item)
      case .paste:
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item)
        Clipboard.shared.paste()
      case .pasteWithoutFormatting:
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item, removeFormatting: true)
        Clipboard.shared.paste()
      case .unknown:
        return
      }
    }

    Task {
      searchQuery = ""
    }
  }

  @MainActor
  func togglePin(_ item: HistoryItemDecorator?) {
    guard let item else { return }

    item.togglePin()

    let sortedItems = sorter.sort(all.map(\.item))
    if let currentIndex = all.firstIndex(of: item),
       let newIndex = sortedItems.firstIndex(of: item.item) {
      all.remove(at: currentIndex)
      all.insert(item, at: newIndex)
    }

    let shouldRefreshImmediately = searchQuery.isEmpty
    searchQuery = ""
    if shouldRefreshImmediately {
      applyFilterAndSearch()
    }
    if item.isUnpinned {
      AppState.shared.scrollTarget = item.id
    }
  }

  @MainActor
  func cycleFilter() {
    guard let currentIndex = ContentFilter.allCases.firstIndex(of: contentFilter) else { return }
    let nextIndex = ContentFilter.allCases.index(after: currentIndex)
    let wrappedIndex = nextIndex == ContentFilter.allCases.endIndex ? ContentFilter.allCases.startIndex : nextIndex
    contentFilter = ContentFilter.allCases[wrappedIndex]
  }

  @MainActor
  func openLink(for item: HistoryItemDecorator? = nil, url: URL? = nil) {
    let targetItem = item ?? selectedItem ?? items.first
    guard let resolvedURL = url ?? targetItem?.primaryURL else { return }

    NSWorkspace.shared.open(resolvedURL)
  }

  @MainActor
  private func findSimilarItem(_ item: HistoryItem) -> HistoryItem? {
    let descriptor = FetchDescriptor<HistoryItem>()
    if let all = try? Storage.shared.context.fetch(descriptor) {
      let duplicates = all.filter({ $0 == item || $0.supersedes(item) })
      if duplicates.count > 1 {
        return duplicates.first(where: { $0 != item })
      } else {
        return isModified(item)
      }
    }

    return item
  }

  private func isModified(_ item: HistoryItem) -> HistoryItem? {
    if let modified = item.modified, sessionLog.keys.contains(modified) {
      return sessionLog[modified]
    }

    return nil
  }

  @MainActor
  private func applyFilterAndSearch(shouldUpdateSelection: Bool = true) {
    let filteredItems = all.filter { contentFilter.matches($0) }
    let results = search.search(string: searchQuery, within: filteredItems)
    let visibleIdentifiers = Set(results.map { $0.object.id })

    for item in all {
      item.isVisible = visibleIdentifiers.contains(item.id)
    }

    updateItems(results)
    updateShortcuts()

    if shouldUpdateSelection {
      if searchQuery.isEmpty {
        if let first = unpinnedItems.first?.id ?? pinnedItems.first?.id {
          AppState.shared.selection = first
        } else {
          AppState.shared.selection = nil
        }
      } else {
        AppState.shared.highlightFirst()
      }
    }

    AppState.shared.popup.needsResize = true
  }

  private func updateItems(_ newItems: [Search.SearchResult]) {
    items = newItems.map { result in
      let item = result.object
      item.highlight(searchQuery, result.ranges)

      return item
    }
  }

  private func updateShortcuts() {
    for item in pinnedItems {
      if let pin = item.item.pin {
        item.shortcuts = KeyShortcut.create(character: pin)
      }
    }

    updateUnpinnedShortcuts()
  }

  @MainActor
  private func updateTitle(item: HistoryItemDecorator, title: String) {
    item.title = title
    item.item.title = title
  }

  private func updateUnpinnedShortcuts() {
    let visibleUnpinnedItems = unpinnedItems.filter(\.isVisible)
    for item in visibleUnpinnedItems {
      item.shortcuts = []
    }

    var index = 1
    for item in visibleUnpinnedItems.prefix(10) {
      item.shortcuts = KeyShortcut.create(character: String(index))
      index += 1
    }
  }
}
