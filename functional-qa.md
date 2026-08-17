# Functional QA

## Current regression contract

The current suite protects the complete non-Settings experience requested for this delivery:

1. Native multiline focus, selection, newline insertion, paste, deletion-driven contraction, and
   Return submission.
2. Virtualized 1M-character documents with exact backing content, bottom-first presentation,
   on-demand earlier pages, exact submission, and compact post-submit layout.
3. Delayed, bursty, and character-at-a-time OpenAI-compatible SSE responses.
4. Adaptive stream smoothing, 120 ms glyph fade, 150 ms height reveal, waiting caret, cancellation,
   completion, and error transitions.
5. Submit-time forced auto-follow, growth follow through completion, final-result visibility, and
   deliberate user detachment.
6. One outer history scroll surface for all results, natural-width reflow, long-result sticky copy,
   and exact Pencil history/document thumbs.
7. Record actions hidden at rest, revealed on hover, absent while streaming, and copied-state reset
   after 800 ms.
8. Native `⌘C` precedence for editable input and selected result text, with latest-terminal-result
   fallback otherwise.
9. SQLite history order/content/state persistence, restart recovery of interrupted streams, and
   continued loading around malformed rows.
10. Production startup without design fixtures or mock responses; test data, preferences, Keychain,
    clipboard, endpoint, and history remain isolated from the production namespaces.
11. Standard macOS close, minimize, zoom, resizing, keyboard routing, and responder-chain behavior.
12. Latest-only history focus, two-line folded previews, source omission, independent expansion and
    collapse, full-result copy from folded rows, and continuity across consecutive submissions.
13. Large persisted history upward scrolling with bounded folded previews, no complete-result reads
    in the scroll path, forced follow after detachment, and a 1,000-record frame-pacing workload.
14. Exact extreme workflows for one million persisted rows and one thousand one-million-character
    results, including real submit, uneven streaming, terminal persistence, normal scrolling,
    viewport-per-frame hyper-scrolling, timeout/RSS guards, and phase-specific frame reports.

Settings visual alignment is outside this pass. Its existing model navigation, endpoint/model/API-key
editing, and native close behavior remain in the end-to-end smoke path so this work cannot regress
them.

## Root repairs in this pass

| Area | Confirmed cause | Repair and regression |
| --- | --- | --- |
| Record controls | Controls were not modeled as one hover-owned record state, and result actions could affect text geometry. | Three overlay actions share one record hover policy. Streaming suppresses them. Pure policy tests and XCUI verify rest, hover, copied, reset, and streaming states. |
| Copy shortcut | A global latest-result shortcut could override standard native copy behavior. | The local key monitor first yields to any editable `NSTextView` or non-empty native selection, then copies the newest terminal result while skipping an active stream. Unit and XCUI tests cover both branches. |
| Uneven streaming | Backend arrival timing was visible directly and new characters changed abruptly. | The display-linked presenter remains network-decoupled and releases grapheme-safe batches at 30–400 characters/s with a maximum of eight clusters. New ranges fade from 25% opacity and 2 pt blur over 120 ms ease-out. |
| Streaming frame drops | SwiftUI height animation and every presented delta invalidated the history tree, while per-frame TextKit temporary attributes multiplied main-thread work. | Presentation storage notifies the existing native result view directly, which appends only the missing suffix. Natural layout stays coalesced; a Core Animation mask reveals new line height over 150 ms. A regression proves that streaming deltas do not reconfigure folded history. |
| Result scrolling | A result-owned viewport divided wheel input, follow state, and copy-control positioning. | TextKit reports full natural height into the outer history. Long records get a small transparent scroll runway, and result copy follows the visible intersection without reserving text width. Unit and XCUI tests reject nested scroll views. |
| Long-input scrollbar | Removing an obsolete visual fixture also removed the overflow that made Pencil's 90 pt history thumb real. | A 64 pt transparent lead-in applies only when history contains a long record. It preserves the visible record position while providing real draggable history range; the input retains its 64 pt thumb. |
| Reversed scrollbar | Document normalization used top = 0 and bottom = 1, but the custom indicator kept AppKit's default bottom-origin view coordinates, so the same value painted at the opposite visual end. | The indicator now owns a flipped, top-origin coordinate system. A native regression covers both flipped and non-flipped documents; XCUI compares bottom and older-history screenshots and requires the 90 pt thumb center to move upward with the content. |
| Auto-follow | Entry-count observation did not represent growth inside one streaming result, and submit intent could be coalesced away. | A dedicated force-pin revision, native document-frame notifications, and an unthrottled terminal revision keep the outer history at the bottom through completion without repinning a detached reader. |
| Multiline contraction | A boolean multiline state could not represent the current row count after deletion. | Shared logical/wrapped-line metrics contract through 5-line, 3-line, 2-line, and 27 pt compact states. Real native deletion and XCUI paste/delete flows verify it. |
| Large input | Even after separating the exact backing document from SwiftUI, synchronously materializing a 4,096-unit tail and publishing the final large-document layout metrics could consume an entire 120 Hz interval. | The visible TextKit tail is limited to 512 UTF-16 units and earlier content materializes in 1,024-unit pages. Presentation-only metrics expand through bounded 9 ms stages while the native backing store keeps the exact document and count. Immediate submit cancels every pending stage before clearing the editor; regressions verify exact submission, compact reset, and no delayed re-expansion. |
| History focus | Keeping every prior record fully expanded made repeated submissions expensive and visually noisy. | The newest record stays expanded; older records use a two-line result preview without TextKit, expand independently, and still copy the complete value. Production-shaped unit and XCUI regressions cover two consecutive submissions. |
| Hidden previous focus | During automatic folding, the former latest entry could retain its expanded result subtree even after becoming visually folded, rebuilding expensive text and action views behind the new entry. | The expanded body is retained only until the automatic fold transition actually targets that entry. Hidden source/result actions and hover tracking are not mounted. Consecutive-submission and hover-leak regressions exercise the production-shaped path. |
| Large-history scroll drops | Every folded row rebuilt its preview by bridging the complete result into a Swift `String`, and SwiftUI retained a row graph for the loaded page. | `HistoryResultStorage` maintains a grapheme-safe 420-character preview incrementally. A native viewport recycler materializes only visible rows plus overscan, finds them with binary-search geometry, and never reads complete folded results. Structural regressions exercise a 5,000-row hyper-scroll and reject unbounded materialization. |
| Submit-time history rebuild | AppKit reinstalled an overlay scroller during live scroll. The custom layer then forced legacy layout, alternating the document width between 804 and 787 pt; one append remeasured roughly 5,000 folded rows. | The Pencil layer suppresses every reinstalled system scroller but preserves overlay layout mode. Append-only history updates retain the row pool and height cache and measure exactly one new folded row. |
| Recycled hover actions | A virtualized row could leave the viewport before `mouseExited`, so its hover buttons remained in the recycled view and accessibility tree. | `prepareForReuse()` clears hover state, removes action accessibility children, and hides controls before pooling. Unit and independent XCUI regressions reject stale controls during the next submission. |
| Million-row startup crash | Eagerly loading one million records into one SwiftUI `ForEach` grew AttributeGraph's table until `AG::data::table::grow_region` aborted. The diagnostic run reached about 6.9 GB RSS before exit; this was a view-graph capacity failure, not SQLite or an out-of-memory kill. | Production loads the newest 512 rows and prepends cursor-based pages on demand; isolated stress automation uses 2,000-row pages. The native folded-row recycler keeps the exact million-row workflow bounded; the current available-display run peaks at about 164 MB for the whole process tree. |
| Retry accessibility | The expanded-row header applied its collapse identifier after adding the retry overlay, so SwiftUI exposed the visible retry button under the parent identifier. | The overlay is now added after the header accessibility modifiers, preserving the retry identifier. The focused VM regression and the subsequent unfiltered suite both verify all three hover actions. |
| Background 120 Hz diagnostics | A hidden app on a 60 Hz host inherited the physical 60 Hz clock and could not exercise an 8.33 ms main-actor deadline. Periodic synchronous RSS sampling also contaminated frame intervals. | The non-activating diagnostic clock uses the requested cadence while retaining `displayRequirementSatisfied = false` when no real 120 Hz display is online. RSS is sampled outside the per-tick path. Unit tests distinguish deadline diagnostics from physical display certification. |

## Host verification

`swift test -Xswiftc -warnings-as-errors` passes all 115 tests:

- 43 application-model and performance-report tests;
- 7 SQLite persistence and cursor-pagination tests;
- 61 native interaction/layout regressions;
- 4 loopback OpenAI-compatible streaming integrations.

The native regressions now include system-scroller reinsertion, viewport-bounded folded-row
materialization, recycled-hover cleanup, append-only row measurement, direct TextKit streaming
without folded-history reconfiguration, staged 1M-document presentation, and immediate submission
while those stages are pending. The integrations verify typed operation/language
parameters, exact one-copy source delivery, SSE partial output, completion, cancellation, loopback
authentication policy, Settings-to-request wiring, and detached-history submission through the
production model/service boundary.

## Fresh Tart XCUI verification

The final `scripts/test-ui-in-tart.sh` run used a fresh disposable `cida-ui-golden` clone on macOS
26.4. Before XCUI it independently passed the same 115 Swift tests in six bounded shards and the
optimized Release real-input responder-chain gate. The shard runner enumerates every interaction
test and fails if a new test does not match the maintained execution set; this repaired a
real gap where the staged-long-stream regression had not been selected. The retained
`TestResults/vm-ui/CidaUITests.xcresult` and freshly generated `xcresult-summary.json` report nine
tests passed, zero failed, and zero skipped:

- **Settings, multiline input, and submitted stream:** configures the loopback endpoint, edits the
  model and API key, closes Settings through the native control, grows and deletes multiline input,
  submits after detaching history, and follows through `CIDA_UI_E2E_COMPLETE`.
- **Pencil scroll indicator:** captures the bottom position and the position after scrolling toward
  older records, requires the 90 pt thumb center to move upward, and rejects a second or wider system
  thumb beside the 4 pt design indicator.
- **Independent submit-follow regression:** starts detached, submits through the real endpoint,
  requires an immediate bottom pin and delayed streaming follow, and rejects leaked historical
  hover actions.
- **Production-shaped continuity:** starts with persisted history, submits twice, verifies both
  completed results remain visible, and confirms that the prior focus folds instead of clearing the
  page.
- **History focus and folding:** expands and collapses older records independently and copies the
  complete result from a bounded folded preview.
- **Record actions and copy precedence:** verifies hover-only actions, copied feedback and reset,
  streaming suppression, latest-result `⌘C`, and native selected-text precedence.
- **Sticky long result:** verifies a single outer history scroll surface and keeps the copy control
  attached to the visible result intersection.
- **Expanded action column:** verifies retry and both copy controls stay inside the reserved Pencil
  action column instead of overlapping text or clipping at the window edge.
- **Folded-card geometry:** checks the folded metadata, two-line preview, divider, action geometry,
  and scroll behavior against the current Pencil interaction contract.

Tart ran with graphics, audio, host clipboard sharing, and guest network disabled. The source mount
was read-only, only the result directory was writable, and the disposable clone was deleted after
the run. The golden image remained healthy and stopped, so it was not reinitialized. No host Cida
window was launched or activated.

## Available-display performance evidence

The final probe reports a 60 Hz display maximum. Therefore the final code is verified against the
physical 60 Hz clock, while the 120 Hz background clock is reported separately as a deadline
diagnostic rather than visible-frame certification.

| Focused workload | Samples / interactions | Measured fps | P99 / maximum | Missed | Workload | Host activation / key |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Smooth streaming | 720 / 412 presentation updates | 60.000152 | 16.7082 / 17.8291 ms | 0 | pass | false / false |
| 1M-character paste | 720 / exact 1,000,000 characters | 60.000079 | 16.7033 / 17.5194 ms | 0 | pass | false / false |
| 1,000-row upward scroll | 720 / 23,040 pt | 60.000287 | 16.7648 / 18.4190 ms | 0 | pass | false / false |

The current-code 120 Hz deadline artifacts are retained under
`Performance/final-120hz-deadline-diagnostic`. Smooth streaming, 1M-character paste, and 1,000-row
scroll completed 1,440 samples at 120.0008, 120.0004, and 120.0005 measured ticks/s respectively.
Their P99 values were 8.3755, 8.3737, and 8.4039 ms; maxima were 9.5927, 8.5442, and 11.7212 ms, with
zero missed 12.5 ms budgets. Each report intentionally remains `passed = false` because
`displayRequirementSatisfied = false` on the 60 Hz display.

## Extreme end-to-end performance matrix

The final 60 Hz matrix exercised both exact profiles with 2,400 samples. Each used a unique temporary
app identity, SQLite database, UserDefaults, Keychain namespace, and loopback OpenAI-compatible
endpoint. The verifier observed exactly one streaming request containing the full
1,000,000-character source and a terminal 1,024-character result persisted at the exact final row
count.

| Profile | Seed / final rows | Loaded rows | Load / first render | Operation | Peak process-tree RSS | Normal / hyper scroll | Measured fps | P99 / maximum | Missed | Workflow / frames |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| One million history rows | 1,000,000 / 1,000,001 | 257 | 86.28 / 238.40 ms | 13.67 s | 164,151,296 B | 6,016 / 120,320 pt | 60.000161 | 16.7346 / 20.1406 ms | 0 | pass / pass |
| 1,000 one-million-character results | 1,001 / 1,002 | 34 | 126.95 / 274.51 ms | 13.72 s | 190,332,928 B | 6,016 / 120,216 pt | 60.000132 | 16.9290 / 21.9033 ms | 0 | pass / pass |

Both profiles completed submission, uneven streaming, persistence, normal scrolling,
viewport-per-frame hyper-scrolling, and the completed tail with zero missed budgets in every phase.
Both processes exited normally without timeout, RSS termination, crash, host activation, or a key
probe window.

The single final 120 Hz deadline matrix also completed both workflows and persistence checks, but it
is not green. Both profiles recorded one interval above 12.5 ms at sample 3 while the new streaming
entry became visible: 12.6291 ms for one million history rows and 13.3326 ms for the thousand-record
profile. The physical-display precondition was also false. These are retained failures, not
rerun away or relabeled as passes.

## Result

The 115-test host suite, the independently sharded 115-test guest suite, nine isolated VM journeys,
the Release responder-chain gate, all focused 60 Hz gates, and both exact 60 Hz extreme workflows are
green. The signed Release bundle was built without launching or activating it. Physical 120 Hz
certification remains open, and the final extreme deadline diagnostic preserves one insertion-time
miss per profile for that rerun.
