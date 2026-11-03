import Foundation

/// A finding's words with its place (detector audit 8): what is wrong and
/// where, per surface. With a nil place each one is the string without a
/// place (`line`, `detailText`, `accessibilityLabel`).
extension Finding {
    /// "checkout-api", "checkout-api and orders", "3 services"; nil with none.
    static func whereText(_ services: [String]) -> String? {
        let services = services.filter { !$0.isEmpty }
        switch services.count {
        case 0: return nil
        case 1: return services[0]
        case 2: return "\(services[0]) and \(services[1])"
        default: return "\(CountFormat.string(services.count)) services"
        }
    }

    private var thresholdText: String { DurationFormat.string(nanoseconds: Detectors.slowSQLThresholdNs) }
    private var totalText: String { DurationFormat.string(nanoseconds: durationNs) }
    private var isOutgoing: Bool { spanKind == .client || spanKind == .producer }
    private var message: String { statusMessage.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// A status message as the end of a sentence: one line, then "." unless it ends a sentence already.
    static func sentence(_ text: String) -> String {
        let line = oneLine(text)
        return [".", "!", "?", "…"].contains(where: line.hasSuffix) ? line : line + "."
    }

    /// "The span has status Error: context deadline exceeded."
    private static func statusError(_ message: String) -> String {
        message.isEmpty ? "The span has status Error." : "The span has status Error: \(sentence(message))"
    }

    // MARK: Strip line

    /// The strip line, where before the statement, since the view cuts the tail:
    /// "Slow SQL · 851 ms · checkout-api · GET /reports/sales · SELECT …".
    public func line(in place: FindingPlace?) -> String {
        guard let place else { return line }
        let shownUnder = place.underIsHeader ? nil : place.under
        let parts: [String?]
        switch kind {
        case .slowSQL:
            parts = [kind.title, durationText, Self.whereText(place.services), shownUnder, Self.oneLine(statement ?? spanName)]
        case .nPlusOne:
            parts = [kind.title, "\(CountFormat.string(count)) times, \(totalText) in all", Self.whereText(place.services),
                     shownUnder, Self.oneLine(statement ?? spanName)]
        case .httpError:
            let who = isOutgoing ? callerText(place).map { caller in place.callee.map { "\(caller) → \($0)" } ?? caller }
                : Self.whereText(place.services)
            parts = [kind.title, httpStatusCode.map(String.init) ?? "no response code", durationText, who, Self.oneLine(call)]
        }
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    private func callerText(_ place: FindingPlace) -> String? {
        place.caller ?? Self.whereText([serviceName])
    }

    // MARK: Span detail

    /// The span detail's text, which the strip line's tooltip shows too.
    public func detailText(in place: FindingPlace?) -> String {
        guard let place else { return detailText }
        let inWhere = Self.whereText(place.services).map { " in \($0)" } ?? ""
        let under = place.under.map { ", under \($0)" } ?? ""
        let share = place.share(of: self).map {
            ": \($0)% of the trace's \(DurationFormat.string(nanoseconds: place.traceDurationNs))"
        } ?? ""
        switch kind {
        case .slowSQL:
            let query = statement == nil ? "This \(dbSystem ?? "database") query" : "This query"
            return "\(query) took \(durationText)\(inWhere)\(under)\(share). Queries over \(thresholdText) are flagged."
                + (isError ? " " + Self.statusError(message) : "")
        case .nPlusOne:
            let min = DurationFormat.string(nanoseconds: minRunNs), max = DurationFormat.string(nanoseconds: maxRunNs)
            let runs = min == max ? "Each run took \(min)." : "The runs took \(min) to \(max)."
            return "This statement ran \(CountFormat.string(count)) times\(inWhere)\(under), \(totalText) in all\(share). "
                + "\(runs) Statements that run \(Detectors.nPlusOneMinimum) or more times in one trace are flagged."
        case .httpError:
            var text = httpOutcome(place, duration: durationText, spoken: false)
            if let callee = place.callee, let route = place.calleeRoute { text += " \(callee) answered as \(route)." }
            if let below = place.firstErrorBelow {
                let service = below.service.isEmpty ? "" : " in \(below.service)"
                text += " Under it, \(below.name)\(service) has status Error"
                    + (below.message.isEmpty ? "." : ": \(Self.sentence(below.message))")
            }
            if (httpStatusCode ?? 0) < Detectors.httpErrorMinimumCode {
                text += " Responses of \(Detectors.httpErrorMinimumCode) or higher, and spans with status Error, are flagged."
            }
            return text
        }
    }

    /// What the call did: "web called POST … and got 500 after 57 ms.",
    /// "POST /payments in checkout-api returned 500 to web after 52 ms.".
    /// Spoken: VoiceOver's clause, with no message and no final ".".
    private func httpOutcome(_ place: FindingPlace, duration: String, spoken: Bool) -> String {
        let errorText = spoken ? "" : " " + Self.statusError(message)
        let butError = ", but the span has status Error" + (spoken ? "" : message.isEmpty ? "." : ": \(Self.sentence(message))")
        let errorAfter = !spoken && isError && !message.isEmpty ? " " + Self.statusError(message) : ""
        let end = spoken ? "" : "."
        if isOutgoing {
            let subject = "\(callerText(place) ?? "The span") called \(call)"
            switch httpStatusCode {
            case nil: return "\(subject) and got no response code in \(duration)" + (spoken ? ", status Error" : "." + errorText)
            case let code? where code < Detectors.httpErrorMinimumCode:
                return "\(subject) and got \(code) after \(duration)\(butError)"
            case let code?: return "\(subject) and got \(code) after \(duration)\(end)\(errorAfter)"
            }
        }
        let subject = call + (Self.whereText(place.services).map { " in \($0)" } ?? "")
        let to = place.caller.map { " to \($0)" } ?? ""
        switch httpStatusCode {
        case nil: return "\(subject) sent no response code in \(duration)" + (spoken ? ", status Error" : "." + errorText)
        case let code? where code < Detectors.httpErrorMinimumCode:
            return "\(subject) returned \(code)\(to) after \(duration)\(butError)"
        case let code?: return "\(subject) returned \(code)\(to) after \(duration)\(end)\(errorAfter)"
        }
    }

    // MARK: VoiceOver

    /// The strip line for VoiceOver: "Slow SQL, 851 milliseconds, SELECT Orders in checkout-api, under GET /reports/sales".
    public func accessibilityLabel(in place: FindingPlace?) -> String {
        guard let place else { return accessibilityLabel }
        let inWhere = Self.whereText(place.services).map { " in \($0)" } ?? ""
        let under = place.under.map { ", under \($0)" } ?? ""
        switch kind {
        case .slowSQL:
            return "\(kind.title), \(spokenDuration), \(spanName)\(inWhere)\(under)" + (isError ? ", status Error" : "")
        case .nPlusOne:
            return "\(kind.title), \(spanName) ran \(CountFormat.string(count)) times, "
                + "\(DurationFormat.spoken(nanoseconds: durationNs)) in all"
                + (Self.whereText(place.services).map { ", in \($0)" } ?? "") + under
        case .httpError:
            return "\(kind.title), " + httpOutcome(place, duration: spokenDuration, spoken: true)
        }
    }

    /// What a click on the strip line does; nil without a place.
    public func accessibilityHint(in place: FindingPlace?) -> String? {
        guard place != nil else { return nil }
        return kind == .nPlusOne ? "Selects the first of the \(CountFormat.string(count)) spans"
            : "Selects the span in the waterfall"
    }

    // MARK: Waterfall row

    /// The waterfall row's tooltip for this span: "Slow SQL: 851 ms, over 100 ms",
    /// "N+1: run 1 of 8, 58 ms in all", "HTTP Error: 500".
    public func rowHelp(for spanID: String) -> String {
        switch kind {
        case .slowSQL:
            return isJustOverThreshold ? "\(kind.title): just over \(thresholdText)"
                : "\(kind.title): \(durationText), over \(thresholdText)"
        case .nPlusOne:
            return "\(kind.title): run \(CountFormat.string(run(of: spanID))) of \(CountFormat.string(count)), \(totalText) in all"
        case .httpError:
            switch httpStatusCode {
            case nil: return "\(kind.title): no response code, status Error"
            case let code? where code < Detectors.httpErrorMinimumCode: return "\(kind.title): \(code), status Error"
            case let code?: return "\(kind.title): \(code)"
            }
        }
    }
}
