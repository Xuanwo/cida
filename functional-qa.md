# Functional QA

## Release contract

Cida's release decision is based on one signed Release `.app`, not on a Debug preview build. The
artifact manifest records the source commit, clean state, Developer ID signature, executable digest,
and complete app-tree digest. Swift tests, Tart XCUI, mutation contracts, and performance runners
consume that artifact or the same source commit, and the final gate verifies the app-tree digest
again.

The current core experience contract includes:

1. Real native typing, selection, paste, multiline growth, deletion-driven shrink, Return submit,
   and immediate native composer reset.
2. An atomic submit transition that clears the composer, folds the previous automatic current
   record, creates an empty current waiting result, and force-pins history.
3. Delayed-first-byte, bursty, character-at-a-time, paused, cancelled, failed, and recovered
   OpenAI-compatible streaming.
4. Display-linked smoothing, bounded grapheme batches, 120 ms tail blur/fade, waiting caret, and
   coalesced TextKit natural-height publication.
5. Automatic follow through terminal completion, deliberate user detachment, and reattachment on a
   new accepted submission.
6. One outer result/history scroll surface, correct 4 pt custom thumb direction, and sticky result
   actions for long records.
7. Latest-only automatic expansion, independent manual comparisons, bounded folded previews, full
   source/result restoration after manual expansion, full copy from folded records, and no hidden
   full-result layout. Folded, current, and manually expanded records are states of one native
   history-entry renderer.
8. Native Command-C precedence, hover-only terminal actions, streaming action suppression, and
   copied-state reset.
9. DeepSeek/OpenAI selection, editable local endpoint and model, Keychain API-key persistence and
   clearing, prompt edit/reset, and source-language-preserving improvement.
10. SQLite order/content/state persistence, interrupted-stream recovery, cursor pagination, and
    malformed-row isolation.
11. Standard macOS close, minimize, zoom, resize, focus, and Settings lifecycle behavior.
12. Exact one-million-character input, one-million persisted rows, and one thousand
    one-million-character records in isolated correctness/performance workloads.

Production starts without design records or mock output. Automation redirects only its database,
preferences, Keychain namespace, local endpoint, and diagnostics; it does not replace the production
model, storage, window, history, or renderer paths.

## Root repairs in the current refactor

| Risk | Root repair | Regression oracle |
| --- | --- | --- |
| Old result survives a new submit | Submission now transfers the latest marker and mounts a new empty result in the same accepted event; pooled result views clear TextKit and compositor state before reuse. | Controlled-first-byte Tart journey checks the new current identity, empty output, forbidden old pixels, and prior-row fold. Pool-capacity journey repeats beyond the prewarmed pool. |
| Composer sometimes remains populated or becomes uneditable | Native reset synchronization is generation-aware: a stale binding echo is cleared, while a genuine edit made after the reset is preserved. Empty macOS AX values are normalized without confusing `nil` with a failed reset. | Native responder-chain tests, real typing/paste/delete XCUI, atomic-submit unit test, and two consecutive-submit journeys. |
| A passing test only proved an AX string | Current/expanded state is asserted through visible product structure: current semantic label, source and result presence, absence of the folded card; folded state requires the inverse structure. | Shared driver applies the invariant to every submit. Direct mutation of the latest marker is killed by unit and Tart tests. |
| Folded and expanded records drifted because two layout engines owned the same component | `HistoryEntryNSView` now owns header, source, result, actions, fades, accessibility, and exact geometry for every presentation state. SwiftUI selects one explicit `folded`, `current`, or `manuallyExpanded` presentation; `HistoryRenderContract` derives content and disclosure behavior without an `isLatest` rendering flag. Native child controls and the entry-local fallback own pointer routing; the window does not scan the view tree. | Pure presentation-matrix tests require both expanded states to show source and result; structural hierarchy tests require all three states to resolve to `HistoryEntryNSView`; native window events exercise standard AppKit hit testing; identity/geometry tests exercise every state transition; Tart asserts that every expanded record restores its source, preserves spacing, and accepts source/result actions. Source and hit-routing mutations must be killed. |
| SwiftUI and AppKit colors or spacing drifted independently | Both frameworks resolve semantic colors through `CidaDesign.Palette` and history measurements through `HistoryEntryPencilLayout`; renderer files contain no duplicate design RGB constants. | Token tests pin every shared sRGB value, opacity, folded height, row stride, action column, and source fade measurement. |
| Some UI suites were silently absent from PR | The PR selector names every UI suite, and a source-enumerating unit test fails if a new `*Tests.swift` suite is not selected. | `PairwiseManifestTests/testPRGateIncludesEveryReleaseUITestSuite`. |
| Settings could open but not work | Stable identifiers now cover provider, endpoint/model, API key, prompt editor/reset, and launch-at-login. Prompt editing, close/reopen, reset, provider switch, local endpoint, and official endpoint reset form one E2E state machine. | `WindowAndSettingsJourneyTests`, persistence relaunch, and Settings pixel baseline. |
| Improvement followed translation language selectors | Improvement uses `preserve_source` with no source/target translation parameters; UI history and hints derive from detected input language. | English and Chinese improvement journey plus request-body contract tests. |
| Backend timing was visually abrupt | Network arrival is decoupled from presentation by a view-bound display link and adaptive buffer. A single bounded tail layer implements Pencil blur/fade without per-character layers or whole-document filtering. | Bursty/character stream tests, real uneven SSE journey, layer/animation token tests, and performance probe. |
| Streaming growth lost follow or caused layout churn | Native result storage notifies the existing TextKit view directly; suffix append and natural-height updates avoid rebuilding folded history. Force-pin and terminal revisions bypass stream throttling when required. | Detached/follow integration, uneven stream journey, layout-coalescing tests, and no-reconfiguration tests. |
| Large history scroll rebuilt full results | SQLite loads bounded pages; AppKit recycles only viewport folded rows and reads cached grapheme-safe previews. | 5,000-row recycler tests, 1,000-row sustained scroll, and exact extreme workflows. |
| A PR could pass without naming the hot-path invariants it relied on | Every gate reruns a dedicated proxy stage for bounded history reads, viewport-only materialization, incremental result layout, layout coalescing, and large-document virtualization. PR summaries explicitly stop at proxy coverage; nightly/release summaries additionally require physical view-bound reports from a 120 Hz display. | `performance-proxies` gate stage plus physical streaming, million-paste, history-scroll, and extreme reports. |
| Scrollbar direction or duplicate system thumb regressed | Custom indicators use top-origin normalized geometry and suppress reinstalled AppKit overlay scrollers while retaining native scroll behavior. | Native direction/reinstallation tests and two-position WindowServer pixel assertions. |

## Test layers

| Layer | Environment | Current role |
| --- | --- | --- |
| State/storage | Swift XCTest | model transitions, typed request envelope, SQLite, deterministic property sequences, report validation |
| Native components | AppKit XCTest | responder chain, TextKit append/layout, pooling, hover, geometry, indicators, background windows |
| Release E2E | fresh headless Tart clone | real signed app, WindowServer, XCUI input, local SSE, persistence, screenshots, accessibility |
| Mutation | temporary clean clone | deliberately reintroduce known faults; designated unit and Release tests must fail |
| Performance | nonactivating physical-display runner | display-link cadence, main-actor latency, missed budgets, exact workloads, RSS and artifact digest |

The host Swift suite currently contains 144 tests: 50 model/report tests, 7 SQLite tests, 4 host
isolation tests, 72 native interaction/layout tests, 3 mutation invariants, 2 suite/matrix manifest
tests, 4 loopback integration tests, and 2 deterministic journey-model tests.

The Release XCUI target contains 26 tests across ten files: 23 product journeys and three harness
self-tests. The product journeys cover signed-artifact smoke,
composer and copy behavior, controlled and uneven streams, cancellation/error recovery, scroll
direction and follow, history presentation/actions, persistence, shared state-machine relaunch,
Main/Settings pixel baselines, accessibility audit, and standard window/Settings behavior.

## Test-system self-verification

All UI waits use one 20 ms polling primitive that samples immediately, records value transitions,
and attaches its timeline to the XCResult on timeout. Three deterministic harness tests use an
injectable clock to prove that 100 ms, 200 ms, and 800 ms transient states are observable and that a
timeout retains its changed-value history. Tart failures write a machine-readable classification as
`infrastructure`, `build`, `source-test`, `ui-assertion-or-crash`, or `artifact`; an ambiguous UI
failure is never automatically labeled as a product regression.

The mutation catalog now contains fourteen source-level faults. Each definition pins an exact source
anchor and names its unit and/or Release kill tests. Catalog drift fails before an expensive build
or VM launch. In addition to submit-reset coverage, the
`history-presentations-bypass-unified-renderer` mutation forces every standalone record into the
folded presentation; native state/geometry tests and the visible Tart history journey reject it.
The `expanded-history-source-stays-hidden` mutation restores the reported latest-only source gate;
the same native geometry test and real expanded-history journey must reject it.
The `history-action-hit-target-swallowed` mutation disables the history control's entry-local action
fallback; the regression must fail before an icon can appear interactive while a wrapper consumes
the click. Standard AppKit child-control hit testing and this local fallback own pointer routing; the
window never scans the view tree for history actions.

The checked-in pairwise manifest provides a stable inventory of light/dark, reduced motion,
scrollbar preference, window size, lifecycle, and content combinations, and its pair coverage is
mathematically verified. It is not currently executed as eight separate Tart configurations, so it
must not be presented as a completed environment matrix. The release gate's executable coverage is
the 23 deterministic journeys above.

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

- `swift test -Xswiftc -warnings-as-errors`: 144/144 passed.
- Focused fresh-clone Tart diagnosis reproduced both the source-preview frame overflow and the
  recycled folded-row click failure. After the root repairs, both previously failing journeys passed
  2/2 with a healthy host-session guard and no host artifact activation. The native semantic audit
  also passes after the result action exposes only its real button rather than a roleless overlay.
- The complete source mutation catalog validates all 14 exact anchors.
- The complete clean-checkout PR gate for this repair writes its machine-readable result to
  `TestResults/gates/expanded-history-source-final-rerun-20260818/gate-summary.json`.

## Performance acceptance boundary

The performance runner uses the exact manifest-bound app with activation policy `.accessory`, orders
its transparent probe behind existing windows, and fails if the app activates or the probe becomes
key. Focused gates require a detected 120 Hz display, at least 118.8 native display-link callbacks
per second, P99 and main-actor latency within the configured budget, zero missed budgets for strict
workloads, and complete workload-specific invariants.

Tart frame rate is never used as 120 Hz evidence. If only a 60 Hz display is detected, correctness
and diagnostic latency can still be reported, but physical 120 Hz certification remains pending.
