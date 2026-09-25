# Developing Cida

Cida is a Swift 6.2 package (SwiftUI and AppKit) for macOS 15 or newer. Building it needs Xcode 26 or newer: the app icon is an Icon Composer file that only Xcode 26's `actool` compiles.

The design in [`Design/`](../Design/README.md) is the first source for how Cida looks and behaves; [`AGENTS.md`](../AGENTS.md) lists the working rules for changes.

## Build and run

```sh
swift run Cida
swift test
```

`scripts/build-app.sh release` builds the Release app bundle at `build/Cida.app` without launching it. It signs with the first Developer ID Application identity in your keychain (or `CIDA_CODESIGN_IDENTITY`), because the Keychain item that holds the API key is bound to a stable signature. `CIDA_VERSION` and `CIDA_BUILD_NUMBER` set the bundle version; without them it keeps the one in `Resources/Cida-Info.plist`.

To hand the app to another Mac, notarize it:

```sh
scripts/notarize-app.sh
```

It submits `build/Cida.app` to Apple's notary service, staples the ticket, checks that Gatekeeper accepts the app as notarized, and writes `build/Cida-<version>-<build>.zip`. Locally it reads credentials from the notarytool keychain profile `cida-notary` (or `CIDA_NOTARY_PROFILE`), created once with `xcrun notarytool store-credentials cida-notary --apple-id <id> --team-id <team>` and an app-specific password.

Provider keys are stored only in Keychain; prompts, model IDs, the custom endpoint, and other non-secret preferences are stored in UserDefaults. Nothing else is persisted: the panel starts empty on every launch, and no record of past requests is written anywhere.

Prompts are stored as stable task policies rather than string templates. Each request sends the operation and language choices as a typed, trusted parameter envelope in the system message, while the complete source document appears exactly once in the user message. Legacy `{text}` and `{target_lang}` prompts migrate once; braces in current prompts remain literal text.

## Screenshots

`scripts/capture-design-states.sh` captures every panel and Settings state from an isolated, non-activating build into `Design/ImplementationCurrent` and compares each with its board.

The README's `docs/images/demo.gif` is a screen recording of the signed Release app driven by an XCUI journey in a Tart guest: a selection translated with ⌥Space, improved with Tab, and a line framed with ⌥S. The model's replies came from the loopback scenario server, and the desktop's widgets were hidden. That recording journey is not part of the regression suite; when the panel's look or the flow changes, record the demo again the same way.

## Verification

Run a release decision from a clean, committed checkout with one of the unified gates:

```sh
scripts/e2e/run-pr-gate.sh
scripts/e2e/run-nightly-gate.sh
scripts/e2e/run-release-gate.sh
```

Every profile first validates every mutation anchor, runs the complete Swift suite, and reruns four
named structural performance proxies before it builds and signs one Release app, binds its manifest
to the current commit, and verifies the app-tree digest again after all consumers finish. The PR
profile runs the P0 Release journeys in Tart and the unit mutation contracts. Nightly runs the full
Tart suite, all unit and Release mutations, and the focused 120 Hz workloads. Release adds three
fresh-clone P0 burn-in rounds by default. Each invocation writes a single `gate-summary.json`;
standalone scripts are diagnostic entry points, not a release verdict. After the harness contract
check, nightly and release profiles query AppKit and Core Graphics for an awake, active display whose
native maximum is at least 120 Hz. An unavailable physical frame clock is classified as
infrastructure and stops the gate before builds, Tart clones, or mutation runs.

Useful standalone diagnostics are:

```sh
swift test -Xswiftc -warnings-as-errors
scripts/test-ui-in-tart.sh
scripts/e2e/run-focused-tart-diagnostic.sh \
  CidaUITests/CoreTranslationJourneyTests/testNewSubmissionIsVisiblyEmptyUntilItsControlledFirstByte
scripts/capture-design-states.sh
scripts/test-release-input-interaction.sh
scripts/benchmark-frame-pacing.sh
scripts/benchmark-smooth-streaming.sh
scripts/benchmark-million-character-paste.sh
```

The focused Tart diagnostic performs an incremental host compile, runs exactly one selected XCUI
journey in a fresh no-graphics VM, and skips the duplicate guest Swift preflight. It is intentionally
not a release verdict; every delivery still requires one of the unified gates above.

The XCUI regression runs inside a fresh clone of the local `cida-ui-golden` macOS VM through [Tart](https://github.com/cirruslabs/tart). Tart starts without graphics, audio, or host clipboard sharing; the guest network is disabled, the repository is mounted read-only, and only the selected result directory is writable from the VM. The exact signed artifact is copied into that writable share, verified against its source digest, consumed by the guest, and reverified on the host after the run. The ephemeral clone is deleted after every attempt, so the test never launches a host application or reads the production API key, UserDefaults, or Keychain. A 100 ms host monitor fails if either exact artifact copy is launched or takes focus on the host; frontmost-app, pasteboard, and production-Cida changes caused by concurrent user activity remain recorded diagnostics. See `UITests/README.md` for the golden-image contract and artifacts.

Standalone design snapshots and native input probes use a fresh temporary `辞达测试.app` with a unique `com.xuanwo.Cida.Automation.*` bundle identifier. Release performance gates instead launch the exact manifest-bound `Cida.app` in an isolated automation data directory. The performance instance orders its panel behind existing windows, never activates the application or makes its panel key, and reports fail if activation or a key panel is observed.

The in-process integration suite and the VM XCUI suite both start a loopback OpenAI-compatible SSE server. XCUI drives the visible guest panel through Settings, the OpenAI endpoint, model and API Key editors, multiline growth and shrink of the source pane and the panel, submit with the source retained, stale marking, consecutive submissions, uneven streaming, stop and inline failure, hover-free copy, Escape and Option-Space, the empty-panel and Settings pixel baselines, the native accessibility audit, and the exact outbound request body. A separate Release executable gate routes a real mouse click through AppKit hit testing, performs an isolated focus handoff, sends real key-down events, and verifies the native editor and `AppModel` receive identical text. UI waits use an immediately sampled 20 ms polling primitive with timeout timelines, and harness self-tests prove that short-lived feedback cannot be skipped. Tart writes a machine-readable failure category before a failed run is interpreted as a product regression. No external credential or network service is used. `CIDA_UI_TEST_ONLY_TESTING` can select one XCUI identifier for diagnosis; omitting it always runs the complete regression suite.

The strict performance gates require a detected 120 Hz-capable display, at least 118.8 measured native display-link callbacks per second, a P99 physical interval no greater than 12.5 ms, and zero main-actor callback latencies above the 12.5 ms budget. The focused gates collect 1,440 samples. Production stream pacing and the probe both use the panel's native Core Animation display link; the report labels it `view-bound-ca-display-link` and records native callback cadence separately from main-actor handling latency. A nonactivating fallback only keeps an unavailable display link from hanging the process; a 60 Hz or unavailable physical display still fails `displayRequirementSatisfied` and cannot produce a passing 120 Hz report. PR gates report structural proxy coverage without claiming an FPS result; nightly and release summaries cannot pass unless at least one physical report confirms a 120 Hz display and the view-bound clock.

## Releasing

Pushing a tag `vX.Y.Z` on a commit of `main` publishes a release through `.github/workflows/release.yml`; `vX.Y.Z-rc.N` publishes a prerelease. On a `macos-26` runner the workflow runs `swift test`, builds with the tag's version and the commit count as the build number, signs with the Developer ID identity, notarizes, and attaches `Cida-<version>-<build>.zip` and its SHA-256 to a GitHub release with generated notes.

GitHub's runners cannot run the Tart journeys, so run the release gate on the commit before tagging it:

```sh
scripts/e2e/run-release-gate.sh
```

The workflow reads these repository secrets:

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_P12` | The Developer ID Application certificate and its private key, exported from Keychain Access as `.p12`, in base64 (`base64 -i Cida.p12`) |
| `DEVELOPER_ID_P12_PASSWORD` | The password chosen for that export |
| `NOTARY_API_KEY` | The contents of an App Store Connect team API key (`AuthKey_<id>.p8`) with the Developer role |
| `NOTARY_API_KEY_ID` | That key's ID |
| `NOTARY_API_ISSUER` | The issuer ID shown above the team keys |

`scripts/ci/import-signing-identity.sh` imports the identity into a keychain of the job's own, which the workflow deletes when it ends.

## Architecture

- SwiftUI owns the panel composition and observable application state. AppKit owns the non-activating floating panel, the global shortcut, the menu-bar item, native text controls, keyboard routing, result rendering, snapshots, and performance instrumentation. `PanelController` sizes the panel from the height its content reports and keeps the top edge fixed, so the panel only ever grows downward over the design's 150 ms height transition. `AppModel` holds one `ResultRecord`: the source and action it was made from, its streamed text, and its phase (streaming, completed, stopped, failed). Both frameworks derive colors and typography from one semantic `CidaDesign` token set: Inter for the source, Source Serif 4 and Noto Serif SC for the result, accent only on the selected action, the caret, and the copied feedback.
- Model requests keep stable prompt policy, typed runtime parameters, and untrusted source content separate. Translation sends the detected source language and the other language of the supported pair as target; improvement sends `preserve_source` without either translation language, so every source passage stays in its original language. The same contract is used for OpenAI, compatible remote providers, and loopback mock endpoints without requiring provider-specific template syntax.
- Streamed results use a lightweight TextKit 1 rendering view and materialize a native selection editor only when needed. The result storage publishes an append notification, so TextKit appends only the missing UTF-16 suffix without invalidating the SwiftUI tree. A view-bound `CADisplayLink` adaptive presenter smooths uneven network delivery at 30–400 grapheme clusters per second with a maximum of eight grapheme clusters per update.
- Each streamed run is laid out on the display pulse that presents it and painted by a short-lived fragment view that fades in from transparent and unblurs from 2 pt over the design's 120 ms ease-out behind the inline caret; the renderer skips those glyphs until the fade completes and then paints them in place. The result pane grows with its text until the panel reaches its height budget, then scrolls and keeps the tail in view while streaming unless the user scrolled away; a completed result opens at its top.
- The source and result panes are native `NSScrollView`s pinned to the system overlay scroll bar (`OverlayScrollView`): it appears while scrolling or hovering, fades out at rest, and never switches to the legacy track that a mouse or the "Always" preference would otherwise bring. The result scroll view spans the pane and insets its text, so both bars sit on the panel's right edge.
- The source editor uses a full backing document with a virtualized TextKit viewport. Documents of at least 100,000 UTF-16 units materialize only the final 512 units; upward scrolling prepends earlier 1,024-unit pages on demand. The pane's height is measured from the laid-out text after every native edit, so deleting lines shrinks the pane and the panel immediately. The SwiftUI binding is never written back into the editor while an input method is composing, so pinyin candidates survive unrelated re-renders.
- No idle display link or timer runs during normal use.

See [`functional-qa.md`](functional-qa.md) for regression evidence and [`design-qa.md`](design-qa.md) for the design comparison matrix.
