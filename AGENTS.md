# AGENTS.md

Working rules for anyone changing Cida, human or agent. [`docs/development.md`](docs/development.md) explains the build, the test harnesses and the architecture in depth.

## Layout

| Path | Holds |
| --- | --- |
| `Sources/Cida` | The app: SwiftUI views, AppKit windows, the model, streaming and rendering |
| `Tests/CidaTests` | Unit and in-process integration tests (`swift test`) |
| `UITests` | XCUI journeys that drive the signed Release app inside a Tart VM |
| `Design` | The design source: rules in `spec/*.md`, states in `boards/*.html`, tokens in `boards/tokens.css` |
| `Resources` | `Cida-Info.plist` and the app icon (`AppIcon.icon`) |
| `scripts` | Building, signing, notarizing, design rendering and the verification gates |
| `docs` | Development notes, QA records and the README demo (`docs/images/demo.gif`) |
| `infra/releases-publisher` | The Worker the release workflow uploads updates through |

## Design comes first

- `Design/` is the first source for how Cida looks and behaves. A change to behaviour or appearance edits the spec section and the board state in the same change as the code. Replace outdated rules in place and delete abandoned ones; never keep versioned copies.
- `CidaDesign` and `CidaMotion` in `Sources/Cida/DesignSystem.swift` mirror `Design/boards/tokens.css` one to one, and `DesignTokenTests` fails when they drift. Change the token file and the Swift value together.
- After editing a board, render it with `swift scripts/render-design.swift <board>.html`.
- The brand mark comes from `scripts/generate-brand-marks.swift`; change its geometry there, not in the generated SVGs.

## Screenshots are required for UI changes

Every change that touches the interface or an interaction, whether a view, a window, a shortcut, an animation, the menu bar item or the app icon, must include screenshots in its pull request, before and after:

- Static states: run `scripts/capture-design-states.sh` and attach the matching `Design/QACurrent/comparison-<state>.png`, which puts the board next to the native capture.
- States without a fixture, interactions and motion: attach the screenshots that the Tart XCUI journey saves in its `.xcresult`, or a short screen recording.
- When a change alters what `docs/images/demo.gif` shows (the panel, translating, improving, the capture overlay), say so in the pull request so the demo is recorded again.
- A changed pixel baseline (`UITests/Resources/VisualBaselines/manifest.json`) is re-approved in the same pull request, with the new comparison image attached.

A pull request that changes the UI without screenshots is not ready for review.

## Verify

- `swift build -Xswiftc -warnings-as-errors` and `swift test` must pass for every change; the CI workflow runs both on each pull request.
- Changes to the panel, Settings, shortcuts, selection import, capture or streaming run the affected XCUI journey in Tart: `CIDA_TART_DIAGNOSTIC_MODE=1 CIDA_UI_TEST_ONLY_TESTING=<Suite/test> scripts/test-ui-in-tart.sh`.
- Release decisions use the gates, from a clean committed checkout: `scripts/e2e/run-pr-gate.sh`, `run-nightly-gate.sh`, `run-release-gate.sh`.
- Never drive the host's screen for testing: no synthetic mouse or keyboard events, no screen recording of the live desktop, no test instance that activates windows. Use the offscreen captures or Tart.
- A new `InteractionReproductionTests` case must match one of the name shards in `scripts/run-vm-ui-tests-in-guest.sh`, or the guest run fails.

## Code and writing

- Code, comments, identifiers, commit messages and English docs are written in English. User-facing strings are Simplified Chinese, and so are the specs in `Design/spec`.
- Match the surrounding code: its naming, comment density and idiom. Comments explain constraints the code cannot show, not history.
- Commit messages start with a type (`feat:`, `fix:`, `test:`, `docs:`, `build:`, `ci:`, `refactor:`) and explain why the change is needed in the body.
- Never commit secrets. Provider keys live in Keychain; signing and notarization credentials live in CI secrets.

## Release

Pushing a `vX.Y.Z` tag on `main` builds, signs, notarizes and publishes a release through `.github/workflows/release.yml`, and publishes it as a Sparkle update to `https://cida-releases.xuanwo.io` (`vX.Y.Z-rc.N` goes to the beta channel only). Run `scripts/e2e/run-release-gate.sh` on the commit before tagging it, because GitHub's runners cannot run the Tart journeys.
