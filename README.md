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

The XCUI regression runs inside a fresh clone of the local `cida-ui-golden` macOS VM through [OpenAI Tart](https://github.com/openai/tart). Tart starts without graphics, audio, or host clipboard sharing; the guest network is disabled, the repository is mounted read-only, and only `TestResults/vm-ui` is writable from the VM. The ephemeral clone is deleted after every run, so the test never launches a host application or reads the production API key, UserDefaults, Keychain, or SQLite history. See `UITests/README.md` for the golden-image contract and artifacts.

Snapshot and performance modes use a fresh temporary `辞达测试.app` for every invocation. Each instance receives a unique `com.xuanwo.Cida.Automation.*` bundle identifier, isolated UserDefaults and Keychain namespaces, and is removed after the run. Automation never opens the production history database, rebuilds or launches `build/Cida.app`, activates the application, or makes a probe window key.

The in-process integration suite and the VM XCUI suite both start a loopback OpenAI-compatible SSE server. XCUI drives the visible guest application through Settings, the OpenAI endpoint, model and API Key editors, the standard close button, multiline growth and deletion shrinkage, latest-only history focus, independent expansion and collapse, full copy from folded previews, consecutive submissions, submission from detached history, uneven streaming, forced follow, completed-result visibility, hover actions and copy feedback, an active-scroll 4 × 90 pt indicator pixel gate, and the exact outbound request body. A separate Release executable gate routes a real mouse click through AppKit hit testing, performs an isolated focus handoff, sends real key-down events, and verifies the native editor and `AppModel` receive identical text. No external credential or network service is used. `CIDA_UI_TEST_ONLY_TESTING` can select one XCUI identifier for diagnosis; omitting it always runs the complete regression suite.

The strict performance gates require a 120 Hz-capable display, at least 118.8 measured ticks per
second, P99 no greater than 12.5 ms, and zero intervals above 12.5 ms. The focused gates collect
1,440 samples; the extreme matrix collects 2,400. The history gate continuously scrolls upward
through 1,000 persisted-shaped records for at least 12,000 points. Because macOS suspends the app's
visual display callbacks while this non-activating test instance remains in the background, the
automation report explicitly labels its measurement clock `background-deadline`. Production
streaming uses the screen's display link; the background gate is a non-disruptive main-actor deadline
and workload regression, not a claim that a hidden window was presented by WindowServer at 120
visible frames per second. The deadline clock still runs at the requested 120 Hz on a 60 Hz display
so headless runs can expose main-actor stalls, but `displayRequirementSatisfied` remains false and the
report cannot pass until it is rerun on a physical 120 Hz-capable display.

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

- SwiftUI owns composition and observable application state. AppKit owns standard titled windows, the global shortcut, native text controls, keyboard routing, snapshots, and performance instrumentation.
- Model requests keep stable prompt policy, typed runtime parameters, and untrusted source content separate. The same contract is used for OpenAI, compatible remote providers, and loopback mock endpoints without requiring provider-specific template syntax.
- Streamed results use a stable native TextKit view. Presentation storage publishes a native append notification, so TextKit appends only the missing UTF-16 suffix without invalidating the SwiftUI history tree. A display-linked adaptive presenter smooths uneven network delivery at 30–400 grapheme clusters per second with a maximum of eight grapheme clusters per update.
- New streamed text uses one batched 120 ms fade pipeline and an inline caret. Results grow naturally inside the history document and never install a second scroll region; the outer history alone follows while the user remains pinned to the bottom. Glyph presentation remains display-paced, while natural-height TextKit layout is coalesced to at most 30 Hz and notifies the history surface directly instead of round-tripping through the observable model.
- The actual vertical scroll surfaces—history, composer, and Settings—keep native `NSScrollView` gesture, momentum, and accessibility behavior while drawing exactly one Pencil thumb layer: 4 pt wide, rounded, trackless, fixed to the design-state length, and hidden when content does not overflow. The indicator owns a top-origin coordinate system, so its thumb moves in the same visual direction for both flipped and standard AppKit documents. AppKit's own overlay scroller remains suppressed even when the framework reinstalls it during live scrolling; its overlay layout mode is preserved so content width never oscillates. Geometry notifications are coalesced and repeated installation is idempotent.
- The composer grows and contracts from the current logical and wrapped line counts, so deleting multiline text immediately restores the compact input height. It uses a full backing document with a virtualized TextKit viewport. Documents of at least 100,000 UTF-16 units materialize only the final 512 units; upward scrolling prepends earlier 1,024-unit pages on demand. Presentation-only layout metrics expand through bounded 9 ms stages, while the native backing store and accessibility value retain the exact count. The full document remains available for editing and submission without entering SwiftUI's observed text value. An accepted submit synchronously cancels pending presentation stages, captures the document, clears native TextKit, and resets Composer-owned layout metrics in the same input event.
- Submitted long sources are collapsed by default in history. Their character metadata is recorded at submission, so normal history rendering never counts or lays out the whole source.
- Production startup loads only the newest 512 history rows and preserves the true SQLite count and
  oldest cursor. Reaching the top loads earlier pages without inserting the complete database into
  SwiftUI's AttributeGraph. Automation uses a bounded 2,000-row page so the exact million-row
  scenario exercises a real page transition. Folded history is an AppKit viewport recycler: it
  materializes only visible rows plus overscan, uses binary-search geometry, resets hover and
  accessibility state before reuse, and reads only each record's cached 420-grapheme preview.
  Append-only submissions retain the existing row pool and height cache and measure exactly the new
  folded row instead of re-diffing or remeasuring the page.
- SQLite writes run on a dedicated utility queue. Streaming result deltas are coalesced for 250 ms and appended in place instead of rewriting the complete growing result; terminal transitions and application shutdown flush pending work before completion.
- No idle display link or timer runs during normal use.

See `functional-qa.md` for regression evidence and `design-qa.md` for the Pencil comparison matrix.
