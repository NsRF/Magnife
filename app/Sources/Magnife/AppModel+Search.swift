import AppKit
import MagnifeKit
import SwiftUI

/// Search (S-017, ⌘K): a panel over the window that looks up stored traces
/// by the shared query language. Every keystroke reads again, at most one
/// read in flight; the result for the newest text wins. Return opens the
/// highlighted trace, ⌘Return applies the query as the list's filters.
extension AppModel {
    /// The parsed query in the field.
    var searchQuery: TraceQuery { TraceQuery(searchText) }

    /// What the unfinished token at the end can become (`status:` ->
    /// error, ok, unset; `service:` -> service names; `has:` -> keys).
    var searchSuggestions: [String] {
        guard let unfinished = searchQuery.unfinished else { return [] }
        let candidates: [String] = switch unfinished.prefix {
        case .status: TraceQuery.statusValues
        case .service: services.map(\.name)
        case .has: searchAttributeKeys
        }
        return unfinished.suggestions(from: candidates, limit: 8)
    }

    /// The traces under the suggestions.
    var searchTraces: [TraceSummary] { searchResult?.traces ?? [] }

    /// Suggestions and traces are one list for ↑↓ and Return.
    var searchRowCount: Int { searchSuggestions.count + searchTraces.count }

    /// Edit > Search… (⌘K) and the toolbar's Search button. Pressed again
    /// while it shows, the field takes the focus back with its text selected.
    func showSearch() {
        searchFocusRequest += 1
        guard !showsSearch else { return }
        searchText = ""
        searchSelection = 0
        showsSearch = true
        runSearch()
        let cutoff = Retention.cutoffNs(seconds: retentionSeconds)
        Task { [weak self] in
            guard let reader = self?.reader else { return }
            let keys = (try? await reader.attributeKeys(seenSinceNs: cutoff)) ?? []
            self?.searchAttributeKeys = Array(Set(keys.map(\.key))).sorted()
        }
    }

    /// Esc, a click outside, or opening a result: nothing else changes.
    func closeSearch() {
        guard showsSearch else { return }
        showsSearch = false
        searchTask?.cancel()
        searchTask = nil
        searchAnnouncement?.cancel()
    }

    func searchTextChanged() {
        searchSelection = 0
        searchTypedAt = .now
        runSearch()
    }

    /// Reads the results for the text in the field. A new keystroke cancels
    /// the read before it, which stops its SQL; the page shows first and the
    /// total follows when the page came without it.
    func runSearch() {
        searchTask?.cancel()
        guard showsSearch, let reader = searchReader ?? reader else { return }
        let query = searchQuery
        searchTask = Task { [weak self] in
            guard let result = try? await reader.searchTraces(query) else { return }
            guard let self, !Task.isCancelled, self.searchText == query.text else { return }
            self.showSearchResult(result)
            guard result.total == nil, let total = try? await reader.searchCount(query),
                  !Task.isCancelled, self.searchResult?.text == query.text else { return }
            self.searchResult?.total = total
            self.announceSearchCount()
        }
    }

    private func showSearchResult(_ result: TraceSearchResult) {
        searchResult = result
        if let typed = searchTypedAt {
            lastSearchLatency = .now - typed
            searchTypedAt = nil
        }
        searchSelection = min(searchSelection, max(0, searchRowCount - 1))
        announceSearchCount()
    }

    /// VoiceOver hears the count once typing pauses (docs/ux.md, S-017 Access).
    private func announceSearchCount() {
        searchAnnouncement?.cancel()
        guard let result = searchResult, !result.isNewest, result.total != nil else { return }
        searchAnnouncement = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            AccessibilityNotification.Announcement(result.spokenCount).post()
        }
    }

    /// ↑↓ in the field: the highlight moves over suggestions and traces.
    func moveSearchSelection(by offset: Int) {
        guard searchRowCount > 0 else { return }
        searchSelection = min(max(0, searchSelection + offset), searchRowCount - 1)
    }

    /// Return: a highlighted suggestion completes its token; a trace opens.
    func activateSearchSelection() {
        let suggestions = searchSuggestions
        if searchSelection < suggestions.count {
            completeSearch(with: suggestions[searchSelection])
        } else if let trace = searchTraces[safe: searchSelection - suggestions.count] {
            openSearchResult(trace.traceID)
        }
    }

    /// A suggestion picked: "status:er" becomes "status:error ".
    func completeSearch(with value: String) {
        searchText = searchQuery.completing(with: value)
    }

    /// Opens a result: Search closes, the Traces view shows the trace in
    /// the detail column, selected in the list when the list shows it.
    func openSearchResult(_ traceID: String) {
        closeSearch()
        showContentMode(.traces)
        if selectedTraceID != traceID { selectedTraceID = traceID }
        Task { await revealSelectedTrace() }
    }

    /// ⌘Return, "Apply as Filter": the query becomes the trace list's
    /// filters (the sidebar takes its service), the filter bar shows them
    /// and Search closes.
    func applySearchAsFilter() {
        let filter = searchQuery.filter
        closeSearch()
        showContentMode(.traces)
        applyTraceFilter(filter)
        showsTraceFilterBar = true
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
