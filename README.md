# Cida

Cida is a native macOS writing assistant built with Swift 6.2, SwiftUI, and AppKit. It translates text or improves writing through streaming DeepSeek and OpenAI-compatible Chat Completions APIs.

## Requirements

- macOS 15 or newer
- Xcode 26 or a compatible Swift 6.2+ toolchain

## Build and run

```sh
swift run Cida
```

Create a signed Release app bundle without launching it:

```sh
scripts/build-app.sh release
```

The production bundle is written to `build/Cida.app`. It uses a stable Developer ID signature so its Keychain identity survives rebuilds. A fresh production install starts with empty history; design samples and fixed preview responses are compiled only into Debug automation builds. Provider keys are stored only in Keychain; prompts, model IDs, the OpenAI endpoint, and other non-secret preferences are stored in UserDefaults.

Production history is stored in `~/Library/Application Support/com.xuanwo.Cida/History.sqlite3`. The database uses WAL mode, preserves submission order and terminal states, and recovers an interrupted streaming entry as cancelled on the next launch without discarding its partial result. API keys are never written to this database.

When OpenAI is selected, Settings exposes an editable Chat Completions endpoint and model ID. Loopback endpoints such as `http://127.0.0.1:8080/v1/chat/completions` and `http://localhost:8080/v1/chat/completions` may omit the API key. Non-local endpoints still require one.

Prompts are stored as stable task policies rather than string templates. Each request sends the operation and language choices as a typed, trusted parameter envelope in the system message, while the complete source document appears exactly once in the user message. Legacy `{text}` and `{target_lang}` prompts migrate once; braces in current prompts remain literal text.

## Interaction

- `Option-Space`: show Cida from any application
- `Tab`: switch between Translate and Improve
- `Escape`: close the input window
- `Command-,`: open Settings
- `Return`: submit the current text
- `Shift-Return` or `Option-Return`: insert a newline
- `Command-C`: keep native copy for editable input or selected text; otherwise copy the latest completed result
- The submit button becomes a stop button while a response is streaming
- Main and Settings windows use the standard macOS close, minimize, and zoom controls

## Verification

Run a release decision from a clean, committed checkout with one of the unified gates:

```sh
scripts/e2e/run-pr-gate.sh
scripts/e2e/run-nightly-gate.sh
scripts/e2e/run-release-gate.sh
```

Every profile first validates every mutation anchor, then runs the complete Swift suite, builds and
signs one Release app, binds its manifest to the current commit, and verifies the app-tree digest
again after all consumers finish. The PR profile
runs the P0 Release journeys in Tart and the unit mutation contracts. Nightly runs the full Tart suite,
all unit and Release mutations, the focused 120 Hz workloads, and the extreme smoke matrix. Release
adds three fresh-clone P0 burn-in rounds by default and replaces the extreme smoke matrix with the
full million-row and thousand-by-one-million-character matrix. Each invocation writes a single
`gate-summary.json`; standalone scripts are diagnostic entry points, not a release verdict.

Useful standalone diagnostics are:

```sh
swift test -Xswiftc -warnings-as-errors
scripts/test-ui-in-tart.sh
scripts/capture-design-states.sh
scripts/test-release-input-interaction.sh
scripts/benchmark-frame-pacing.sh
scripts/benchmark-smooth-streaming.sh
scripts/benchmark-million-character-paste.sh
scripts/benchmark-large-history-scroll.sh
scripts/benchmark-extreme-workflows.sh smoke
# Opt-in: creates about 1.5 GB of isolated SQLite fixtures in total.
scripts/benchmark-extreme-workflows.sh full
```

The XCUI regression runs inside a fresh clone of the local `cida-ui-golden` macOS VM through [OpenAI Tart](https://github.com/openai/tart). Tart starts without graphics, audio, or host clipboard sharing; the guest network is disabled, the repository is mounted read-only, and only the selected result directory is writable from the VM. The exact signed artifact is copied into that writable share, verified against its source digest, consumed by the guest, and reverified on the host after the run. The ephemeral clone is deleted after every attempt, so the test never launches a host application or reads the production API key, UserDefaults, Keychain, or SQLite history. A 100 ms host monitor fails if either exact artifact copy is launched or takes focus on the host; frontmost-app, pasteboard, and production-Cida changes caused by concurrent user activity remain recorded diagnostics. See `UITests/README.md` for the golden-image contract and artifacts.

Standalone design snapshots and native input probes use a fresh temporary `辞达测试.app` with a unique `com.xuanwo.Cida.Automation.*` bundle identifier. Release performance gates instead launch the exact manifest-bound `Cida.app` in an isolated automation data directory. The performance instance has activation policy `.accessory`, is ordered behind existing windows, never activates the application or makes its probe window key, and never opens the production history database. Reports fail if activation or a key probe window is observed.

The in-process integration suite and the VM XCUI suite both start a loopback OpenAI-compatible SSE server. XCUI drives the visible guest application through Settings, the OpenAI endpoint, model and API Key editors, the standard close button, multiline growth and deletion shrinkage, latest-only history focus, independent expansion and collapse, full copy from folded previews, consecutive submissions, submission from detached history, uneven streaming, forced follow, completed-result visibility, hover actions and copy feedback, an active-scroll 4 × 90 pt indicator pixel gate, and the exact outbound request body. A separate Release executable gate routes a real mouse click through AppKit hit testing, performs an isolated focus handoff, sends real key-down events, and verifies the native editor and `AppModel` receive identical text. UI waits use an immediately sampled 20 ms polling primitive with timeout timelines, and harness self-tests prove that short-lived feedback cannot be skipped. Tart writes a machine-readable failure category before a failed run is interpreted as a product regression. No external credential or network service is used. `CIDA_UI_TEST_ONLY_TESTING` can select one XCUI identifier for diagnosis; omitting it always runs the complete regression suite.

The strict performance gates require a detected 120 Hz-capable display, at least 118.8 measured
native display-link callbacks per second, a P99 physical interval no greater than 12.5 ms, and zero
main-actor callback latencies above the 12.5 ms budget. The focused gates collect 1,440 samples; the
extreme matrix collects 2,400. The history gate continuously scrolls upward through 1,000
persisted-shaped records for at least 12,000 points. Production stream pacing and the probe both use
the app view's native Core Animation display link; the report labels it
`view-bound-ca-display-link` and records
native callback cadence separately from main-actor handling latency. A nonactivating fallback only
keeps an unavailable display link from hanging the process; a 60 Hz or unavailable physical display still
fails `displayRequirementSatisfied` and cannot produce a passing 120 Hz report.

The extreme matrix has a quick smoke profile and two exact, opt-in profiles: one million persisted
history rows, and one thousand persisted results containing one million characters each. Every
profile stages an exact one-million-character input, submits it through the production model path,
receives an uneven local SSE stream, verifies the terminal SQLite row, scrolls normally, and then
scrolls by one viewport per measured frame. The runner independently checks the request body and
database, enforces timeout and process-tree RSS limits, and rejects missing phase samples, incomplete
scroll distances, oversized presentation batches, or an unbounded loaded-history window. It reports
workflow correctness separately from frame pacing. A red frame gate therefore never hides a
successfully completed data flow, and a correct data flow never masks a long frame.

## Architecture

- SwiftUI owns page composition and observable application state. AppKit owns standard titled windows, the global shortcut, native text controls, keyboard routing, history-record rendering, snapshots, and performance instrumentation. A single `HistoryEntryNSView` renders folded, current, and manually expanded records; state changes never cross layout engines or duplicate header, source, result, action, fade, or accessibility geometry.
- Model requests keep stable prompt policy, typed runtime parameters, and untrusted source content separate. Translation sends explicit source and target languages; improvement sends `preserve_source` without either translation language, so every source passage stays in its original language. The same contract is used for OpenAI, compatible remote providers, and loopback mock endpoints without requiring provider-specific template syntax.
- Streamed results use a lightweight TextKit 1 rendering view and materialize a native selection editor only when needed. Presentation storage publishes an append notification, so TextKit appends only the missing UTF-16 suffix without invalidating the SwiftUI history tree. A view-bound `CADisplayLink` adaptive presenter follows the window across displays and smooths uneven network delivery at 30–400 grapheme clusters per second with a maximum of eight grapheme clusters per update.
- New streamed text uses one bounded 30 pt compositor tail whose 2 pt background blur and 18% cover fade reach zero over the Pencil 120 ms ease-out, plus an inline caret. Results grow naturally inside the history document and never install a second scroll region; the outer history alone follows while the user remains pinned to the bottom. Glyph presentation remains display-paced, while natural-height TextKit layout is coalesced to at most 10 Hz and notifies the history surface directly instead of round-tripping through the observable model.
- The actual vertical scroll surfaces—history, composer, and Settings—keep native `NSScrollView` gesture, momentum, and accessibility behavior while drawing exactly one Pencil thumb layer: 4 pt wide, rounded, trackless, fixed to the design-state length, and hidden when content does not overflow. The indicator owns a top-origin coordinate system, so its thumb moves in the same visual direction for both flipped and standard AppKit documents. AppKit's own overlay scroller remains suppressed even when the framework reinstalls it during live scrolling; its overlay layout mode is preserved so content width never oscillates. Geometry notifications are coalesced and repeated installation is idempotent.
- The composer grows and contracts from the current logical and wrapped line counts, so deleting multiline text immediately restores the compact input height. It uses a full backing document with a virtualized TextKit viewport. Documents of at least 100,000 UTF-16 units materialize only the final 512 units; upward scrolling prepends earlier 1,024-unit pages on demand. One presentation state drives both the editor height and history viewport inset through the 150 ms design transition, while the native backing store and accessibility value retain the exact count. The full document remains available for editing and submission without entering SwiftUI's observed text value. An accepted submit captures the document, clears native TextKit, resets layout, folds the previous record, and inserts the waiting result in the same input event.
- Submitted long sources are collapsed by default in history. Their character metadata is recorded at submission, so normal history rendering never counts or lays out the whole source.
- Production startup loads only the newest 512 history rows and preserves the true SQLite count and
  oldest cursor. Reaching the top loads earlier pages without inserting the complete database into
  SwiftUI's AttributeGraph. Automation uses a bounded 2,000-row page so the exact million-row
  scenario exercises a real page transition. Folded history reuses the same native entry renderer
  through an AppKit viewport recycler: it
  materializes only visible rows plus overscan, uses binary-search geometry, resets hover and
  accessibility state before reuse, and reads only each record's cached 420-grapheme preview.
  Append-only submissions retain the existing row pool and height cache and measure exactly the new
  folded row instead of re-diffing or remeasuring the page.
- SQLite writes run on a dedicated utility queue. Streaming result deltas are coalesced for 250 ms and appended in place instead of rewriting the complete growing result; terminal transitions and application shutdown flush pending work before completion.
- No idle display link or timer runs during normal use.

See `functional-qa.md` for regression evidence and `design-qa.md` for the Pencil comparison matrix.
