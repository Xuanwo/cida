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

Exports are retained under `Design/LatestReferenceExport`; `l98qna.png` and `cRhyz.png` are the
`Motion — 历史折叠` T0 and T1 viewports that define the folded card. Current native captures,
normalized references, and side-by-side review images are under `Design/ImplementationCurrent` and
`Design/QACurrent`. The `history-folded` design state (`scripts/capture-design-states.sh`) renders
one folded long card above the focus record for direct comparison with `l98qna.png`.

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
- Folded records are the Pencil card from `BBKsI` ④ and `fgF4n`: a `surface-fold` fill with an
  8 pt radius, a 10 pt inset on every side, meta plus the first two result lines at the shared
  26 pt line height, and a 25 pt fade to the card colour. Cards have no divider; consecutive cards
  keep one 8 pt gap so their fills stay distinct (the Stream frame never stacks two cards, so the
  gap reuses the `Entry` gap token). Hovering lifts the whole card to `surface-fold-hover`
  (`#ECECE7`, halfway to `border`, because the design only calls for a slight highlight) over
  the 120 ms icon-in duration. Dividers only separate two expanded records, as in `mlf3o`.
- Folded, latest-expanded, and manually expanded records are presentation states of the same
  `HistoryEntryNSView`. One AppKit coordinate system owns their header, source preview, result,
  actions, fades, clipping, and accessibility frames. SwiftUI chooses the state but does not provide
  an alternate record layout. Expanded content keeps the Pencil 24 pt action column and 8 pt
  source-to-result gap; result rows are exactly 26 pt per line with no extra inset, so a
  one-line entry is the Pencil 82 pt.
- Presentation changes animate over the 200 ms `motion-fold-ms` ease-out. A new submission keeps
  the former focus record standalone while its source collapses, its result clips to two lines
  under the fade, and the card fill rises; a clicked card first renders as that card and then
  opens in place, and collapsing runs the same transition in reverse before the record rejoins the
  virtualized list. The folded preview and the expanded result share one TextKit style, so the
  swap at the start of a transition never changes line height.
- SwiftUI and AppKit resolve every shared surface, text, border, and accent color from
  `CidaDesign.Palette`, while every history renderer resolves sizing from
  `HistoryEntryPencilLayout`. Token tests pin the approved sRGB values and layout measurements so a
  framework-specific literal cannot silently drift from the design.
- Results contribute their natural height to one outer history scroll surface. There is no nested
  output scroller. Long-result copy actions follow the visible result intersection without changing
  text width.
- History, document input, and Settings retain native `NSScrollView` gesture, momentum, keyboard,
  and accessibility behavior while drawing one trackless 4 pt Pencil thumb. The coordinate system
  is top-origin, so the history thumb is at the bottom for the newest content and moves upward when
  the user reads older content.
- Record actions are hidden at rest, fade in over 120 ms on hover for terminal records, remain
  absent during streaming, fade in over 150 ms when a hovered record completes, and show the
  copied checkmark for 800 ms.
- Streaming is paced by the app view's native `CADisplayLink`. Uneven backend chunks enter a
  grapheme-safe adaptive buffer and leave in bounded display-aligned batches. Each presented run is
  laid out on the pulse that presents it and painted by its own fragment view that fades from
  transparent and unblurs from 2 pt over the Pencil 120 ms ease-out, behind the caret; the record
  renderer takes those glyphs over only after the fade, so nothing shifts. A wrapped line grows the
  record on the same pulse, and the history surface slides the growth in over the 150 ms
  `motion-height-ms` ease-out instead of jumping. The waiting caret and completion fade use the
  shared motion tokens; reduced motion keeps display-paced arrival and drops the fades.
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

- `swift test -Xswiftc -warnings-as-errors`: 153 tests, 0 failures.
- Native renderer tests prove all three history presentations use the same concrete view, preserve
  the header renderer identity across transitions, release expanded-only resources when folding,
  expand a recycled row through a real AppKit hit-test and mouse event, run the fold and expand
  transitions inside one renderer (card frame, opacity, and preview text at the start; final
  geometry after `motion-fold-ms`), fade record actions in over 120 ms on hover and 150 ms on
  completion, and give every presented glyph run its own 120 ms reveal fragment that commits in
  order. Model tests pin the 200 ms folding grace for collapsed and superseded records.
- Fresh-clone Tart history journeys assert exact latest-source/result containment and spacing, and
  retain WindowServer screenshots for both source and folded-result fades.
- `VisualAndAccessibilityJourneyTests` compares the Main Translate and Settings WindowServer
  screenshots against the manifest-bound approved images and runs the native semantic accessibility
  audit. The Main Translate approval was re-recorded from the isolated nonactivating capture after
  the folded cards moved to the Pencil card styling; the Settings approval is unchanged.
- `scripts/test-ui-in-tart.sh` from this tree: all 28 XCUI journeys passed in a fresh headless
  Tart clone (`TestResults/vm-ui-pencil-run2`), including the folded-card geometry assertions, the
  re-approved Main Translate baseline, and the host-session guard.
- `scripts/e2e/run-mutation-contracts.sh --mode unit` on a scratch clone of this tree: all 14
  mutations killed (`TestResults/mutations-unit-pencil-20260908`), including the re-anchored
  `folded-result-fade-hidden` mutation that now empties the Pencil fade frame.
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
