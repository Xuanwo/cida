# Design

This directory is the first source for Cida's design. The implementation follows it; a behaviour
change edits the spec and the board here before, or together with, the code. Every topic has one
spec and one board; a replaced rule is edited in place and an abandoned one is deleted, never kept as
a versioned copy.

| Topic | Rules | States |
| --- | --- | --- |
| Panel: shape, structure, actions, states, keys, selection import, capture | [`spec/panel.md`](spec/panel.md) | [`boards/panel-states.html`](boards/panel-states.html), [`boards/capture.html`](boards/capture.html) |
| Streaming: buffering rate, phase motion, constraints | [`spec/streaming-motion.md`](spec/streaming-motion.md) | [`boards/streaming-motion.html`](boards/streaming-motion.html) |
| Settings: window, model status, prompts, shortcuts, permissions | [`spec/settings.md`](spec/settings.md) | [`boards/settings-states.html`](boards/settings-states.html) |
| Brand: mark, app icon, menu bar image, wordmark | [`spec/brand.md`](spec/brand.md) | [`boards/brand.html`](boards/brand.html) |
| Updates: checks, channels, update reminders, menu bar menu | [`spec/updates.md`](spec/updates.md) | [`boards/updates.html`](boards/updates.html) |
| Lifecycle: DMG, first run, launch behaviour, the update panel, uninstall | [`spec/lifecycle.md`](spec/lifecycle.md) | [`boards/lifecycle.html`](boards/lifecycle.html) |
| Configuration: the command line, model fields, the agent prompt, Settings' model group | [`spec/configuration.md`](spec/configuration.md) | [`boards/configuration.html`](boards/configuration.html) |

## Boards

Boards are plain HTML drawn from two shared files:

- [`boards/tokens.css`](boards/tokens.css) holds every design token: colors (light only), type,
  radii, spacing, panel ratios and the `motion-*` values. `CidaDesign` and `CidaMotion` in
  `Sources/Cida/DesignSystem.swift` mirror it one to one, and `DesignTokenTests` fails when they
  drift apart. Specs name tokens rather than repeating numbers; when the two disagree the token wins.
- [`boards/components.css`](boards/components.css) and [`boards/components.js`](boards/components.js)
  draw the parts every state shares: the panel with its source pane, control bar and result pane,
  the Settings window, the frozen screen of the capture overlay. A state is the markup that differs,
  such as `<cida-bar processing action="stop">` or `<cida-settings key="missing">`.

Boards load the fonts the app bundles (`Sources/Cida/Resources/Fonts`) and use the same lucide
icons, so a board renders like the app without a network. Open one in a browser to look at it.

Each state an implementation capture can be compared with carries `data-state="<name>"`, where the
name is the app's `--design-state` value when one exists. Motion boards show one stable state per
frame; the note under a frame is the transition to the next one, with its trigger, property and
token.

## Rendering

```sh
swift scripts/render-design.swift            # every board
swift scripts/render-design.swift capture.html
```

The renderer loads each board in the system WebKit off screen (a transparent window behind
everything that never takes focus) and writes, at 2x:

- `rendered/boards/<board>.png`, the whole board, for reading the design without a browser;
- `rendered/states/<state>.png`, each `data-state` element on its own.

`scripts/capture-design-states.sh` renders the boards, captures the same states from an isolated
Debug build, and writes logical-size reference, implementation and side-by-side comparison images to
`QACurrent`. The approved empty-panel and Settings baselines, and the board files they come from,
are pinned by SHA-256 in `UITests/Resources/VisualBaselines/manifest.json` (see
[`../docs/design-qa.md`](../docs/design-qa.md)).
