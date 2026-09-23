# Functional QA

## Release contract

Cida's release decision is based on one signed Release `.app`, not on a Debug preview build. The
artifact manifest records the source commit, clean state, Developer ID signature, executable digest,
and complete app-tree digest. Swift tests, Tart XCUI, mutation contracts, and performance runners
consume that artifact or the same source commit, and the final gate verifies the app-tree digest
again.

The current core experience contract (Pencil `Spec — 面板模型`) includes:

1. A menu-bar application whose main interface is one borderless, non-activating floating panel:
   `Option-Space` shows or hides it without taking focus from the application the user came from,
   Escape and clicking outside hide it, and hiding never loses the source, the result, or a running
   request.
2. Real native typing, selection, paste, multiline growth, deletion-driven shrink, and Return
   submit in the source pane, with the panel exactly as tall as its content: the source pane is
   capped at 30% of the screen, the panel at 70%, and both panes scroll past their caps.
3. One result at a time. Return runs the selected action on the current source, keeps the source
   in the editor, and replaces the previous result immediately. Every appearance of the panel
   resets the action to 翻译 and selects the whole source.
4. Delayed-first-byte, bursty, character-at-a-time, paused, stopped, failed, and recovered
   OpenAI-compatible streaming, rendered with display-linked smoothing, bounded grapheme batches,
   the per-run 120 ms glyph reveal behind the caret, the waiting caret, coalesced TextKit
   natural-height publication, and the 150 ms height slide for pane and panel growth.
5. A control bar with the `翻译 | 改进` action (Tab switches it) and one context slot: `停止`
   while a request runs, `复制结果` once a result exists, `✓ 已复制` for 800 ms after copying.
6. Result notes instead of alerts: an edited source or a changed action dims the result and notes
   `原文已修改 · ⏎ 重新生成`; a stopped request keeps its partial text with `已停止`; a failed
   request explains itself inline and Return retries.
7. Native Command-C precedence: a selection keeps the system copy; without one, Command-C copies
   the result.
8. DeepSeek/OpenAI selection, editable local endpoint and model, Keychain API-key persistence and
   clearing, prompt edit/reset, source-language detection, and source-language-preserving
   improvement, all from a standard Settings window.
9. Input-method safety: the SwiftUI binding is never written back into the editor while a
   composition (for example pinyin) is in progress, the placeholder hides as soon as marked text
   appears, and Escape, Tab, and the other panel shortcuts reach the input method first while it
   composes.
10. Exact one-million-character input in the isolated performance workload.

Production starts empty and without mock output. Automation redirects only its preferences,
Keychain namespace, local endpoint, and diagnostics; it does not replace the production model,
panel, or renderer paths.

## Root repairs in the panel rewrite

| Risk | Root repair | Regression oracle |
| --- | --- | --- |
| The history timeline consumed most of the code and its interaction never converged | The timeline, folding, SQLite persistence, virtualized list, and their gates are removed. `AppModel` holds one `ResultRecord`; the panel shows source, control bar, and result. | The whole suite runs against the panel; `PairwiseManifestTests` keeps every UI suite in the PR gate. |
| A fixed window left dead space and a chat-style bottom composer | `PanelController` sizes a non-activating `NSPanel` from the height its SwiftUI content reports, anchored at the top edge, within a screen-relative budget. | Panel style-mask, content-height, fixed-top-edge, and height-budget tests; XCUI growth/shrink and hide/show journeys. |
| Pinyin composition was cancelled by SwiftUI write-backs | `ComposerTextEditor.updateNSView` skips the binding write-back while the text view has marked text (found by the panel IME spike). | `testBindingWriteBackIsSkippedWhileAnInputMethodIsComposing`. |
| The source pane did not shrink after deletions | The source height is measured from TextKit 2 layout fragments after every native edit instead of the lazily updated usage bounds. | Composer shrink test with exact 78/52/27 pt heights and the matching panel heights; XCUI growth/shrink journey. |
| A completed result opened scrolled to its end | The result scroll view follows the tail only while streaming; the first follow revision of a completed result stays at the top. | Height-budget test and the long-input indicator test assert `contentView.bounds.minY == 0`. |
| A stale result could be copied as if current | `isResultStale` compares source length and text and the action against the record; the note row states what ⏎ will do. | `testEditedSourceMarksTheResultStale`, property test stale parity, XCUI stale note. |
| The panel showed transparent in the signed Release build | `PanelController.show()` faded the panel in through `NSWindow.animator().alphaValue`, which never progressed in the Release guest; the panel is ordered front at full opacity instead. Only production and the Tart launch reach `show()` (design snapshots use `prepareAutomationPanel`). | Every XCUI journey (the panel must exist), plus the per-launch lifecycle log that records the panel's alpha on show. |

## Test layers

| Layer | Environment | Current role |
| --- | --- | --- |
| State | Swift XCTest | model transitions, typed request envelope, deterministic property sequences, report validation |
| Native components | AppKit XCTest | responder chain, TextKit append/layout, panel sizing, indicators, background windows |
| Release E2E | fresh headless Tart clone | real signed app, WindowServer, XCUI input, local SSE, screenshots, accessibility |
| Mutation | temporary clean clone | deliberately reintroduce known faults; designated unit and Release tests must fail |
| Performance | nonactivating physical-display runner | display-link cadence, main-actor latency, missed budgets, exact workloads, RSS and artifact digest |

The host Swift suite contains 102 tests: 45 model/report tests, 36 native interaction and layout
tests, 6 mutation invariants, 4 host isolation tests, 4 design-token tests, 3 loopback integration
tests, 2 suite/matrix manifest tests, and 2 deterministic journey-model tests.

The Release XCUI target contains 18 tests across seven files: 15 product journeys and three harness
self-tests. The product journeys cover signed-artifact smoke, composer growth and shrink, submit
with the source retained, stale marking, improvement in both languages, Command-C precedence,
controlled and uneven streams, result replacement, stop/failure/recovery, the shared state-machine
smoke with hide and show, the panel lifecycle and Settings, and the empty-panel and Settings pixel
baselines with the accessibility audit.

## Test-system self-verification

All UI waits use one 20 ms polling primitive that samples immediately, records value transitions,
and attaches its timeline to the XCResult on timeout. Three deterministic harness tests use an
injectable clock to prove that 100 ms, 200 ms, and 800 ms transient states are observable and that a
timeout retains its changed-value history. Tart failures write a machine-readable classification as
`infrastructure`, `build`, `source-test`, `ui-assertion-or-crash`, or `artifact`; an ambiguous UI
failure is never automatically labeled as a product regression. Every XCUI launch also writes a
panel lifecycle log (`lifecycle/<namespace>.log`, via `--automation-lifecycle-log`) with the
activation policy, app activation, and the panel's visibility, key status, alpha, and frame at
launch, on every show, and on every key-window transition, because none of that is observable
through accessibility for a non-activating panel.

The mutation catalog contains eight source-level faults. Each definition pins an exact source
anchor and names its unit and Release kill tests. Catalog drift fails before an expensive build
or VM launch: the anchor must occur exactly once, and every named kill test must be declared in the
test sources. A targeted `swift test --filter` that matches no test case is reported as
`infrastructure`, never as a killed or survived mutation. The faults cover the redraw policy of the
result layer, a replaced result keeping its old text, a submission keeping the previous record, a
stale result never being marked, the action not resetting on show, the source pane never resizing,
Command-C ignoring a native selection, and improvement reusing translation languages.

The checked-in pairwise manifest provides a stable inventory of light/dark, reduced motion,
scrollbar preference, action, content, and display combinations, and its pair coverage is
mathematically verified. It is not executed as separate Tart configurations, so it must not be
presented as a completed environment matrix.

## Isolation contract

Tart clones `cida-ui-golden`, randomizes the clone MAC, disables graphics, audio, host clipboard,
and guest Ethernet, mounts source read-only, and exposes only a writable artifact directory. App
assertion failures are never retried. A failed VM boot may receive one fresh-clone retry; a broken
golden image must be reinitialized instead of repaired in place.

A 100 ms host monitor tracks the two exact artifact executable paths. The run fails if either is
launched or becomes frontmost on the host, if the monitor dies, or if sample coverage has a gap.
Normal user changes to the host frontmost app, clipboard, or independently running production Cida
are recorded as diagnostics rather than misclassified as test activity.

## Current verification

- `swift test -Xswiftc -warnings-as-errors`: 102/102 passed on the host.
- Tart XCUI suite: see the run recorded below.
- Mutation catalog: all 8 anchors validate (`run-mutation-contracts.sh --mode catalog`), and
  `--mode unit` kills all 8 in temporary clean clones (7 of 8 on commit 0f83f03; the eighth,
  `improvement-reuses-translation-source-language`, did not compile until its replacement text
  followed the typed `Language` fields and was killed on commit 7b418ff). Results directories:
  `TestResults/panel-mutations-20260923` and `TestResults/panel-mutations-20260923-fix`.

### Tart XCUI run `panel-tart-20260923j`

18 of 18 tests passed in a fresh headless Tart clone (macOS 26.4 guest, Xcode 26.5) against
the signed Release artifact built from this tree (app-tree digest
`d7fd4dab11fcb98bfe951bad16e08d032ae61725581571e694775d8e19bc059b`), after the guest's own
`swift test` (102/102). The host session guard passed: neither artifact executable was launched or
frontmost on the host. Results directory: `TestResults/panel-tart-20260923j`.

The first runs of the rewritten suite failed as a whole before any journey ran, and the failures
were harness and product findings rather than flakes:

- `show()` faded the panel in with a window animator that never progressed in the Release guest,
  so the panel was key and ordered front at alpha 0 for the whole run (found with the lifecycle
  log, fixed in the product).
- XCUI reports the borderless `NSPanel` as a dialog, never under `windows`; the driver queries
  `dialogs["cida-panel"]`.
- An identifier on the panel's root stack was pushed by SwiftUI onto the pane containers and hid
  their own `source-pane`, `control-bar`, and `result-pane` identifiers.
- The 800 ms `✓ 已复制` state is missed by `waitForExistence`, which samples about once per
  second; the driver's 20 ms polling waiter observes it.
- The pre-first-byte pixel oracle screenshots the result pane rather than the text view (whose
  accessibility frame is the full document height), skips the rounded bottom corners where the
  desktop shows, and skips the caret column, whose faded breathing edges read as neutral ink.
- The combined note row exposes its text as the element's value, not its label.
- The accessibility audit ignores elements outside the panel's frame (the guest's Touch Bar proxy
  and menu bar).

## Performance acceptance boundary

The performance runner uses the exact manifest-bound app with activation policy `.accessory`, orders
its transparent panel behind existing windows, and fails if the app activates or the panel becomes
key. Focused gates require a detected 120 Hz display, at least 118.8 native display-link callbacks
per second, P99 and main-actor latency within the configured budget, zero missed budgets for strict
workloads, and complete workload-specific invariants.

Tart frame rate is never used as 120 Hz evidence. If only a 60 Hz display is detected, correctness
and diagnostic latency can still be reported, but physical 120 Hz certification remains pending.
