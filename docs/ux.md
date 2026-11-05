# Magnife — UX spec

The app-wide shape of Magnife v0.1 and a `UX:` block for every story from S-009 to S-032. S-001 to S-008 keep their blocks in [STORIES.md](STORIES.md); nothing here changes them. Words come from [GLOSSARY.md](GLOSSARY.md); every new term is listed at the end. Binding inputs: [BRIEF.md](BRIEF.md), [research/design.md](research/design.md) decisions 1–8, [research/platform.md](research/platform.md) decisions 7–9.

## 1. App-wide structure

### Window

One main window, a `WindowGroup` that never offers File > New Window (the `.newItem` command group is replaced). Closing it keeps Magnife running and receiving (S-008); clicking the Dock icon or Window > Magnife (⌘0) brings it back.

`NavigationSplitView`, three columns:

| Column | Width (min / ideal) | Traces view | Logs view |
| --- | --- | --- | --- |
| Sidebar | 180 / 210 | Scope: All Services, Services, Saved Filters | Same sidebar |
| Content | 360 / 520 | Filter bar (when shown) over the trace list | Filter bar (when shown) over the log list |
| Detail | 420 / 560 | Waterfall on top, span detail below (vertical split, 55 / 45 by default) | Log detail |

- The span detail is the lower pane of the detail column. It has a two-segment picker at its top: **Span** (S-006, S-007, S-011, findings) and **Trace Logs** (S-012). Space or ⌃⌘I hides and shows the pane; the waterfall then takes the whole column.
- Column widths, the split position, the span detail picker and its visibility are remembered per view across launches.
- Window title: the sidebar scope ("All Services", "checkout-api", "Checkout errors"). Subtitle: the count in the list, "1,204 traces" or "312 of 1,204 traces" when filters hide some; "8,310 logs" in the Logs view; prefixed "Paused · " while paused. An edited saved filter reads "Checkout errors — Edited".

### Sidebar and scope

The sidebar sets the scope. Exactly one row is selected:

- **All Services** (icon `square.stack.3d.up`), then section **Services**: one row per service, alphabetical, with its color dot and, when above zero, a trailing red octagon (`exclamationmark.octagon.fill`) and the number of stored traces in which that service has an Error span.
- Section **Saved Filters** (hidden while there are none): one row per saved filter, icon `line.3.horizontal.decrease.circle`, in the order created.

A service scope lists every trace with at least one span from that service; the list's Service column still shows each trace's root service. The scope applies to both views. Selecting a saved filter switches to the Traces view.

### Traces vs Logs

A two-segment control **Traces | Logs** in the toolbar, also View > Traces (⌘1) and View > Logs (⌘2).

Why: it is how Activity Monitor and Xcode's navigators switch what one list shows inside a single window, it stays visible in every state, and it leaves the sidebar to one job, the scope, which applies to both views. Putting Traces and Logs in the sidebar would make one selection mean two things and lose the selected service on every switch.

### Toolbar

Left to right:

1. Toggle Sidebar (system).
2. Window title and subtitle.
3. **Traces | Logs** segmented control.
4. **Pause** / **Resume** (`pause.fill` / `play.fill`, icon only).
5. **Filter** (`line.3.horizontal.decrease.circle`, filled with the accent color while any filter is on), toggles the filter bar.
6. Receiver status text (S-001), at the leading edge of the detail column.
7. Flexible space.
8. **Copy Environment Variables** (`terminal`, icon only): opens a popover with the S-003 language tabs, the variables and a "Copy Environment Variables" button, so the setup stays reachable after the first trace. ⇧⌘C copies the last chosen language without opening it.
9. **Search** (`magnifyingglass`, icon only): opens Search (⌘K).

Tooltips:

| Control | Tooltip |
| --- | --- |
| Traces segment | Show traces (⌘1) |
| Logs segment | Show logs (⌘2) |
| Pause | Hold the list still while new traces keep arriving (⌃⌘P) |
| Resume | Add the traces that arrived while paused (⌃⌘P) |
| Filter, off | Show the filter bar (⌘F) |
| Filter, on | Filters are on. Show the filter bar (⌘F) |
| Filter, bar shown | Hide the filter bar (⌘F) |
| Copy Environment Variables | Show the environment variables that point an app at Magnife |
| Search | Look up a trace by service, route, trace ID or attribute (⌘K) |

The toolbar is not customizable in v0.1.

### Filter bar

Shown with ⌘F or the Filter button, above the list of the current view; Esc or its close button hides it and the filters stay on. One per view.

- Traces, first line: Service pop-up (same setting as the sidebar) · status chips Error, OK, Unset · "Slower than" field · flexible space · "Save Filter…" · "Clear Filters" · close button. Below: condition rows, key / operator / value / − / + (S-020).
- Logs, one line: Service pop-up · level chips TRACE to FATAL · "Body contains" field · flexible space · "Clear Filters" · close button. Log filters are not saved.
- Click a chip to show only that one; ⌘-click or Space adds or removes one; no chip on means all.
- Close button tooltip: "Hide the filter bar (Esc)". "Clear Filters" resets the bar and the scope to All Services, and is undoable.

### Menu bar

Every action has a menu item. Items that do not apply are disabled, not hidden, except where noted.

**Magnife**
- About Magnife (the standard About panel; its credits read "Made by Nasser Farhat" and "GitHub · LinkedIn", links to github.com/NsRF and linkedin.com/in/nasserfarhat that open in the browser)
- Check for Updates… (only in builds with the Sparkle trait, `MAGNIFE_SPARKLE=1`; absent in the default build; disabled until Info.plist has a real feed and key; no keyboard shortcut, like Apple's apps)
- —
- Settings… ⌘,
- —
- Services ▸
- —
- Hide Magnife ⌘H · Hide Others ⌥⌘H · Show All
- —
- Quit Magnife ⌘Q

**File**
- Save Filter… ⌘S (asks for a name; reads "Save Filter" and saves at once when an edited saved filter is selected)
- Save Filter As… ⇧⌘S (only while a saved filter is selected)
- Rename Filter… (selected saved filter)
- Delete Filter ⌘⌫ (selected saved filter; enabled only while the sidebar has focus, so ⌘⌫ still edits text fields)
- Import Traces… ⇧⌘I (OTLP JSON files; also by dropping files on the window) · Export Trace… ⇧⌘E (the selected trace, S-033)
- —
- Close Window ⌘W

**Edit**
- Undo ⌘Z · Redo ⇧⌘Z (named: "Undo Delete Filter", "Undo Rename Filter", "Undo Clear Filters")
- —
- Cut ⌘X · Copy ⌘C · Paste ⌘V · Select All ⌘A
- —
- Copy Trace ID
- Copy Span ID
- Copy Stack Trace
- Copy Body
- Copy Environment Variables ⇧⌘C
- —
- Search… ⌘K
- —
- AutoFill, Start Dictation, Emoji & Symbols (system)

⌘C copies what has focus: selected text; else the trace ID of the selected trace row; the span ID of the selected waterfall row; the body of the selected log row.

**View**
- Traces ⌘1
- Logs ⌘2
- —
- Show Filter Bar ⌘F (reads "Hide Filter Bar" while shown)
- Clear Filters
- —
- Show Span Detail ⌃⌘I (reads "Hide Span Detail"; Traces view)
- Span ⌥⌘1
- Trace Logs ⌥⌘2
- —
- Show Sidebar ⌃⌘S (system)
- Enter Full Screen ⌃⌘F (system)

**Trace**
- Pause ⌃⌘P (reads "Resume")
- Show Newest Traces (enabled while the "new traces" button shows)
- —
- Open Trace ⌘O (the selected log's trace, from the Logs view or Trace Logs)
- —
- Expand All Spans ⌥⌘→
- Collapse All Spans ⌥⌘←

**Window**
- Minimize ⌘M · Zoom · tiling items (system)
- —
- Magnife ⌘0 (the main window; reopens it when closed)
- —
- Bring All to Front

**Help**
- Search field (system)
- Show Environment Variables (opens the toolbar popover)

The default "Magnife Help" item is removed; there is no help book in v0.1.

### Context menus

| Where | Items |
| --- | --- |
| Trace row | Copy Trace ID, —, Export Trace… |
| Waterfall row | Copy Span ID, —, Expand All Spans, Collapse All Spans |
| Log row (Logs view, Trace Logs) | Open Trace, Copy Body, Copy Trace ID |
| Saved filter row | Rename Filter…, Delete Filter |

### Menu bar extra

`MenuBarExtra` with `.menu` style (platform decision 8).

- Icon: a monochrome template Magnife glyph. When at least one trace with an error arrived since the menu was last opened, a non-template red version of the glyph with the count drawn next to it ("3", "99+" above 99). Opening the menu resets the count and the icon.
- Menu, top to bottom:
  1. Receiver status line, disabled: "Receiving on 4317 and 4318" (same words as the toolbar).
  2. —
  3. Section "Recent Errors": the last five traces with errors, newest first, each "POST /orders · checkout-api · 2 min ago". None: disabled "No traces with errors".
  4. —
  5. Open Magnife · Pause (or Resume) · Copy Environment Variables
  6. —
  7. Settings… · Quit Magnife
- Settings > General can hide it ("Show Magnife in the menu bar", on by default).

### Settings

A `Settings` scene, 480 pt wide, three tabs:

- **General** (`gearshape`): "Keep traces and logs for" pop-up (1 hour, 6 hours, 24 hours, 3 days, 7 days; default 24 hours) with "Older traces and logs are deleted automatically." under it; "Database size" with the size ("182 MB") and a "Show in Finder" button; "Show Magnife in the menu bar" toggle.
- **Notifications** (`bell`): "Notify me when a trace has an error" toggle (on), plus a status line (S-028).
- **Appearance** (`paintpalette`): "Accent color" swatches (System first, the default) with the chosen color's name under them and a small preview window drawn in it (decision 18). Light and dark mode always follow the Mac.

### Notifications

Native `UNUserNotificationCenter` banners (platform decision 9). Permission is asked when the first trace with an error arrives, never at launch. One thread per root service. Details in S-028.

### App-wide states

| State | Look and words |
| --- | --- |
| Launch | Last view, scope, filters and selected trace restored; rows from the database at once, no spinner; Pause is always off at launch |
| Receiver starting over 0.5 s | Toolbar status "Starting receiver…" |
| Helper `error` line | Banner above the list: "The receiver reported a problem: <message>" with "Try Again" |
| Database schema unknown | Banner: "This database has schema version <found>, and this version of Magnife reads version <expected>. Update Magnife." (`StoreError.unsupportedVersion`) No rows shown |
| Busy port, helper restart | S-001, S-002, S-008 banners, unchanged |

### Colors

- Follows the system appearance for light and dark; the only in-app appearance setting is the accent color (Settings > Appearance), which follows the system accent by default and colors selection and controls.
- Error is system red with the octagon icon and the word. Findings are system orange with their icon and kind name. Neither color is a service color.
- Services take colors from a fixed 10-color palette (system blue, green, purple, teal, pink, indigo, brown, mint, cyan, yellow), assigned in order of `services.first_seen_ns`, so a service keeps its color across launches (design decision 4). The 11th service takes the 1st color again (the palette repeats in the same order), so two services can share a color; the name always shows beside the dot, which is never the only way to tell services apart (research/design.md, 10+ services).

## 2. Keyboard map

Menu shortcuts work anywhere in the main window unless focus is in a text field and the key edits text there.

| Key | Action | Where |
| --- | --- | --- |
| ⌘1 / ⌘2 | Traces / Logs | Window |
| ⌘K | Search | Window |
| ⌘F | Show or hide the filter bar of the current view | Window |
| ⇧⌘C | Copy Environment Variables (last chosen language) | Window, empty state |
| ⌃⌘P | Pause / Resume | Window |
| ⌘S / ⇧⌘S | Save Filter… / Save Filter As… | Traces view |
| ⌃⌘I | Show or hide the span detail | Traces view |
| ⌥⌘1 / ⌥⌘2 | Span / Trace Logs in the span detail | Traces view |
| ⌥⌘→ / ⌥⌘← | Expand All Spans / Collapse All Spans | Trace open |
| ⌘O | Open Trace | Log selected |
| ⌘C | Copy the focused item (text, trace ID, span ID, log body) | Everywhere |
| ⌘⌫ | Delete Filter | Sidebar, saved filter selected |
| ⇧⌘I / ⇧⌘E | Import Traces… / Export Trace… | Anywhere / a trace selected |
| ⌘0 | Show the main window | App |
| ⌘, | Settings | App |
| ⌘W, ⌘M, ⌘H, ⌥⌘H, ⌘Q, ⌘Z, ⇧⌘Z, ⌃⌘S, ⌃⌘F | System meanings | App |
| Tab / ⇧Tab | Next / previous column: sidebar → filter bar (when shown) → list → waterfall → span detail | Window |
| ↑ ↓ | Move the selection | Sidebar, trace list, waterfall, log lists, Search results |
| Page Up / Page Down | Move one page | Lists |
| Home or ⌘↑ / End or ⌘↓ | Select the newest / oldest row | Trace list, Logs |
| → or Return | Move focus to the waterfall, root span selected | Trace list |
| ← | Collapse the span, or select its parent | Waterfall |
| → | Expand the span, or select its first child | Waterfall |
| ⌥← / ⌥→ | Collapse / expand the span and all its descendants | Waterfall |
| Return | Open the span detail on Span and move focus into it | Waterfall |
| Space | Show or hide the span detail, focus stays | Trace list, waterfall |
| Return | Select the log's span in the waterfall and focus it | Trace Logs |
| Return | Open Trace | Logs view |
| Return | Rename the saved filter | Sidebar |
| Return / ⌘Return | Open the result / Apply as Filter | Search |
| Space or ⌘-click | Turn one status or level chip on or off without changing the others | Filter bar |
| Esc | Close the top-most thing, in this order: Search; a sheet or inline rename (cancels); the filter bar (filters stay on); span detail focus back to the waterfall; waterfall focus back to the trace list | Window |

Not used, because macOS or standard apps own them: ⌘P and ⇧⌘P (Print, Page Setup), ⌘Space and ⌃Space (Spotlight, input source), ⌃⌘Space (Emoji & Symbols), ⌃⌘Q (Lock Screen), ⇧⌘3/4/5 (screenshots), ⌥⌘D (Dock), ⌘` (cycle windows), ⌥⌘C (Copy Style). ⇧⌘C is Show Colors only in apps with a Format menu, which Magnife does not have. ⌘O keeps its standard meaning, open the selected item, as in Finder.

## 3. Search tokens

One query language for Search, the filter bar and saved filters. A saved filter stores its query in this form.

| Token | Means | Filter bar equivalent |
| --- | --- | --- |
| `service:checkout-api` | Scope to that service | Service pop-up (and sidebar) |
| `status:error`, `status:ok`, `status:unset` | Trace status, case-insensitive | Status chip |
| `route:/orders` | Route contains the text | Condition "Route contains /orders" |
| `>200ms`, `>1.5s`, `>200` (ms) | Slower than | "Slower than" field |
| `key=value`, `key!=value`, `key~value` | Attribute is, is not, contains | Condition row |
| `has:key` | Attribute exists | Condition "key exists" |
| `"_dd.p.tid"=abc`, `has:"my key"` | A key that is not letters, digits, `.`, `_` and `-` from a letter (or is `route`) is quoted, with any operator above | Condition row |
| any other word or `"quoted text"` | Any field contains it: service, route, trace ID, attribute values | Condition "Any Field contains" |

Tokens combine with AND. Values with spaces use quotes: `route:"GET /items/{id}"`.

## 4. UX blocks, S-009 to S-032

### S-009 Filter traces by service from the sidebar
UX:
- Flow: spans arrive -> the service appears in the sidebar in alphabetical place with its color dot -> click it, or press ↑↓ in the sidebar -> the list shows traces with a span from that service, title becomes the service name -> click All Services to go back
- Surface: sidebar page (a place people come back to); the selection is the scope for both views
- States: no services yet shows only All Services; a service with no errors shows no count; too much: names truncate at the tail with the full name in a tooltip, the list scrolls when there are 50 services; service scope with no traces "No Traces from orders" and "Traces with a span from orders appear here."
- Words: "All Services", section "Services", count tooltip "12 traces with errors", empty "No Traces from orders"
- Access: VoiceOver reads "checkout-api, 12 traces with errors" or "web, no errors"; the count pairs the octagon icon with the number; the color dot is decoration and is hidden from VoiceOver

### S-010 Pause the live list while I investigate
UX:
- Flow: click Pause, press ⌃⌘P, or choose Trace > Pause or Pause in the menu bar extra -> the trace list, Logs list and open waterfall hold still; a bar at the top of the list counts arrivals -> click Resume in the bar or toolbar, or press ⌃⌘P -> new rows are inserted at the top, the selected trace stays selected and in view
- Surface: inline bar pinned to the top of the list (information next to where it matters), toolbar button state; no sheet or alert
- States: paused bar "Paused. 12 new traces. Magnife is still receiving." with "Resume"; zero arrivals "Paused. Magnife is still receiving."; the sidebar counts, menu bar extra and notifications keep updating; changing filters while paused re-queries up to the pause point and the count follows the filters; not paused but scrolled away from the top, a floating button "12 new traces" with an up arrow shows at the top of the list instead (design decision 6) and clicking it scrolls to the top; Pause resets at launch
- Words: "Pause", "Resume", "Paused. 12 new traces. Magnife is still receiving.", "12 new traces" (inflected: "1 new trace"), "Show Newest Traces", subtitle prefix "Paused · "; tooltips in the toolbar table
- Access: VoiceOver announces "Paused" and "Resumed"; the bar is read as one element with its Resume button; the new-traces button reads "12 new traces, button" with hint "Shows them at the top of the list"; pausing never depends on color

### S-011 See the logs for the selected span
UX:
- Flow: select a span -> the span detail's Span tab lists its logs in the last section, oldest first -> click a log's disclosure triangle to show its attributes -> ⌘C copies the selected log's body
- Surface: the Logs section at the bottom of the S-006 span detail (part of the same inspector, design decision 5 order: Findings, Exception, Attributes, Events, Resource, Logs)
- States: no logs means no section (S-006 rule); over 50 logs shows the first 50 and "Show All (312)"; bodies show three lines, then "Show All"; logs arriving while the span is open join in time order unless paused
- Words: header "Logs", row "14:02:31.204  ERROR  Payment declined for order 1182", "Show All (312)", "Show Less"
- Access: each log reads "14:02:31, ERROR, Payment declined for order 1182"; the disclosure triangle reads "Show attributes"; the section is a heading

### S-012 See all logs for a trace
UX:
- Flow: open a trace -> pick Trace Logs at the top of the span detail, or press ⌥⌘2 -> every log of the trace in time order -> select a log, or press Return on it, and its span is selected and scrolled into view in the waterfall (collapsed parents expand) -> the pane stays on Trace Logs; ⌥⌘1 goes back to Span
- Surface: second tab of the span detail (inspector for the open trace while the waterfall stays visible)
- States: none "No Logs for This Trace" and "Logs that carry this trace ID appear here."; a log with no span ID shows "—" in the Span column and selecting it leaves the waterfall alone; a span ID not in the trace shows "Span not received"; too much: 10,000 logs scroll smoothly, bodies truncate at the tail with a tooltip; pane header "24 logs"
- Words: tab "Trace Logs", columns "Time", "Level", "Service", "Span", "Body", "Span not received", empty "No Logs for This Trace"
- Access: rows read "14:02:31, ERROR, orders, span charge-card, Payment declined"; selecting announces nothing extra, the waterfall selection is the feedback; the picker is reachable with Tab and ⌥⌘1 / ⌥⌘2

### S-013 Browse all logs in the Logs tab
UX:
- Flow: click Logs or press ⌘2 -> every log in scope, newest first, live -> select a log to read it in the detail column -> double-click, Return, ⌘O, the row's arrow button or Open Trace in the log detail -> Traces view with that trace open and the log's span selected (or the root span when it has none)
- Surface: the content column becomes the log list and the detail column the log detail (same window, design decision for Traces vs Logs); live list holds still when scrolled away, same "12 new logs" button and Pause as S-010
- States: empty "No Logs Yet" with "Logs your apps send over OTLP appear here." and "Copy Environment Variables"; no selection "No Log Selected. Select a log to see its attributes."; a log with no trace ID shows no arrow and no Trace section; a trace ID with no stored spans disables Open Trace with tooltip "Magnife has no spans for this trace"; too much: 100,000 logs scroll smoothly, bodies are one line in the list and full in the detail
- Words: columns "Time" (14:02:31.204), "Level", "Service", "Body"; arrow tooltip "Open this log's trace (⌘O)"; log detail sections "Body", "Attributes", "Resource", "Trace" with "Trace ID", "Span ID" and button "Open Trace"; "12 new logs"
- Access: rows read "14:02:31, ERROR, checkout-api, Payment declined, has trace"; Open Trace has a visible label in the detail; body text is selectable monospace

### S-014 Filter the Logs tab by level and service
UX:
- Flow: in Logs press ⌘F or click Filter -> filter bar: Service pop-up, level chips, "Body contains" field -> click ERROR to show only errors, ⌘-click WARN to add it, pick a service -> list updates as you change them -> Clear Filters resets all three at once -> Esc hides the bar, filters stay on and the Filter button stays filled
- Surface: filter bar above the log list (inline, changes values on screen; design decision 1 shape)
- States: no chip on means every level, including logs with no severity; filtered empty "No Matching Logs" with "No logs match these filters." and "Clear Filters"; the Service pop-up and the sidebar are one setting, choosing in either changes both
- Words: "All Services", chips "TRACE", "DEBUG", "INFO", "WARN", "ERROR", "FATAL" (chip tooltip "Show only ERROR logs, ERROR to ERROR4"), label "Body contains", "Clear Filters"; ranges TRACE 1–4, DEBUG 5–8, INFO 9–12, WARN 13–16, ERROR 17–20, FATAL 21–24; severity 0 shows "—" with tooltip "No level set"
- Access: chips are toggle buttons that read "ERROR, on"; Space toggles the focused chip; Clear Filters is reachable with Tab; level is a word, never only a color

### S-015 Prune old data automatically
UX:
- Flow: nothing to do; the helper deletes traces, spans and logs older than the kept period -> rows leave the bottom of the lists without animation
- Surface: none (no action needed, so no message)
- States: first launch keeps 24 hours; the selected trace pruned -> detail shows "Trace No Longer Stored" and "Magnife keeps traces and logs for 24 hours." with "Open Settings"; a paused list may still show pruned rows, which open to the same state; the sidebar counts drop with the data
- Words: "Trace No Longer Stored", "Magnife keeps traces and logs for 24 hours.", "Open Settings"
- Access: the state is a normal content view VoiceOver reads in order; no announcement for pruning

### S-016 Change the retention period
UX:
- Flow: Magnife > Settings… (⌘,) -> General -> pick from "Keep traces and logs for" -> a longer period applies at once -> a shorter one asks first -> Delete prunes now, the list and "Database size" update; Cancel restores the previous choice
- Surface: Settings tab (a setting people rarely change); confirmation dialog only when shortening (destroys data, cannot be undone)
- States: database size shows at once from the file sizes (database plus WAL), updates after each pruning; dialog "Delete Data Older Than 1 Hour?" with "Traces and logs older than 1 hour are deleted now. You can't undo this action." and buttons "Delete" (default, not destructive-styled: people chose it) and "Cancel"
- Words: "Keep traces and logs for", choices "1 hour", "6 hours", "24 hours", "3 days", "7 days", "Older traces and logs are deleted automatically.", "Database size", "182 MB", "Show in Finder", the dialog above
- Access: pop-up and button have visible labels; Return confirms and Esc cancels the dialog; VoiceOver reads "Database size, 182 megabytes"

### S-017 Search traces with Cmd+K
UX:
- Flow: press ⌘K, click Search, or choose Edit > Search… -> a search box drops over the top of the window with focus in the field -> type; tokens turn into chips, results update on every keystroke -> ↑↓ pick a result -> Return opens it (closes Search, Traces view, trace in the detail column; selected in the list when the list can show it) or ⌘Return applies the query as filters (filter bar opens) -> Esc or a click outside closes with nothing changed
- Surface: a floating search panel over the main window, Xcode Open Quickly style (a short task that closes as soon as it is done; no sheet, the window stays visible)
- States: empty field lists the 10 newest traces under "Newest Traces" and the hint line; results show the 50 newest matches under "Matching Traces" with the total ("50 of 312"); a 32-character or 8-plus hex trace ID puts that trace first; nothing found "No traces match “paymnt”." with "Try fewer words, or check the service name."; an unfinished token (`status:`) shows the allowed values as suggestions; results appear within 100 ms
- Words: placeholder "Search traces: service:, status:, route:, >200ms or any text", result row as the list row ("POST /orders · checkout-api · 240 ms · Error · 2 min ago"), footer "↩ Open   ⌘↩ Apply as Filter   esc Close", "Newest Traces", "Matching Traces", "Apply as Filter"
- Access: the field is labeled "Search traces"; VoiceOver reads result rows like list rows and announces "12 results" after typing pauses; everything works without the mouse; token chips read "Filter: status is Error"

### S-018 Filter traces by status
UX:
- Flow: ⌘F or the Filter button -> filter bar shows over the list -> click Error to show only traces with errors (⌘-click OK to add it; click the only active chip again to turn it off) -> list and subtitle count update -> Esc hides the bar, the filter stays on and the Filter button stays filled
- Surface: filter bar above the trace list (inline control that changes what is on screen; design decision 1)
- States: no chip on means every status; filtered empty "No Matching Traces" with "No traces match these filters." and "Clear Filters"; a selected trace hidden by a filter stays in the detail column
- Words: chips "Error", "OK", "Unset"; tooltips "Show traces with at least one Error span", "Show traces with no Error span and an OK root span", "Show traces with no Error span and an Unset or missing root span"; "Clear Filters", "No Matching Traces"
- Access: chips are toggle buttons ("Error, on"); the Error chip carries the octagon icon as well as the word; Space toggles the focused chip

### S-019 Filter traces by minimum duration
UX:
- Flow: filter bar -> type in "Slower than" (200, 200ms, >200ms or 1.5s) -> the list updates 100 ms after the last keystroke -> clear the field to remove the rule
- Surface: field in the first line of the filter bar, after the status chips (inline)
- States: placeholder "200 ms"; text that does not parse gets a red outline and "Type a duration, like 200 ms or 1.5 s" beside the field, the list keeps the last valid rule; a valid value shows normalized after focus leaves ("1.5 s")
- Words: label "Slower than", placeholder "200 ms", error "Type a duration, like 200 ms or 1.5 s"
- Access: the field has a visible label; VoiceOver reads "Slower than, 200 milliseconds, text field" and the error as the field's value hint

### S-020 Filter traces by any attribute
UX:
- Flow: filter bar -> in the condition row type a key; suggestions from received attribute keys list as you type -> ↓ and Return pick one -> pick an operator -> type a value -> list updates 100 ms after the last keystroke -> "+" adds a row below, "−" removes one (on the only row, it clears it)
- Surface: condition rows in the filter bar, under the first line (inline, Proxyman and TablePlus shape)
- States: one empty row shows when the bar opens; empty-key rows are ignored; at most 10 rows, then "+" is disabled with tooltip "Up to 10 conditions"; "exists" hides the value field; ">" and "<" accept numbers only, other text gets "Type a number" beside the field; all rows must match (AND); suggestions show the key and its source ("http.route — span", "host.name — resource"), 20 at most; a key never received still works
- Words: key placeholder "Attribute", built-in keys "Any Field" and "Route" at the top of the suggestions, operators "is", "is not", "contains", "exists", ">", "<", value placeholder "Value", buttons "+" (tooltip "Add a condition") and "−" (tooltip "Remove this condition")
- Access: each row reads "Condition 1: http.route is /orders"; "+" and "−" have VoiceOver labels "Add Condition" and "Remove Condition"; Tab moves key -> operator -> value -> − -> +

### S-021 Save the current filters to the sidebar
UX:
- Flow: with filters on, File > Save Filter… (⌘S) or "Save Filter…" in the filter bar -> sheet "Save Filter" with Name -> Return saves -> the filter appears under Saved Filters, selected -> click it later to restore its scope and filters (Traces view) -> change a filter while it is selected and the title reads "Checkout errors — Edited"; ⌘S updates it, ⇧⌘S saves a new one -> rename: context menu Rename Filter…, or Return on the row, edits the name in place -> delete: Delete Filter or ⌘⌫, no confirmation, Edit > Undo Delete Filter brings it back
- Surface: sheet for naming (one short task to finish or cancel); inline rename in the sidebar (changes one value on screen); sidebar page for the saved filter (a place people come back to)
- States: Save Filter… disabled while no filter is on; sheet shows the query under the field in monospace ("service:checkout-api status:error"); empty name disables Save; a duplicate name shows "A saved filter named “Checkout errors” already exists." under the field; Saved Filters section hidden while empty; long names truncate with a tooltip; seed data has "Checkout errors" (`service:checkout-api status:error`)
- Words: sheet title "Save Filter", label "Name", placeholder "Checkout errors", buttons "Cancel" and "Save"; "Save Filter…" (menu and filter bar), "Save Filter As…", "Rename Filter…", "Delete Filter", "Edited", "Undo Delete Filter", "Undo Rename Filter"
- Access: Return saves and Esc cancels in the sheet and in rename; VoiceOver reads a row as "Checkout errors, saved filter"; delete and rename are in the context menu and the File menu, not only on hover

### S-022 Move through traces and spans with the keyboard
UX:
- Flow: Tab into the trace list -> ↑↓ select traces, the waterfall follows -> → or Return moves into the waterfall on the root span -> ↑↓ move between spans, ← and → collapse and expand, ⌥← and ⌥→ do a whole subtree -> Return opens the span detail and focuses it, Space shows or hides it without moving focus -> Esc steps back: span detail -> waterfall -> trace list; ⌘F opens the filter bar and Esc closes it
- Surface: no new surface; the keyboard map in section 2 applies to every column
- States: focus is always visible (system focus ring on the focused column, selection in the accent color); collapsing a subtree that holds the selected span selects the collapsed span; keys on an empty list do nothing
- Words: every menu item listed in section 1, with its shortcut shown in the menu
- Access: the whole flow works with Full Keyboard Access and VoiceOver; the waterfall is an outline VoiceOver reads with "expanded" and "collapsed" and the level ("level 3"); each column is a labeled group ("Sidebar", "Traces", "Waterfall", "Span Detail")

### S-023 See slow SQL queries flagged
UX:
- Flow: a trace arrives with a database span over 100 ms -> its row shows a "Slow SQL" badge -> open it: the findings strip under the waterfall header lists it, the span shows the finding icon -> click the strip line to select the span -> the span detail opens with Findings first
- Surface: badge in the Route cell of the list row; strip under the waterfall header; Findings section at the top of the span detail (all inline on views already on screen)
- Where (all three findings, detector audit 7, PROGRESS decisions 185 and 186): every finding says what is wrong and where: the service ("in checkout-api"; two read "checkout-api and orders", three or more "3 services"), the route or span name it sits under ("under GET /reports/sales": Slow SQL the nearest server or consumer span above it, else the root's name; N+1 the lowest span above all its runs; each span is named by its route the helper's way, "<method> <http.route>" when it has a route, else its name, so a server span named "GET" with `http.route` reads "GET /v1/orders/{id}"; a span named only for its method with no route, like "GET", is skipped for the one above), and for Slow SQL and N+1 its share of the trace ("96% of the trace's 884 ms", left out at 0% and when the finding took longer than the trace, from runs at the same time or clock skew; PROGRESS decisions 187 to 193). The word "endpoint" is never written: "in <service>, under <route>" says it (docs/GLOSSARY.md, Route). The places come from the waterfall, so the strip and span detail say them once the trace is open; the list's badges name services only
- States: rule: span with `db_system` and duration over 100 ms; several slow queries show one badge and one strip line each; strip shows 3 lines, then "Show All Findings (7)"; the strip line leaves out "under …" when it is the waterfall header's route and service (the span detail keeps it); the statement is monospace, 3 lines, then "Show All"; no statement: "This postgresql query took 330 ms in checkout-api, …"; a query with status Error adds "The span has status Error: context deadline exceeded."; just over: a query over 100 ms that rounds to "100 ms" reads "just over 100 ms" in the strip line, the span detail, the tooltips and the row ("Slow SQL: just over 100 ms"), "just over 100 milliseconds" for VoiceOver, never "took 100 ms. Queries over 100 ms are flagged."; a span whose parents never arrived names no "under"; a trace still receiving spans gains badges in place
- Words: badge "Slow SQL" (icon `cylinder`, tooltip "Slow SQL: 1 query over 100 ms, 851 ms in checkout-api", or "Slow SQL: 3 queries over 100 ms, the slowest 330 ms in checkout-api"); strip line, what, cost, which query, where, then the statement, since the tail is cut: "Slow SQL · 851 ms · SELECT Orders · checkout-api · GET /reports/sales · SELECT date_trunc('day', …" (the span's name is left out when the statement starts with it: "Slow SQL · 2.00 s · orders · UPDATE inventory SET …"); its tooltip is the span detail's text; span detail header "Findings", title "Slow SQL", text "This query took 851 ms in checkout-api, under GET /reports/sales: 96% of the trace's 884 ms. Queries over 100 ms are flagged.", then the statement; waterfall row tooltip adds "Slow SQL: 851 ms, over 100 ms"
- Access: the badge pairs icon and words in orange, never color alone; at the default list width (Route about 98 pt) a badge shows its icon alone, so the route keeps its room, and the word shows as soon as the whole route fits beside it (a wider list column); the tooltip and VoiceOver always carry the words (PROGRESS decision 134, M3 review); the list row reads "…, findings: Slow SQL" ("findings: 3 Slow SQL" with three, "findings: Slow SQL, N+1"); the waterfall row adds "Slow SQL, over 100 milliseconds"; strip lines are buttons: "Slow SQL, 851 milliseconds, SELECT Orders in checkout-api, under GET /reports/sales" (", status Error" when it failed); VoiceOver's help is the tooltip's text, the span detail's words (no hint: on macOS a hint replaces the help, PROGRESS decision 191)

### S-024 See N+1 queries flagged
UX:
- Flow: a trace runs the same normalized statement 5 or more times -> "N+1" badge on the row -> open it: one strip line names the count, the total, where and the statement, every repeated span shows the N+1 icon -> click the line to select the first of those spans
- Surface: same three places as S-023; where as S-023
- States: rule: same normalized `db_statement` (literals replaced with `?`) 5 or more times in one trace gives one finding for all those spans, whatever their parents and services; a span can carry Slow SQL and N+1 at once (both icons, both sections, and the row's tooltip says both: "Slow SQL: 120 ms, over 100 ms · N+1: run 3 of 6, 138 ms in all"); two different repeated statements give two strip lines; runs of one length read "Each run took 7.2 ms.", else "The runs took 3.1 ms to 9.8 ms."; counts in finding words, and every other count on screen (the Spans column, the waterfall header, subtitles), group with "," whatever the Mac's region ("1,200 times", "1,201 spans", "Show All Findings (1,200)"), like durations, whose decimal mark is always "." (PROGRESS decision 192)
- Words: badge "N+1" (icon `repeat`, tooltip "N+1: a statement ran 8 times in orders, 58 ms in all", or "N+1: 2 statements ran 5 or more times, the most 6 times in checkout-api"); strip line "N+1 · 8 times, 58 ms in all · SELECT order_items · orders · GET /v1/orders · SELECT * FROM order_items WHERE order_id = ?"; span detail title "N+1", text "This statement ran 8 times in orders, under GET /v1/orders, 58 ms in all: 60% of the trace's 96 ms. Each run took 7.2 ms. Statements that run 5 or more times in one trace are flagged.", then the normalized statement; waterfall row tooltip "N+1: run 1 of 8, 58 ms in all"
- Access: as S-023; the strip line reads "N+1, SELECT order_items ran 8 times, 58 milliseconds in all, in orders, under GET /v1/orders"; the waterfall row adds "N+1, run 1 of 8"

### S-025 See failed HTTP calls flagged
UX:
- Flow: an HTTP span returns 400 or higher, or has status Error -> "HTTP Error" badge on the row -> open it: one strip line per span with the code, the duration, who called whom, and the method with URL or route -> click to select the span
- Surface: same three places as S-023
- States: rule: span with `http_method` or `http_status_code`, and a code of 400 or higher or status Error, one finding per span (a failed call through two services is three lines: the caller's server span, its client span, the callee's server span); client spans show the URL, server spans the route, else the span name alone, with no method before it (an empty URL or route counts as none); a client names its own service and the one that answered ("web → checkout-api", and "checkout-api answered as POST /payments."); a server called by another service says "to web"; the first span under it that failed on its own follows ("Under it, INSERT Payments in checkout-api has status Error: …"), left out when it is the service that answered; no code: "got no response code in 30.0 s. The span has status Error: …"; a code under 400 with status Error: "returned 200 after 40 ms, but the span has status Error: …"; those two end with the rule "Responses of 400 or higher, and spans with status Error, are flagged."; status messages are one line of at most 300 characters and end with "."
- Words: badge "HTTP Error" (icon `network`, tooltip "HTTP Error: 3 calls returned 500, in web and checkout-api", "HTTP Error: 4 calls returned 400 or 404, in web and checkout-api", "HTTP Error: 2 calls returned 502 or had status Error, in checkout-api", "HTTP Error: 4 calls returned 404 or 500, or had status Error, in web"); strip line "HTTP Error · 500 · 57 ms · web → checkout-api · POST /payments" (a client's URL without its scheme, and without its host when the service that answered is named before it; the span detail keeps the whole URL), or "HTTP Error · no response code · 30.0 s · checkout-api · POST api.stripe.com/v1/refunds"; span detail title "HTTP Error", text "web called POST http://localhost:5080/payments and got 500 after 57 ms. checkout-api answered as POST /payments. Under it, INSERT Payments in checkout-api has status Error: 23505: duplicate key value violates unique constraint "IX_Payments_OrderId"." or "POST /payments in checkout-api returned 500 to web after 52 ms. …"; waterfall row tooltip "HTTP Error: 500", "HTTP Error: no response code, status Error", "HTTP Error: 200, status Error"
- Access: as S-023; the code is read as a number; the strip line reads the outcome without the message ("HTTP Error, web called POST http://localhost:5080/payments and got 500 after 57 milliseconds"; ", status Error" when there is no code); the waterfall row adds "HTTP Error, 500" ("HTTP Error, no response code", "HTTP Error, 200, status Error")

### S-026 See recent errors in the menu bar
UX:
- Flow: a trace with an error arrives -> the menu bar icon turns red with "1", counting up -> click it -> the menu lists the last five traces with errors; the count and the red icon reset
- Surface: menu bar extra, `.menu` style (platform decision 8)
- States: no new errors: monochrome template icon, no count; over 99: "99+"; no traces with errors stored: disabled "No traces with errors"; times are fixed when the menu opens; the receiver line shows the S-001/S-002 status words
- Words: "Recent Errors", item "POST /orders · checkout-api · 2 min ago", "No traces with errors", "Open Magnife", "Pause" / "Resume", "Copy Environment Variables", "Settings…", "Quit Magnife"
- Access: VoiceOver reads the icon as "Magnife, 3 new traces with errors" or "Magnife"; the red state always carries the count, not color alone; the menu is a native NSMenu, so arrows and Return work

### S-027 Open a failed trace from the menu bar
UX:
- Flow: click a trace in Recent Errors -> the main window comes forward (opened if closed) on the Traces view -> the trace is in the detail column, its earliest-starting Error span selected, span detail on Span with the Exception section in view
- Surface: the main window's detail column (the same Open Trace route as Search, logs and notifications)
- States: the list selects and scrolls to the trace when its scope, filters and pause allow it; otherwise the list keeps its state and shows no selection, the detail still shows the trace; a trace pruned since the menu opened shows "Trace No Longer Stored" (S-015)
- Words: no new words
- Access: focus lands in the waterfall on the Error span; VoiceOver reads that span's row

### S-028 Get notified when a trace fails
UX:
- Flow: the first trace with an error arrives -> macOS asks for permission (no window of our own before it) -> each new trace with an error posts a banner -> click it -> Magnife opens the trace as in S-027, launching first when it was not running
- Surface: native notification (works when Magnife is in the background, the job of the feature), one thread per root service
- States: one trace: banner at once; more traces with errors from the same service within 10 s of that banner: one follow-up replaces it at the end of the 10 s with the count, so Notification Center keeps one per burst; Magnife frontmost still shows banners; permission denied: nothing else changes, Settings > Notifications shows "Notifications for Magnife are off in System Settings." with "Open System Settings"; not yet asked: "Magnife asks for permission when the first trace with an error arrives."; toggle off: nothing posts
- Words: single: title "POST /orders", subtitle "checkout-api", body the first exception's type and message ("InvalidOperationException: Cart is empty") or "Error in span charge-card"; burst: title "3 traces with errors", subtitle "checkout-api", body "Newest: POST /orders"; clicking a burst opens its newest trace; Settings "Notify me when a trace has an error"
- Access: the system reads notifications; the Settings toggle and button have visible labels

### S-029 Open in under a second
UX:
- Flow: click the Dock icon -> the window appears with the last view, scope, filters and selected trace, rows read from the database -> the receiver status appears when the helper reports its ports
- Surface: the main window as it was (no splash, no loading screen)
- States: no spinner at any point; "Starting receiver…" only after 0.5 s; a stored selected trace that was pruned shows S-015's state; first run shows S-003's empty state
- Words: no new words
- Access: focus starts in the trace list on the selected row (or the first row)

### S-030 Stay responsive under heavy load
UX:
- Flow: an app floods Magnife -> the list inserts new rows in batches at most every 250 ms -> scrolling, selecting and typing keep working; while you scroll, inserts wait and the "new traces" button counts them
- Surface: no new surface
- States: the list pages from the database, 200 rows at a time; an open waterfall that is still receiving spans redraws at most every 500 ms and never moves the selected span; traces over 500 spans open with deep subtrees collapsed (S-005); counts in the subtitle and sidebar refresh at most once a second
- Words: no new words
- Access: no VoiceOver announcements for arriving rows (they would never stop); Reduce Motion turns off row insert animation, which is off under load anyway

### S-031 Use Magnife in dark mode
UX:
- Flow: change the Mac's appearance -> Magnife follows at once, no relaunch
- Surface: every view; light and dark follow the system setting (the one place); Settings > Appearance only picks the accent color
- States: light, dark, and each with Increase Contrast (waterfall bars get a 1 pt border, service dots a ring); status red, finding orange and all 10 service colors keep at least 4.5:1 for text and 3:1 for bars against the background in both modes; every snapshot page has a dark version
- Words: no new words
- Access: color never carries meaning alone (octagon for Error, icons and words for findings, level words); Reduce Transparency gives the Search panel and banners a solid background

### S-032 Recognize Magnife by its icon
UX:
- Flow: install -> find Magnife in the Dock, Finder and Launchpad by its icon and the name under it
- Surface: app icon (Icon Composer, macOS 26 rounded-square grid, layered for Liquid Glass) and the menu bar glyph
- States: the mark is a magnifying glass whose lens holds three stacked, offset bars, a tiny waterfall, on a deep indigo field; at 16 pt the lens and bars still read, with no thin strokes; dark, clear and tinted variants come from the layers; the menu bar glyph is the same lens and bars as one-color line art, template normally, red when S-026 says so
- Words: "Magnife"
- Access: the name always appears next to the icon in Finder and Launchpad; the menu bar glyph has the VoiceOver label in S-026

## 5. Words added to the glossary

Things: Finding, Slow SQL, N+1, HTTP Error, Filters, Filter Bar, Condition, Any Field, Saved Filter, Search, Span Detail, Trace Logs, Log Detail, Level (TRACE, DEBUG, INFO, WARN, ERROR, FATAL), Body, All Services, Traces with errors, Recent Errors, Database size, Edited.

Actions: Pause, Resume, Search…, Show Filter Bar / Hide Filter Bar, Clear Filters, Apply as Filter, Save Filter… / Save Filter As…, Rename Filter…, Delete Filter, Open Trace, Show Newest Traces, Expand All Spans / Collapse All Spans, Show Span Detail / Hide Span Detail, Copy Trace ID, Copy Span ID, Copy Body, Import Traces…, Export Trace…, Show Environment Variables, Open Magnife, Show in Finder, Open Settings, Open System Settings, Delete (retention dialog).

Settings: "Keep traces and logs for", "Database size", "Show Magnife in the menu bar", "Notify me when a trace has an error".

Status lines: "Starting receiver…", "Paused. 12 new traces. Magnife is still receiving.", "12 new traces" / "12 new logs", "Trace No Longer Stored", "No traces with errors".
