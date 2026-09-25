# Release E2E regression system

The macOS E2E suite exercises an exact signed Release artifact in a fresh, headless Tart clone. It
does not launch Cida on the host, share the host pasteboard, or request host focus.

## Test contract

- `scripts/e2e/build-release-artifact.sh` builds and signs one app, then records its source commit,
  clean/dirty state, signing identity, executable digest, and complete app-tree digest.
- `scripts/test-ui-in-tart.sh` verifies the supplied artifact, stages a byte-identical copy into the
  writable result share, clones `cida-ui-golden`, starts Tart with
  `--no-graphics --no-audio --no-clipboard`, disables guest Ethernet, and mounts source read-only.
- Both the source artifact and its staged copy are verified after the guest exits. Unified gates also
  require a clean checkout, a manifest commit equal to `HEAD`, and a Developer ID signature.
- `UITests/Fixtures/e2e_scenario_server.py` provides a deterministic OpenAI-compatible local
  endpoint. Tests release response headers and chunks through named gates instead of sleeping.
- Every UI test starts with a unique settings domain, Keychain service, and VM-only pasteboard.
  Nothing persists between launches except settings; the panel starts empty.
- Application assertion failures are never retried. Only a failed Tart boot may use one fresh
  clone retry.
- Host snapshots record the frontmost app, pasteboard change count, and production Cida processes
  before and after each Tart run. A separate 100 ms monitor fails closed if either exact artifact copy
  is launched or takes focus on the host. `--no-clipboard` is the pasteboard isolation guarantee;
  frontmost-app, pasteboard, and production-Cida changes remain diagnostics so normal user activity
  during a long run is not misclassified as a test mutation. A missing, dead, or discontinuous
  monitor fails the run.

The checked-in UI test host compiles the driver and assertions only. The app under test always
comes from `CIDA_UI_TEST_APP_PATH`; Debug-only preview fixtures are not an E2E execution path.

## The panel under test

The app is a menu-bar application whose main interface is a borderless floating panel
(`app.windows["辞达"]`). The driver in `Support/CidaAppDriver.swift` works with these identifiers:

| Element | Identifier |
| --- | --- |
| source editor | `composer-input` |
| action segment / items | `action-segment`, `action-translate`, `action-improve` |
| control bar slot | `bar-action-stop`, `bar-action-copy`, `bar-action-copied` |
| result pane / text | `result-pane`, `result-text` |
| result notes | `result-note-stale`, `result-note-stopped`, `result-note-failed`, `result-note-unrecognized` |
| capture overlay / canvas | `capture-overlay`, `capture-overlay-canvas` |

⏎ submits, Tab switches the action, Escape hides, Option-Space shows, ⌘, opens Settings, ⌘C copies
the result when nothing is selected, ⌘. stops. There is no send button and no title bar.

## Journey ownership

| File | Contract |
| --- | --- |
| `CidaReleaseArtifactSmokeTests.swift` | signed artifact provenance and a production translation |
| `ComposerJourneyTests.swift` | responder-chain typing, panel growth and shrink with the source, submit keeps the source, stale marking, source-language-preserving improvement, and Command-C precedence |
| `CoreTranslationJourneyTests.swift` | delayed first byte, uneven SSE, panel growth, result replacement, stop, inline failure, and recovery |
| `TranslationStateMachineJourneyTests.swift` | shared model/UI consecutive-submit, completion, hide, and show invariants |
| `PanelAndSettingsJourneyTests.swift` | Escape/Option-Space lifecycle, default action on show, select-all on show, the model service configured by the artifact's own command line while Settings is open (onboarding card, copied prompt, live status, 检查 and a failed check), prompt editing, recording the global shortcut, bringing in the frontmost selection, and framing text with the capture shortcut |
| `VisualAndAccessibilityJourneyTests.swift` | approved empty-panel and Settings design pixels and the native semantic accessibility audit |

`Resources/Scenarios/pairwise-environment-v1.json` is a stable-seed pairwise environment matrix.
`PairwiseManifestTests` mathematically verifies that every value pair remains covered. The manifest
is an inventory, not an executed Tart configuration matrix.

## Visual and accessibility gates

`Resources/VisualBaselines/manifest.json` pins the baseline namespace, approved implementation
image, the board's render of the state, the board file, their SHA-256 digests, masks, and pixel thresholds.
A failure retains approved/current/design/diff attachments in the `.xcresult`; changing a
threshold or baseline is a reviewable source change. The approved images come from
`scripts/capture-design-states.sh`, which renders the same states offscreen without activating
anything on the host.

The native accessibility gate covers element detection, hit regions, descriptions, actions, and
parent/child relationships. Contrast is intentionally owned by the exact design pixel contract so
the audit cannot silently recolor an approved design. The empty XCTest Touch Bar proxy keeps its
narrow recorded exception.

## Run

Use the unified profiles for gate decisions:

| Profile | Required work |
| --- | --- |
| PR | full Swift suite, one exact Release artifact, P0 Tart journeys, unit mutation contracts |
| Release | full Tart suite, unit mutation contracts, focused 120 Hz gates when the host has a 120 Hz display |
| Nightly | release plus the Release mutation contracts; run it after changing the journeys or a mutated file |

These profiles require a clean, committed checkout:

```sh
scripts/e2e/run-pr-gate.sh
scripts/e2e/run-nightly-gate.sh
scripts/e2e/run-release-gate.sh
```

Every profile writes a
machine-readable `gate-summary.json` with stage status, artifact provenance, UI summaries,
mutation summaries, host guards, performance reports, and the final app digest comparison. Mutation
anchor drift is validated before any expensive build or VM work.

For a standalone full UI diagnostic that builds its own artifact:

```sh
scripts/test-ui-in-tart.sh
```

To run selected journeys against a prebuilt exact artifact, keep the artifact outside the Tart result
directory because the runner stages a verified copy into that directory:

```sh
artifact_root="$PWD/TestResults/manual-artifact/ReleaseArtifact"
scripts/e2e/build-release-artifact.sh "$artifact_root"

CIDA_RELEASE_ARTIFACT_ROOT="$artifact_root" \
CIDA_TART_RESULTS_DIR="$PWD/TestResults/selected" \
CIDA_UI_TEST_ONLY_TESTING='CidaUITests/CoreTranslationJourneyTests,CidaUITests/ComposerJourneyTests' \
scripts/test-ui-in-tart.sh
```

Artifacts include `CidaUITests.xcresult`, `xcresult-summary.json`, signed Release artifact metadata,
scenario request logs, VM progress, guest logs, screenshots, video, host-session snapshots and guard,
retained audit diagnostics, and one panel lifecycle log per app launch under `lifecycle/`. The
driver launches the app with `--automation-lifecycle-log`, so the log records the activation
policy, app activation, and the panel's visibility, key status, alpha, and frame at launch, at every
show, and at every key-window transition: XCUI cannot observe any of that for a non-activating
panel, and the log is what separates "never shown" from "hid on resign key" or "shown transparent".
The global shortcut adds `selection-imported` or `selection-kept` before each show it causes.

Before the XCUI run the guest grants Cida Accessibility and Screen Recording by writing the system
TCC database (the golden image has SIP disabled) and restarting `tccd`. Selection and capture
journeys therefore run their production paths against the UI test host, which stands in for the
application the user works in: the global shortcut reads the selection in its editor through the
Accessibility API, and the capture shortcut freezes the guest's display with ScreenCaptureKit and
recognizes the host's line of text with Vision. The Settings pixel baseline shows the state before
any permission is granted, so it launches with `--automation-permissions denied`. The capture
shortcut adds `capture-overlay-shown`, then `capture-imported`, `capture-unrecognized` or
`capture-cancelled`, to the lifecycle log.

Regenerate the project after adding or removing UI source files:

```sh
xcodegen generate --spec UITests/project.yml
```

The VM is a correctness and final-composition target, not proof of 120 Hz presentation. The
nonactivating hardware performance gates consume the same manifest-bound Release artifact and run
separately on a detected physical 120 Hz display.
