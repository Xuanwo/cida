# Design QA

## Source of truth

The current source is `Design/cida.pen` (SHA-256
`b6a85d7cb6db979baed7393407184fc8cedd72534c280077d709a082cc9dba5b`). The aligned
Pencil nodes are:

| State or contract | Node |
| --- | --- |
| Translate | `mlf3o` |
| Improve | `csGeO` |
| Settings | `l1gIe` |
| Long input | `r2rxd9` |
| Streaming | `J9Vlmv` |
| Record actions | `BBKsI` |
| History focus and folding | `Sol2d` |
| Action behavior | `UVmdQ` |
| Streaming motion | `NdsRA` |

Exports are retained under `Design/LatestReferenceExport`. Current native captures, normalized
references, and side-by-side review images are under `Design/ImplementationCurrent` and
`Design/QACurrent`.

## Approved visual contracts

`UITests/Resources/VisualBaselines/manifest.json` binds each executable baseline to the approved
native image, the current Pencil export, and the complete `.pen` document by SHA-256. A changed
image or design file cannot silently reuse an old approval.

| Baseline | Logical size | Mask |
| --- | ---: | --- |
| Main Translate | 860 × 640 | native title bar, 46 pt |
| Settings | 560 × 660 | native title bar, 46 pt |

The remaining Improve, long-input, streaming, hover-action, and sticky-action states are retained as
reviewable reference/current comparisons and are protected by deterministic geometry and
interaction assertions. They are not misreported as pixel baselines.

All native captures are made by isolated, nonactivating app instances. Interactive pixel checks run
inside a disposable headless Tart macOS session. Neither path activates the tested app on the host.

## Alignment result

- The main window is 860 × 640 and Settings is 560 × 660. Both use standard titled macOS windows,
  native close/minimize/zoom behavior, and content that resizes with the window.
- The surface, text hierarchy, borders, accent colors, 46 pt title bars, 28 pt main insets, 24 pt
  Settings insets, dividers, composer footer, and section spacing follow the current Pencil nodes.
- Main and Settings UI text use the bundled Inter roles. The brand title uses Noto Serif SC.
- The composer has one presentation state derived from the native document. It grows from 27 pt to
  multiline/document layouts, follows wrapped and explicit line counts, and returns to 27 pt after
  deletion or accepted submission.
- An accepted submission is one state transition: capture the source, clear the native document,
  fold the former automatic current record, insert an empty waiting record, and pin the outer
  history to the bottom. The waiting result never reuses the previous record's text or pixels.
- Only the newest record is automatically expanded. Older records use a two-line cached result
  preview without mounting their complete TextKit result. Manual comparisons can remain expanded
  independently.
- Folded, latest-expanded, and manually expanded records are presentation states of the same
  `HistoryEntryNSView`. One AppKit coordinate system owns their header, source preview, result,
  actions, fades, clipping, and accessibility frames. SwiftUI chooses the state but does not provide
  an alternate record layout. The folded card keeps its intentional 10 pt inset; expanded content
  keeps the Pencil 24 pt action column and 8 pt source-to-result gap.
- Results contribute their natural height to one outer history scroll surface. There is no nested
  output scroller. Long-result copy actions follow the visible result intersection without changing
  text width.
- History, document input, and Settings retain native `NSScrollView` gesture, momentum, keyboard,
  and accessibility behavior while drawing one trackless 4 pt Pencil thumb. The coordinate system
  is top-origin, so the history thumb is at the bottom for the newest content and moves upward when
  the user reads older content.
- Record actions are hidden at rest, appear over 120 ms on hover for terminal records, remain absent
  during streaming, and show the copied checkmark for 800 ms.
- Streaming is paced by the app view's native `CADisplayLink`. Uneven backend chunks enter a
  grapheme-safe adaptive buffer and leave in bounded display-aligned batches. The newest 30 pt tail
  uses one compositor layer whose 2 pt background blur and 18% cover fade reach zero over the
  Pencil 120 ms ease-out. The waiting caret and completion fade use the shared motion tokens.
- Native editable input and selected result text retain standard macOS Command-C precedence. The
  latest terminal result is copied only when no native text responder owns copy.
- Improvement always follows the detected source language and presents `输出跟随原文` in the
  composer and `语气与语法` in history.
- Settings matches the current section, row, prompt-editor, shortcut, footer, and spacing design.
  Provider, model, endpoint, API key, prompt editing/reset, launch-at-login, and native window
  controls remain real interactive controls.

## Intentional prompt-text difference

The current Pencil export still contains legacy `{text}` and `{target_lang}` helper copy. The
application intentionally shows that task parameters are supplied by the application without
placeholders. This preserves the approved product contract: prompts are plain policies, the source
appears exactly once as untrusted user content, and operation/language choices travel in a typed
runtime envelope. Geometry and style remain aligned; the obsolete placeholder wording is not
reintroduced.

## Executable evidence

- `swift test -Xswiftc -warnings-as-errors`: 142 tests, 0 failures.
- Native renderer tests prove all three history presentations use the same concrete view, preserve
  the header renderer identity across transitions, release expanded-only resources when folding,
  and expand a recycled row through a real AppKit hit-test and mouse event.
- Fresh-clone Tart history journeys assert exact latest-source/result containment and spacing, and
  retain WindowServer screenshots for both source and folded-result fades.
- `VisualAndAccessibilityJourneyTests` compares the Main Translate and Settings WindowServer
  screenshots against the manifest-bound approved images and runs the native semantic accessibility
  audit.
- The full PR gate output for this refactor is written to
  `TestResults/gates/unified-history-renderer-final-20260818/gate-summary.json`. It runs all nine UI
  suites rather than a hand-maintained subset; `PairwiseManifestTests` fails if any suite is omitted.
- Failures retain approved/current/Pencil/diff images in the `.xcresult`; baseline recording is
  never automatic.

## Remaining certification boundary

Tart proves real macOS interaction and WindowServer composition, not physical 120 Hz cadence.
Physical performance is accepted only when the nonactivating runner detects a real 120 Hz display
and the exact manifest-bound app satisfies the frame budget. A 60 Hz run remains useful diagnostic
evidence but cannot be labeled a 120 Hz pass.
