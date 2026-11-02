import Foundation
import MagnifeKit

/// Findings (S-023+): the trace list's badges, and selecting a finding's span
/// from the strip under the waterfall header. The detectors run off the main
/// actor, inside the reader's methods.
extension AppModel {
    /// The badges of a row, once read.
    func findingSummary(for trace: TraceSummary) -> FindingSummary? {
        findingCache.summary(for: trace)
    }

    /// What VoiceOver reads for a row: the S-004 sentence, then its findings
    /// ("…, Error, findings: HTTP Error", docs/ux.md S-023 Access).
    func rowAccessibilityLabel(_ trace: TraceSummary) -> String {
        ([trace.accessibilityLabel] + [findingSummary(for: trace)?.spoken].compactMap { $0 }).joined(separator: ", ")
    }

    /// Reads the badges of rows that have none yet, or whose trace changed
    /// since. One read in flight; rows that change meanwhile are read after it.
    func updateTraceFindings() {
        guard let reader else { return }
        let readerID = ObjectIdentifier(reader)
        if findingCacheReader != readerID {
            findingsTask?.cancel()
            findingsTask = nil
            findingCacheReader = readerID
            if findingCache.count > 0 { findingCache = FindingCache() }
        }
        guard findingsTask == nil else {
            findingsAgain = true
            return
        }
        let stale = findingCache.stale(traces)
        guard !stale.isEmpty else { return }
        let seqs = Dictionary(stale.map { ($0.traceID, $0.updatedSeq) }, uniquingKeysWith: max)
        findingsTask = Task { [weak self] in
            let summaries = try? await reader.findingSummaries(traceIDs: Array(seqs.keys))
            guard let self, !Task.isCancelled else { return }
            self.findingsTask = nil
            if let summaries, reader === self.reader {
                var cache = self.findingCache
                cache.store(summaries, seqs: seqs)
                // Rows scrolled out of the list (a new scope, pruning) are forgotten.
                if cache.count > self.traces.count + TraceList.pageSize {
                    cache.keep(only: Set(self.traces.map(\.traceID)))
                }
                if cache != self.findingCache { self.findingCache = cache }
            }
            if self.findingsAgain {
                self.findingsAgain = false
                self.updateTraceFindings()
            }
        }
    }

    /// Waits until every shown row has its badges (self-test, snapshots).
    func waitForTraceFindings() async {
        for _ in 0..<100 {
            if findingsTask == nil, findingCache.stale(traces).isEmpty { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// A strip line: select the finding's first span, opening its parents,
    /// and show its span detail on the Span tab, Findings first.
    func selectFinding(_ finding: Finding) {
        guard let spanID = finding.spanIDs.first else { return }
        selectSpanOpeningParents(spanID)
        showSpanDetailTab(.span)
        if !showsSpanDetail { showsSpanDetail = true }
    }
}
