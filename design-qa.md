# Design QA

## Scope and source of truth

- Pencil document: `Design/cida.pen`
- Translate: `mlf3o`
- Improve: `csGeO`
- Long document: `r2rxd9`
- Streaming: `J9Vlmv`
- Record actions: `BBKsI`
- History focus and folding: `Sol2d`
- Record-action specification: `UVmdQ`
- Streaming-motion specification: `NdsRA`

Settings (`l1gIe`) is explicitly outside this alignment pass and was not visually changed.
All source nodes were read and exported through the Pencil MCP. The current exports are under
`Design/LatestReferenceExport`.

## Capture contract

The four app-state comparisons use an 860 × 640 logical viewport. Native Retina captures are
normalized to the same logical size. Each comparison places the current Pencil source on the left
and the current native implementation on the right with a 16 px gutter:

- `Design/QACurrent/comparison-translate.png`
- `Design/QACurrent/comparison-improve.png`
- `Design/QACurrent/comparison-large-input.png`
- `Design/QACurrent/comparison-streaming.png`

The interaction specifications and retained XCUI screenshots are compared together in:

- `Design/QACurrent/comparison-record-actions.png`
- `Design/QACurrent/comparison-sticky-long-result.png`

All implementation captures were produced by isolated app instances. Static captures never became
active or key. Interactive captures came from a disposable Tart macOS VM rather than the host
desktop.

## Verified alignment

- **Typography:** main-window UI and result text use bundled Inter roles; the brand title uses Noto
  Serif SC. Settings retains its existing typography because it is out of scope.
- **Geometry:** the 860 × 640 surface, 46 pt title bar, history spacing, 101 pt compact composer,
  expanded document composer, dividers, and footer controls align to the current source nodes.
- **Tokens:** background `#FAFAF8`, surface, dim surface, border `#E8E8E3`, text hierarchy, accent
  `#2E6B4F`, and accent-soft `#EAF2EE` match the Pencil variables.
- **Record actions:** retry, source-copy, and result-copy remain fully hidden at rest, fade in over
  120 ms for a hovered terminal record, and never appear for an active stream. Successful copy
  changes only the selected copy icon to the accent checkmark and returns after 800 ms.
- **History focus:** the newest record remains expanded. Older records fold to metadata plus at most
  two faded result lines, omit the source, and do not instantiate TextKit until explicitly expanded.
  Records expand independently, tapping metadata collapses them again, and copy always returns the
  complete result rather than the preview. A new submission folds the previous focus over 200 ms.
  This later `Sol2d` interaction contract is authoritative where older static screen fixtures still
  show a fully expanded previous row.
- **Long-result action:** the result-copy control is an overlay and does not reserve text width. For
  a long record it follows the top of the result's visible intersection while remaining inside the
  record block.
- **Copy shortcut:** native editable input and native text selection keep standard macOS `⌘C`
  precedence. Only when neither owns copy does `⌘C` copy the latest terminal result; an active
  streaming entry is skipped.
- **Single scroll surface:** result text contributes its full natural height to the outer history.
  No result installs an independent scroll view. The long-document state has a real scroll runway,
  preserving both the source position and a draggable history thumb.
- **Scroll indicators:** history and document input each draw one trackless, rounded, 4 pt Pencil
  thumb at the source coordinates. The history thumb is fixed at 90 pt and the document thumb at
  64 pt; AppKit's proportional overlay rendering remains suppressed. The indicator uses the same
  top-origin direction as the document: the thumb is at the bottom for the newest history and moves
  upward when the user scrolls toward older records.
- **Streaming:** the waiting caret pulses, new grapheme-safe batches fade from 25% opacity and 2 pt
  blur over 120 ms ease-out, line-height growth reveals over 150 ms ease-out through Core Animation,
  and completion fades the caret before the copy/retry actions appear.
- **Auto-follow:** submission force-pins the outer history, follows growth through the final SSE
  event, and leaves the complete result visible above the collapsed composer. A deliberate user
  scroll still detaches follow.
- **Long input:** the editor grows for multiline text, uses the bottom viewport for very large
  documents, contracts back through each line count after deletion, and returns to the compact
  height after submit.
- **Assets:** all Pencil icons are vendored from Lucide and rendered from bundle resources; no
  Unicode glyph, SF Symbol, or hand-drawn approximation is used for the aligned main surface.

## Findings and iteration history

- P0: none.
- P1: none.
- P2: none.
- P3: inactive native traffic lights and native text rasterization differ slightly from Pencil's
  renderer in non-activating static captures. The active XCUI capture also contains the standard
  macOS keyboard-focus ring on the model control. Both are native system states, not custom chrome.
- The first comparison exposed system-font wrapping in the main surface; the main UI was moved to
  the Pencil Inter roles without changing Settings.
- The first long-document comparison exposed an obsolete visible sample record and a missing
  history thumb. The obsolete fixture was removed and a transparent long-record scroll runway now
  preserves the exact visible content while keeping the outer scroll surface genuinely interactive.
- The first streaming performance pass exposed SwiftUI layout animation and per-frame TextKit
  attribute churn. Height reveal moved to Core Animation and glyph styling is applied at four
  display-aligned milestones; the then-current 120 Hz gate subsequently passed with zero missed
  budgets.
- The first production-shaped folding run exposed an endless `LazyVStack` prefetch/layout cycle in
  a hidden host. Histories up to 64 lightweight rows now use an eager stack, while larger histories
  retain lazy materialization and only a bounded tail is primed.
- The final hover failure was not a visual hover regression: the failure hierarchy showed all three
  controls on screen, but the retry control had inherited the parent collapse identifier. Reordering
  the accessibility and overlay modifiers preserves the retry identifier; the focused VM regression
  and the subsequent unfiltered suite both pass.

## Interaction evidence

- `TestResults/vm-ui/CidaUITests.xcresult` is the final fresh-VM result: 9 XCUI journeys, 0 failures.
  `xcresult-summary.json` is regenerated from that exact bundle after every successful run, so a
  previous summary cannot survive beside a newer result.
- `TestResults/vm-ui/Attachments-history-scroll-20260815` retains history folding, both consecutive
  completions, copied-checkmark, sticky long-result, completed auto-follow, and active-scroll
  indicator screenshots.
- `TestResults/vm-ui/Attachments-scroll-direction-20260817` retains the latest bottom-position and
  older-record-position screenshots used by the direction assertion.
- The same Tart run passed all 115 Swift tests and the optimized Release real mouse/keyboard
  responder-chain gate before XCUI began. Its sharding guard rejects any interaction test omitted
  by the maintained filters.
- XCUI verifies latest-only focus, independent expansion/collapse, full copy from a folded preview,
  continuity across two consecutive submissions, hover visibility, streaming suppression, copied
  feedback and reset, native-selection precedence, latest-result fallback, sticky action geometry
  before and after scrolling, one outer result scroll surface, multiline growth/contraction,
  submit-time follow, completion visibility, the local OpenAI-compatible request, and the actual
  vertical movement direction of the fixed Pencil thumb from two pixel screenshots.
- The optional `CIDA_UI_TEST_ONLY_TESTING` selector exists only for focused diagnosis; the default
  VM command remains the unfiltered nine-journey gate used for this result.

## Performance evidence

- `Performance/final-60hz/million-character-paste.json` is the final-code physical-display result:
  1,000,000 exact characters, 720 samples, 60.000079 measured FPS, 16.7033 ms P99, 17.5194 ms maximum,
  zero missed budgets, 0.828 ms insertion, no application activation, and no key window.
- `Performance/final-60hz/smooth-streaming.json` releases at most eight grapheme clusters per
  presentation update and completed at 60.000152 FPS with zero missed budgets.
- `Performance/final-60hz/large-history-scroll.json` covers 1,000 persisted records and 23,040 pt of
  consecutive upward scrolling: 60.000287 FPS, 16.7648 ms P99, 18.4190 ms maximum, and zero missed
  budgets.
- The three current-code reports under `Performance/final-120hz-deadline-diagnostic` ran 1,440
  requested-120 samples with zero missed 12.5 ms budgets. They remain failed certifications because
  the probe reported a 60 Hz physical maximum and `displayRequirementSatisfied = false`.
- Both exact extreme workflows pass the physical 60 Hz matrix with bounded loaded rows (257 and 34),
  approximately 164 MB and 190 MB peak process-tree RSS, and zero missed budgets. The final requested-
  120 extreme diagnostic preserves one insertion-time miss per profile (12.6291 and 13.3326 ms at
  `streaming-entry-visible`) in addition to the unmet display precondition.

## Result

Settings visual alignment remains excluded as requested. Main-surface visual and interaction
alignment passed. Physical 120 Hz certification still requires an online 120 Hz display, and its
extreme workflow rerun must also clear the retained insertion-time misses.

final design result: passed; physical 120 Hz performance certification pending
