# Developing Cida

Cida is a Swift 6.2 package (SwiftUI and AppKit) for macOS 15 or newer. Building it needs Xcode 26 or newer: the app icon is an Icon Composer file that only Xcode 26's `actool` compiles.

The design in [`Design/`](../Design/README.md) is the first source for how Cida looks and behaves; [`AGENTS.md`](../AGENTS.md) lists the working rules for changes.

## Build and run

```sh
swift run Cida
swift test
```

`scripts/build-app.sh release` builds the Release app bundle at `build/Cida.app` without launching it. It signs with the first Developer ID Application identity in your keychain (or `CIDA_CODESIGN_IDENTITY`), because the Keychain item that holds the API key is bound to a stable signature. `CIDA_VERSION` and `CIDA_BUILD_NUMBER` set the bundle version; without them it keeps the one in `Resources/Cida-Info.plist`.

To try a change on your own Mac next to the released Cida, run the development build:

```sh
scripts/run-dev.sh        # build 辞达 Dev, quit the released Cida, start the development build
scripts/run-dev.sh stop   # quit the development build, start the released Cida again
```

`CIDA_VARIANT=dev scripts/build-app.sh release`, which the script runs, builds `build/Cida Dev.app`: bundle id `com.xuanwo.Cida.dev`, so its settings, API key and Accessibility and Screen Recording grants are its own and the released Cida keeps updating through Sparkle. It has no update feed, is versioned from the checkout (the latest release tag and the commit count, as a release is) and names itself in its menu and Settings (`Design/spec/updates.md` §三). Grant it the permissions once; they stay across rebuilds because the signature's designated requirement names only the bundle id and the team. Configure its model service once with its own command line, `"build/Cida Dev.app/Contents/MacOS/Cida" config …`. Both builds register the same global shortcuts, which is why only one runs at a time. Do not build the release bundle id with a made-up higher version to keep Sparkle away; that is what the development build replaces.

When the shortcuts feel slow on a Mac running a released build, its unified log says where the time went. Every ⌥A records the frontmost application, the Accessibility answer, the ⌘C fallback and the moment the panel showed, each with its milliseconds; ⌥D records the translation layer's lifecycle. Neither records any text:

```sh
/usr/bin/log show --last 1h --predicate 'subsystem == "com.xuanwo.Cida" AND category == "shortcut"'
/usr/bin/log show --last 1h --predicate 'subsystem == "com.xuanwo.Cida" AND category == "translation-layer"'
```

Call `/usr/bin/log` by its path: in zsh, `log` is a builtin that prints nothing.

To hand the app to another Mac, notarize it:

```sh
scripts/notarize-app.sh
```

It submits `build/Cida.app` to Apple's notary service, staples the ticket, checks that Gatekeeper accepts the app as notarized, and writes `build/Cida-<version>-<build>.zip`. Locally it reads credentials from the notarytool keychain profile `cida-notary` (or `CIDA_NOTARY_PROFILE`), created once with `xcrun notarytool store-credentials cida-notary --apple-id <id> --team-id <team>` and an app-specific password; `scripts/submit-notarization.sh` holds that submission for both the app and the DMG.

To pack the notarized app the way new users install it:

```sh
scripts/build-dmg.sh build/Cida.app build/Cida-<version>-<build>.dmg
```

It lays out the volume 辞达 as `Design/spec/lifecycle.md` §二 describes: a 600 × 400 Finder window on `Design/rendered/states/dmg-background.png` (turned into a TIFF with a 1x and a 2x representation), Cida.app and a link to /Applications named 应用程序 side by side at 128 pt. [dmgbuild](https://github.com/dmgbuild/dmgbuild), pinned by version and hash, writes that layout into the volume's `.DS_Store` without opening Finder; the script installs it into `build/dmgbuild-<version>` with Python 3.10 or newer (`CIDA_PYTHON` picks another interpreter). The DMG is compressed with LZFSE through `diskutil image`, signed with the app's Developer ID identity, notarized and stapled. It reads the same notary credentials as `scripts/notarize-app.sh`.

The model service's API key is stored only in Keychain; the model configuration (endpoint, request format, model, auth header, extra headers and body), prompts and other non-secret preferences are stored in UserDefaults. The app and its command line (`Cida config …`, `Cida check`; `Design/spec/configuration.md`) are one executable, so they share both stores without a Keychain prompt. Nothing else is persisted: the panel starts empty on every launch, and no record of past requests is written anywhere.

Prompts are stored as stable task policies rather than string templates. Each request sends the operation and language choices as a typed, trusted parameter envelope in the system message, while the complete source document appears exactly once in the user message. Legacy `{text}` and `{target_lang}` prompts migrate once; braces in current prompts remain literal text.

## Screenshots

`scripts/capture-design-states.sh` captures every panel and Settings state from an isolated, non-activating build into `Design/ImplementationCurrent` and compares each with its board. For PR screenshots, use only the native captures from that directory (or `Design/QACurrent/implementation-<state>.png`), labeled Before and After and stacked at a readable width. Board renders and stitched comparisons are local QA artifacts; do not embed them in PRs.

The README's demos (`docs/images/demo-*.gif`) are screen recordings of the signed Release app driven by XCUI in a Tart guest. The translation and capture clips use a local article in Chrome. The improvement, custom-action and in-place translation clips use a native writing fixture with public sample text. Model replies come from the loopback scenario server, so the recordings demonstrate interactions rather than remote-model quality. The guest display is 1512 × 982 pt at 2x; recording stays inside the guest, with no host capture or input. Keep the finalized movie as an XCTest attachment with `.keepAlways`, then export it with `xcrun xcresulttool export attachments`. Successful tests normally discard their automatic screen recordings. Decode from the start before cutting the exported movie: direct seeking can lose the reference frames needed by its screen-content encoding.

`scripts/make-demo-media.py <recordings> --only improve --only actions --only paragraph --only window --crop crop=2544:1632:240:120` turns those recordings into the READMEs' GIFs (1440 px wide), the website's H.264 clips (760 and 1520 px wide), and poster frames. It crops to the central working area, shortens idle stretches and holds the result before looping. Keep the original recordings and recording source with the task's verification evidence. Recording fixtures are separate from the regression suite; record affected clips again when a demonstrated flow changes.

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
profile runs the P0 Release journeys in Tart and the unit mutation contracts. Release runs the full
Tart suite, the unit mutation contracts and the focused 120 Hz workloads. Nightly also runs the
Release mutation contracts, which rebuild the app and boot Tart once per mutation to prove that the
journeys still catch each seeded defect; run it after changing `UITests` or a file in
`scripts/e2e/mutation-catalog.json`. Each invocation writes a single `gate-summary.json`;
standalone scripts are diagnostic entry points, not a release verdict. After the harness contract
check, nightly and release profiles query AppKit and Core Graphics for an awake, active display whose
native maximum is at least 120 Hz. When there is one, the physical 120 Hz workloads run and must
pass. When there is none, the gate skips them, decides on everything else, and records
`physical120HzSkippedReason` in `gate-summary.json`, so the release carries no physical frame-rate
certification.

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

The in-process integration suite and the VM XCUI suite both start a loopback OpenAI-compatible SSE server. XCUI configures the model service through the command line, as an AI assistant would, and drives the visible guest panel through Settings' model status, check and configuration prompt, multiline growth and shrink of the source pane and the panel, submit with the source retained, stale marking, consecutive submissions, uneven streaming, stop and inline failure, hover-free copy, Escape and Option-A, the empty-panel and Settings pixel baselines, the native accessibility audit, and the exact outbound request body. A separate Release executable gate routes a real mouse click through AppKit hit testing, performs an isolated focus handoff, sends real key-down events, and verifies the native editor and `AppModel` receive identical text. UI waits use an immediately sampled 20 ms polling primitive with timeout timelines, and harness self-tests prove that short-lived feedback cannot be skipped. Tart writes a machine-readable failure category before a failed run is interpreted as a product regression. No external credential or network service is used. `CIDA_UI_TEST_ONLY_TESTING` can select one XCUI identifier for diagnosis; omitting it always runs the complete regression suite.

The strict performance gates require a detected 120 Hz-capable display, at least 118.8 measured native display-link callbacks per second, a P99 physical interval no greater than 12.5 ms, and zero main-actor callback latencies above the 12.5 ms budget. The focused gates collect 1,440 samples. Production stream pacing and the probe both use the panel's native Core Animation display link; the report labels it `view-bound-ca-display-link` and records native callback cadence separately from main-actor handling latency. A nonactivating fallback only keeps an unavailable display link from hanging the process; a 60 Hz or unavailable physical display still fails `displayRequirementSatisfied` and cannot produce a passing 120 Hz report. PR gates report structural proxy coverage without claiming an FPS result; nightly and release summaries on a host with a 120 Hz display cannot pass unless its physical reports confirm 120 Hz and the view-bound clock, and on a host without one they state that the certification was skipped.

## Releasing

Pushing a tag `vX.Y.Z` on a commit of `main` publishes a release through `.github/workflows/release.yml`; `vX.Y.Z-rc.N` publishes a prerelease. On a `macos-26` runner the workflow reads the update notes, runs `swift test`, builds with the tag's version and the commit count as the build number, signs with the Developer ID identity, notarizes the app, builds, notarizes and staples `Cida-<version>-<build>.dmg` (`scripts/build-dmg.sh`), attaches the DMG and its SHA-256 to a GitHub release whose notes are the update notes, and publishes the zip as an update and the DMG as the download (`scripts/ci/publish-update.sh`). The zip is only Sparkle's archive and is not attached to the GitHub release.

After the release is published, run the Website workflow (`gh workflow run Website --repo Xuanwo/cida`) so cida.xuanwo.io shows the new version and its notes.

Every version needs update notes before it is tagged: `docs/releases/<X.Y.Z>.md`, written by hand in Chinese for users, one item per line starting with `- ` (`Design/spec/lifecycle.md` §六). A candidate `vX.Y.Z-rc.N` uses the notes of `X.Y.Z`. The workflow stops before building when the file is missing or has a line that is not an item (`scripts/ci/release-notes.py`); the notes go into the feed as plain text, one item per line, and Cida shows them in its panel.

Updates follow `Design/spec/updates.md`. The R2 bucket `cida-releases`, served at `https://cida-releases.xuanwo.io` with a Cloudflare cache rule that honours each object's `Cache-Control`, holds:

| Key | Cache | Written |
| --- | --- | --- |
| `appcast.xml` | 5 minutes | last, EdDSA-signed |
| `releases/<version>-<build>/Cida-<version>-<build>.zip` | a year, immutable | first; the archive Sparkle installs |
| `releases/<version>-<build>/Cida-<version>-<build>.dmg` | a year, immutable | second; that version's installer |
| `latest/Cida.dmg` | 5 minutes | for releases only, before the feed; the READMEs' download link |

The feed keeps the two newest builds of each channel (`Design/spec/updates.md` §四). After uploading the feed, the script deletes every `releases/` folder it no longer lists; if that fails, the job only warns and the next publish deletes them. The GitHub releases keep every version's DMG.

A release candidate's item carries Sparkle's `beta` channel, and its bundle carries `CidaUpdateChannel = beta`, so only candidates look for candidates. The EdDSA private key signs every zip and the feed; the app trusts only the public key in `Resources/Cida-Info.plist` (`SUPublicEDKey`). Losing the private key means shipped copies can no longer be updated, so keep the login keychain item "Private key for signing Sparkle updates" (service `https://sparkle-project.org`, account `cida`) backed up; Sparkle's `sign_update --account cida` signs with it locally.

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
| `SPARKLE_ED_PRIVATE_KEY` | Sparkle's EdDSA private key: base64 of the 32-byte Ed25519 seed |
| `R2_ACCESS_KEY_ID` | The access key of an R2 API token with Object Read & Write on the bucket `cida-releases` only |
| `R2_SECRET_ACCESS_KEY` | That token's secret access key |

`scripts/ci/import-signing-identity.sh` imports the identity into a keychain of the job's own, which the workflow deletes when it ends.

## Website

`website/` holds cida.xuanwo.io (`Design/spec/website.md`): the Chinese page, `en/`, `releases/`, the layout and motion in `site.css` and `site.js`, and the prepared fonts and clips in `assets/`. The pages load the design tokens, components and brand files from `Design/boards` and `Resources` rather than copies, so the site keeps the app's look. To build and look at it (needs the release tags, `git fetch --tags`):

```sh
scripts/build-website.py                # writes build/website
python3 -m http.server --directory build/website
```

The build copies `website/`, maps each path outside it to `/assets`, and fills the version and update notes from the newest `vX.Y.Z` tag. It fails when a page or an update note in `docs/releases` uses a character the committed font subsets do not cover; `scripts/build-website.py --subset-fonts` (with `pip install fonttools brotli`) makes them again. The clips come from `scripts/make-demo-media.py` (see Screenshots above).

The CI workflow builds the site on every pull request, as the required `website` check, since a change to the shared board files can break it. `.github/workflows/website.yml` deploys from `main` after a push that changes the site, with `wrangler deploy --config website/wrangler.jsonc`. A release does not redeploy it; after a release run `gh workflow run Website --repo Xuanwo/cida` so the page shows the new version and notes. The Worker `cida-website` only serves static assets, on the custom domain `cida.xuanwo.io`. The custom domain is attached to the Worker in Cloudflare, not listed in `wrangler.jsonc`, so a deploy never touches it. The deploy reads the repository secret `CLOUDFLARE_API_TOKEN`: an account API token of the Xuanwo account with the Workers Editor role scoped to the Worker `cida-website` only.

## Architecture

- SwiftUI owns the panel composition and observable application state. AppKit owns the non-activating floating panel, the global shortcut, the menu-bar item, native text controls, keyboard routing, result rendering, snapshots, and performance instrumentation. `PanelController` sizes the panel from the height its content reports and keeps the top edge fixed, so the panel only ever grows downward over the design's 150 ms height transition. `AppModel` holds one `ResultRecord`: the source and action it was made from, its streamed text, and its phase (streaming, completed, stopped, failed). Both frameworks derive colors and typography from one semantic `CidaDesign` token set: Inter for the source, Source Serif 4 and Noto Serif SC for the result, accent only on the selected action, the caret, and the copied feedback.
- Model requests keep stable prompt policy, typed runtime parameters, and untrusted source content separate. Translation sends the detected source language and the other language of the supported pair as target; improvement sends `preserve_source` without either translation language, so every source passage stays in its original language. The same contract is used for OpenAI, compatible remote providers, and loopback mock endpoints without requiring provider-specific template syntax.
- Streamed results use a lightweight TextKit 1 rendering view and materialize a native selection editor only when needed. The result storage publishes an append notification, so TextKit appends only the missing UTF-16 suffix without invalidating the SwiftUI tree. A view-bound `CADisplayLink` adaptive presenter smooths uneven network delivery at 30–400 grapheme clusters per second with a maximum of eight grapheme clusters per update.
- Each streamed run is laid out on the display pulse that presents it and painted by a short-lived fragment view that fades in from transparent and unblurs from 2 pt over the design's 120 ms ease-out behind the inline caret; the renderer skips those glyphs until the fade completes and then paints them in place. The result pane grows with its text until the panel reaches its height budget, then scrolls. A result is read from its start: while streaming, new text grows below the fold and the pane follows the tail only after the user scrolls down to it; a completed result opens at its top. An edge with text beyond it fades: `ResultEdgeFadeView` draws paper over the ink, as deep as the hidden text up to `result-fade`, so offscreen captures show it too (a layer mask would not render there).
- The source and result panes are native `NSScrollView`s pinned to the system overlay scroll bar (`OverlayScrollView`): it appears while scrolling or hovering, fades out at rest, and never switches to the legacy track that a mouse or the "Always" preference would otherwise bring. The result scroll view spans the pane and insets its text, so both bars sit on the panel's right edge.
- The source editor uses a full backing document with a virtualized TextKit viewport. Documents of at least 100,000 UTF-16 units materialize only the final 512 units; upward scrolling prepends earlier 1,024-unit pages on demand. The pane's height is measured from the laid-out text after every native edit, so deleting lines shrinks the pane and the panel immediately. The SwiftUI binding is never written back into the editor while an input method is composing, so pinyin candidates survive unrelated re-renders.
- No idle display link or timer runs during normal use.

See [`functional-qa.md`](functional-qa.md) for regression evidence and [`design-qa.md`](design-qa.md) for the design comparison matrix.


### Translation layer motion

`LayerPaneSession` owns one optional source-window stream and its reference revision. A settled AX
read supplies text, paragraph identity and base rectangles. `LayerMotionCapture` crops only that
pane from the source window through ScreenCaptureKit, excluding the overlay by construction. It
keeps images in memory on a serial processing queue and releases them when the pane closes, leaves
the screen, changes geometry or switches applications. Without an existing screen-recording grant,
the layer retains its AX-only fallback and does not request permission from a background task.

`LayerImageAnchor` searches the pane vertically against a paragraph's reference pixels using
normalized correlation and a competing-match check. A small vertical low-pass filter tolerates
subpixel text antialiasing. `LayerMotionReference` requires an unambiguous initial match; a failed
match, a capture gap of 100 ms, or a jump above 80 points invalidates that paragraph until another
AX read. No wheel deltas or cumulative displacements become paragraph coordinates. Frame results
older than 100 ms or belonging to a replaced reference/stream are ignored. Work is bounded to the
first 12 selected paragraphs per pane; other paragraphs use the settled-position fallback.

The overlay moves each matched paragraph and its waiting underlay without re-typesetting. Pane
clipping and occlusion masks remain fixed. Horizontal motion and AX-reported reflow invalidate the
reference. Reads racing motion are discarded. `TranslationLayerMotionTests` covers ambiguity,
identity loss, missing frames and per-paragraph rendering; the translation-layer Tart journey
requires both `layer-motion-ready` and `layer-motion-tracked` in the actual app's lifecycle log and
saves screenshots. The paragraph and whole-window README demos show this scroll tracking with
Screen Recording permission already granted.

## Custom actions

`CidaSettings.actions` is the ordered, persisted collection of action identities, names and prompts.
Translation and improvement keep stable built-in identities; the legacy command-line prompt fields
address these same records. Legacy saved prompts migrate on decode. The first action is the default
for showing the panel or importing a selection; capture and the translation layer explicitly translate.
Custom actions use the prompt's language and output-format policy, without inheriting the built-ins' restrictions.

`ActionEditor` owns one draft, one undo operation, and in-memory sample results. Applying a draft
updates the settings and previews the fixed sample through `TextProcessingService`. A preview keeps
the previous complete output until its replacement finishes. Request identities and cancellation
prevent an obsolete response from replacing a newer one. Browsing and renaming a cached action do
not make requests. The draft survives Settings closure and tab changes, but neither drafts nor sample
outputs are written to disk. The production panel keeps its independent streaming result.

`ActionEditorTests` covers migration, request policies, editing, undo, cancellation and default routing.
`PanelAndSettingsJourneyTests/testCustomActionsEditPreviewReorderAndRunInThePanel` drives creation,
real preview requests, native drag sorting and panel submission in Tart and retains screenshots.
