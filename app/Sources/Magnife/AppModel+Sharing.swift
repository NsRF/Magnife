import AppKit
import MagnifeKit
import UniformTypeIdentifiers

/// Sharing traces as files (v0.2): File > Export Trace… writes the selected
/// trace, its spans and logs, as OTLP JSON Lines (`TraceExport`); File >
/// Import Traces… (or a file dropped on the window) hands OTLP JSON files to
/// the helper, which stays the only writer: it answers "imported" once the
/// records are committed, and the first imported trace opens.
extension AppModel {
    /// The files Import Traces… offers: Magnife's .jsonl, and the .json a
    /// Collector's file exporter writes.
    static var importableTypes: [UTType] {
        [UTType(filenameExtension: TraceExport.fileExtension), UTType(filenameExtension: "ndjson"), .json].compactMap(\.self)
    }

    // MARK: Export

    /// File > Export Trace… (⇧⌘E): the selected trace.
    func exportSelectedTrace() { exportTrace(selectedTraceID) }

    /// The trace list's Export Trace… menu item, and File > Export Trace….
    func exportTrace(_ traceID: String?) {
        guard let traceID, let reader else { return NSSound.beep() }
        Task {
            let export: TraceExport?
            let summary: TraceSummary?
            do {
                export = try await reader.exportTrace(traceID: traceID)
                summary = try await reader.trace(id: traceID)
            } catch {
                return showSharingAlert("The trace could not be read.", detail: error.localizedDescription)
            }
            guard let export else {
                return showSharingAlert("This trace is no longer stored.",
                                        detail: "Traces older than the retention set in Settings > General are deleted.")
            }
            let panel = NSSavePanel()
            panel.title = "Export Trace"
            panel.nameFieldStringValue = summary.map(TraceExport.suggestedFileName)
                ?? "trace \(traceID.prefix(8)).\(TraceExport.fileExtension)"
            if let type = UTType(filenameExtension: TraceExport.fileExtension) { panel.allowedContentTypes = [type] }
            panel.canCreateDirectories = true
            panel.message = "\(Self.count(export.spanCount, "span")) and \(Self.count(export.logCount, "log")) as OTLP JSON. "
                + "Anyone with Magnife can open the file with File > Import Traces…."
            guard await runPanel(panel) == .OK, let url = panel.url else { return }
            do {
                try export.data.write(to: url, options: .atomic)
            } catch {
                showSharingAlert("The trace could not be saved.", detail: error.localizedDescription)
            }
        }
    }

    // MARK: Import

    /// File > Import Traces… (⇧⌘I).
    func importTraces() {
        let panel = NSOpenPanel()
        panel.title = "Import Traces"
        panel.prompt = "Import"
        panel.message = "Choose OTLP JSON files: exported from Magnife, or written by an OpenTelemetry Collector's file exporter."
        panel.allowedContentTypes = Self.importableTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        Task {
            guard await runPanel(panel) == .OK else { return }
            importTraces(from: panel.urls)
        }
    }

    /// Hands each file to the helper. The answer arrives as a helper event
    /// (`importFinished`, `importFailed`).
    func importTraces(from urls: [URL]) {
        for url in urls where url.isFileURL {
            let path = url.standardizedFileURL.path(percentEncoded: false)
            guard HelperCommand.isValidImportPath(path) else {
                showSharingAlert("“\(url.lastPathComponent)” cannot be imported.",
                                 detail: "Move the file to a folder whose path has no line breaks, then try again.")
                continue
            }
            do {
                guard let supervisor else { throw HelperSupervisorError.notRunning }
                try supervisor.send(.importFile(path: path))
                pendingImports.insert(path)
            } catch HelperSupervisorError.notRunning {
                showSharingAlert("The receiver is not running.",
                                 detail: "Magnife imports files through its receiver. Wait until the toolbar says it is listening, then try again.")
                return
            } catch {
                showSharingAlert("“\(url.lastPathComponent)” could not be imported.", detail: String(describing: error))
            }
        }
    }

    /// "imported": the records are committed. The first trace opens in the
    /// Traces view; a file of logs only shows the Logs view.
    func importFinished(_ event: ImportedEvent) {
        guard pendingImports.remove(event.path) != nil else { return }
        requestRefresh()
        guard let traceID = event.traces.first else {
            if event.logs > 0 { showContentMode(.logs) }
            return
        }
        launchSelection = nil
        closeSearch()
        showContentMode(.traces)
        if selectedTraceID == traceID {
            openSelectedTrace()
        } else {
            selectedTraceID = traceID
        }
        Task { await revealSelectedTrace() }
    }

    /// "import_failed": the helper stored nothing from the file.
    func importFailed(path: String, message: String) {
        guard pendingImports.remove(path) != nil else { return }
        let name = URL(fileURLWithPath: path).lastPathComponent
        showSharingAlert("“\(name)” could not be imported.", detail: message)
    }

    // MARK: Panels and alerts

    /// "1 span", "1,204 spans".
    static func count(_ n: Int, _ noun: String) -> String {
        "\(CountFormat.string(n)) \(noun)\(n == 1 ? "" : "s")"
    }

    private func runPanel(_ panel: NSSavePanel) async -> NSApplication.ModalResponse {
        if let window = NSApp.mainWindow ?? NSApp.keyWindow {
            return await panel.beginSheetModal(for: window)
        }
        return panel.runModal()
    }

    private func showSharingAlert(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        if let window = NSApp.mainWindow ?? NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
