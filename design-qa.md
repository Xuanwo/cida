# Design QA

## Source of truth

The current source is `Design/cida.pen` (SHA-256
`dbe535eb50ee22a22579d5311a56a9f63ba382ef93083ab91cbaa850509566e3`). The aligned
Pencil nodes are:

| State or contract | Node |
| --- | --- |
| Translate | `mlf3o` |
| Improve | `csGeO` |
| Settings | `l1gIe` |
| Long input | `r2rxd9` |
| Streaming | `J9Vlmv` |
| Record actions | `BBKsI` |
| History folding rules | `Sol2d` |
| Record action rules | `UVmdQ` |
| Streaming motion | `NdsRA` |
| Long record at rest (860) | `rOC5t` |
| Reading column (1280) | `JoW8q` |
| History fold states | `T6tMl` |

The Pencil document is the first source: each topic has one Spec note (`Sol2d`, `UVmdQ`,
`NdsRA`), and a rule change edits that note and its States or Motion board instead of adding a
versioned copy. Exports of the screens, the States boards, and the Spec notes are retained under
`Design/LatestReferenceExport`; `l98qna.png` and `cRhyz.png` are the `Motion — 历史折叠` T0 and T1
viewports (kept for the fold transition keyframes). Current native captures,
normalized references, and side-by-side review images are under `Design/ImplementationCurrent` and
`Design/QACurrent`. The `history-folded` and `wide-reading-column` design states
(`scripts/capture-design-states.sh`) render one long record at rest above the focus record and
the centred reading column in a 1280 × 720 window, for comparison with `rOC5t` and `JoW8q`.

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
- Only the newest record is automatically expanded. Older records use their cached result preview
  without mounting the complete TextKit result. Manual comparisons can remain expanded
  independently.
- History folding (`Sol2d`, `T6tMl`): a historical record at rest is the Pencil `Entry`
  without its source row, so its text shares the expanded records' left rail, the 24 pt action
  column, and 1 px dividers; there is no card fill or inset. A result that fits one line takes the
  82 pt row, two lines take 108 pt in full, and a longer result keeps the 108 pt row with the second
  line dissolving into the 25 pt fade to the window background. Long documents always fold. The row
  height comes from a cached single-line width of the 420-grapheme preview, so the virtualized
  list never lays text out to size a row. Hovering a record at rest tints the whole row with
  `surface-fold` over the 120 ms icon-in duration, bleeding 10 pt past the column
  (`space-hover-bleed`), and reveals ↺, copy, and a chevron-down disclosure hint; expanded records
  show chevron-up without a row tint.
- The history and composer content sit in a column of at most 804 pt (`reading-width`, the
  Pencil column at 860). Wider windows centre the column; the title bar, the composer surface, and
  both scroll indicators keep spanning the window.
- Folded, latest-expanded, and manually expanded records are presentation states of the same
  `HistoryEntryNSView`. One AppKit coordinate system owns their header, source preview, result,
  actions, fades, clipping, and accessibility frames. SwiftUI chooses the state but does not provide
  an alternate record layout. Expanded content keeps the Pencil 24 pt action column and 8 pt
  source-to-result gap; result rows are exactly 26 pt per line with no extra inset, so a
  one-line entry is the Pencil 82 pt.
- Presentation changes animate over the 200 ms `motion-fold-ms` ease-out. A new submission keeps
  the former focus record standalone while its source collapses and its result rises and, for a
  long record, clips under the fade; a short record only gains its divider. A clicked row first
  renders as that row and then opens in place to show its source (and, for a long record, its
  complete result); the switch waits for the run-loop turn in which the native row has its frame
  and window, because SwiftUI's `onAppear` precedes both and an unsized view would measure its
  result at a 1 pt width and skip the transition. Measuring a record never lays its result out:
  SwiftUI probes 1 pt and 10 pt widths while sizing the column, so the result keeps the height of
  its last real layout. Collapsing runs the same transition in reverse
  before the record rejoins the virtualized list. SwiftUI animates the record's frame with the
  same ease-out control points AppKit uses for its content. The resting preview and the expanded result share one TextKit style, so
  the swap at the start of a transition never changes line height.
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
  absent during streaming, fade in over 150 ms when a hovered record completes, fade out over the
  same 120 ms when the pointer leaves (the button itself hides at once; a detached snapshot layer
  carries the fade), crossfade copy → ✓ over the 150 ms `motion-icon-swap-ms`, and hold the ✓ for
  800 ms. Every icon, including the sticky result copy, rests at `text-tertiary` and darkens to
  `text-secondary` only while the pointer is over that icon. The icon view is the only painter: the
  NSButton cell keeps a described copy of the image for the accessibility audit but never draws,
  because the cell paints a second, blocky copy of a template image even with
  `imagePosition = .noImage`.
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

- `swift test -Xswiftc -warnings-as-errors`: 158 tests, 0 failures.
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
  the history rows moved to the v2 rule; the Settings approval is unchanged.
- `scripts/test-ui-in-tart.sh` from this tree: all 28 XCUI journeys passed in a fresh headless
  Tart clone (`TestResults/vm-ui-expand-run2`), including the row geometry assertions (108 pt
  long record, 40 pt preview offset, chevron beside ↺), the expanded action column of the latest
  record, the re-approved Main Translate baseline, the native accessibility audit with the
  described but undrawn action-button images, and the host-session guard.
- `scripts/e2e/run-mutation-contracts.sh --mode unit` on a scratch clone of this tree: 13 of the
  14 mutations were killed on the first run (`TestResults/mutations-unit-pencil-v2-20260910`). The
  re-anchored `folded-result-fade-hidden` mutation, which empties the Pencil fade frame, survived
  that run only because its catalog entry still named the v1 kill test that the v2 rewrite had
  replaced, so the targeted filter executed no test. The catalog now names
  `testHistoryRowShowsUpToTwoLinesAndFadesOnlyALongerResult`, which pins the exact fade frame, the
  runner rejects undeclared kill tests during catalog validation and reports an empty filter as
  `infrastructure`, and the targeted rerun killed the mutation
  (`TestResults/mutations-unit-pencil-v2-fade-rerun-20260910`).
- `scripts/benchmark-smooth-streaming.sh` and `scripts/benchmark-large-history-scroll.sh` against
  the Tart-verified artifact (`TestResults/performance-pencil-v2-20260910`): both workloads
  completed with a maximum main-actor latency under 2 ms on the 60 Hz host display; one run
  recorded two late frames at the very end of the stream that two immediate reruns did not
  reproduce. The 120 Hz gate itself still needs a 120 Hz display.
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
