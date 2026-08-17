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
- `SQLiteHistoryFixture` seeds each journey's isolated production-schema database before launch.
- Every UI test starts with a new app container, database, Keychain service, and pasteboard.
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

## Journey ownership

| File | Contract |
| --- | --- |
| `CidaReleaseArtifactSmokeTests.swift` | signed artifact provenance and a production translation |
| `ComposerJourneyTests.swift` | responder-chain typing, multiline growth/shrink, paste, submit, source-language-preserving improvement, and Command-C precedence |
| `CoreTranslationJourneyTests.swift` | delayed first byte, uneven SSE, follow, reuse, cancel, failure, and recovery |
| `HistoryAndScrollingJourneyTests.swift` | one outer scroll surface, Pencil thumb direction, detach, and reattach |
| `HistoryPresentationJourneyTests.swift` | fold/expand, full copy, action geometry, streaming action policy, and sticky long-result action |
| `PersistenceJourneyTests.swift` | SQLite relaunch and OpenAI endpoint/model/API-key persistence and clearing |
| `WindowAndSettingsJourneyTests.swift` | native close/minimize/zoom/resize and editable settings |
| `VisualAndAccessibilityJourneyTests.swift` | approved Pencil pixels and native semantic accessibility audit |

`Resources/Scenarios/pairwise-environment-v1.json` is a stable-seed pairwise environment matrix.
`PairwiseManifestTests` mathematically verifies that every value pair remains covered.

## Visual and accessibility gates

`Resources/VisualBaselines/manifest.json` pins the baseline namespace, approved implementation
image, Pencil reference, `Design/cida.pen`, their SHA-256 digests, masks, and pixel thresholds.
A failure retains approved/current/Pencil/diff attachments in the `.xcresult`; changing a
threshold or baseline is a reviewable source change.

The native accessibility gate covers element detection, hit regions, descriptions, actions, and
parent/child relationships. Contrast is intentionally owned by the exact Pencil pixel contract so
the audit cannot silently recolor an approved design. Two macOS 26.4 system-owned proxies have
narrow recorded exceptions: the private decoration inside a standard window control, and the empty
XCTest Touch Bar proxy. The handler keeps diagnostics and rejects every application-owned issue.
Hover actions are made visible explicitly before the audit so coverage does not depend on mouse
position or test order.

## Run

Use the unified profiles for gate decisions:

| Profile | Required work |
| --- | --- |
| PR | full Swift suite, one exact Release artifact, P0 Tart journeys, unit mutation contracts |
| Nightly | full Tart suite, all unit/Release mutations, focused 120 Hz gates, extreme smoke |
| Release | nightly correctness plus three fresh P0 burn-ins and the full extreme 120 Hz matrix |

These profiles require a clean, committed checkout:

```sh
scripts/e2e/run-pr-gate.sh
scripts/e2e/run-nightly-gate.sh
scripts/e2e/run-release-gate.sh
```

The Release burn-in defaults to three rounds and may be raised with
`CIDA_GATE_BURN_IN_ROUNDS`; values below two are clamped to two. Every profile writes a
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
and retained audit diagnostics.

Regenerate the project after adding or removing UI source files:

```sh
xcodegen generate --spec UITests/project.yml
```

The VM is a correctness and final-composition target, not proof of 120 Hz presentation. The
nonactivating hardware performance gates consume the same manifest-bound Release artifact and run
separately on a detected physical 120 Hz display. Their CoreVideo report records the physical display
cadence, main-actor callback latency, activation/key-window observations, hardware and power state,
and the exact app-tree digest.
