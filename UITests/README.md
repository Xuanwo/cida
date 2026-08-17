# Release E2E regression system

The macOS E2E suite exercises a signed `release` build in a fresh, headless Tart clone. It never
launches Cida, changes the pasteboard, or takes focus in the host session.

## Test contract

- `scripts/e2e/build-release-artifact.sh` builds, signs, and records the exact app digest.
- `scripts/test-ui-in-tart.sh` verifies that artifact, clones `cida-ui-golden`, starts Tart with
  `--no-graphics --no-audio --no-clipboard`, disables guest Ethernet, and mounts source read-only.
- `UITests/Fixtures/e2e_scenario_server.py` provides a deterministic OpenAI-compatible local
  endpoint. Tests release response headers and chunks through named gates instead of sleeping.
- `SQLiteHistoryFixture` seeds each journey's isolated production-schema database before launch.
- Every UI test starts with a new app container, database, Keychain service, and pasteboard.
- Application assertion failures are never retried. Only a failed Tart boot may use one fresh
  clone retry.

The checked-in UI test host compiles the driver and assertions only. The app under test always
comes from `CIDA_UI_TEST_APP_PATH`; Debug-only preview fixtures are not an E2E execution path.

## Journey ownership

| File | Contract |
| --- | --- |
| `CidaReleaseArtifactSmokeTests.swift` | signed artifact provenance and a production translation |
| `ComposerJourneyTests.swift` | responder-chain typing, multiline growth/shrink, paste, submit, and Command-C precedence |
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

Full release suite:

```sh
scripts/test-ui-in-tart.sh
```

Selected journeys against a newly built artifact:

```sh
CIDA_TART_RESULTS_DIR="$PWD/TestResults/selected" \
CIDA_UI_TEST_ONLY_TESTING='CidaUITests/CoreTranslationJourneyTests,CidaUITests/ComposerJourneyTests' \
scripts/test-ui-in-tart.sh
```

Reuse is allowed only when product source is unchanged; the runner verifies the digest before and
after the guest run:

```sh
CIDA_E2E_REUSE_ARTIFACT=1 \
CIDA_TART_RESULTS_DIR="$PWD/TestResults/selected" \
CIDA_UI_TEST_ONLY_TESTING='CidaUITests/VisualAndAccessibilityJourneyTests' \
scripts/test-ui-in-tart.sh
```

Artifacts include `CidaUITests.xcresult`, `xcresult-summary.json`, signed Release artifact metadata,
scenario request logs, VM progress, guest logs, screenshots, video, and retained audit diagnostics.

Regenerate the project after adding or removing UI source files:

```sh
xcodegen generate --spec UITests/project.yml
```

The VM is a correctness and final-composition target, not proof of 120 Hz presentation. The
nonactivating hardware performance gates consume the same Release artifact manifest and run
separately on a detected 120 Hz display.
