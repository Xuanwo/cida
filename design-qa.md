# Design QA

## Source of truth

The current source is `Design/cida.pen`; its SHA-256 is pinned by
`UITests/Resources/VisualBaselines/manifest.json` (`designDocumentSHA256`). The aligned Pencil
nodes are:

| State or contract | Node |
| --- | --- |
| Panel model rules | `j4dYmH` (`Spec — 面板模型`) |
| Streaming motion rules | `NdsRA` (`Spec — 流式输出动效`) |
| All panel states | `oeKVI` (`States — 面板交互`) |
| Streaming keyframes T0–T4 | `hwlXF` (`Motion — 流式输出`) |
| Settings | `l1gIe` |
| Components | `mXBP1` Control Bar, `qZy7Z` Bar Action, `KCEUn` Result Note, `B1Kz01` Mode Seg, `POaFg` Send Button (unused by the panel), `YdbKP` Titlebar (Settings only), `KYbZ2` Settings Row, `pn8Ym` Motion Label |

The panel states inside `oeKVI`, and the `--design-state` that renders each one natively:

| Pencil state | Node | `--design-state` |
| --- | --- | --- |
| 空态 | `Vdzho` | `empty` |
| 输入中 | `L4spv` | (typing, no fixture) |
| 生成中 · 等待首字 / 流式 | `DfXTi` / `FMfFR` | `streaming` |
| 完成 | `Y0C5VJ` | `translate` |
| 已复制 | `fwPJ3` | (transient, 800 ms) |
| 已修改 | `Ir399` | `stale` |
| 已停止 | `RapER` | `stopped` |
| 出错 | `mZG8z` | `failed` |
| 改进 · 完成 | `kYllY` | `improve` |
| 再次唤起 · 全选 | `N6v3qq` | (selection, no fixture) |
| 最大高度 | `U2mUc` | `long` |

The Pencil document is the first source: each topic has one Spec note, and a rule change edits that
note and its States or Motion board instead of adding a versioned copy. Exports of the boards and
notes are retained under `Design/LatestReferenceExport`; per-state exports of the nodes above are
under `Design/LatestReferenceExport/states`. `scripts/capture-design-states.sh` renders every state
offscreen with an isolated, non-activating Debug build into `Design/ImplementationCurrent`, crops the
Pencil export of the same node to the node's own pixels, and writes logical-size reference,
implementation, and side-by-side comparison images to `Design/QACurrent`.

## Approved visual contracts

`UITests/Resources/VisualBaselines/manifest.json` binds each executable baseline to the approved
native image, the current Pencil export, and the complete `.pen` document by SHA-256. A changed
image or design file cannot silently reuse an old approval.

| Baseline | Logical size | Mask |
| --- | ---: | --- |
| Panel, empty | 800 × 113 | none |
| Settings | 560 × 660 | native title bar, 46 pt |

The remaining states are retained as reviewable reference/current comparisons and are protected by
deterministic geometry and interaction assertions (panel height budget, source cap, result
scrolling, slot phases, notes). They are not misreported as pixel baselines.

All native captures are made by isolated, nonactivating app instances. Interactive pixel checks run
inside a disposable headless Tart macOS session. Neither path activates the tested app on the host.

## Alignment result

- The panel is a borderless, non-activating `NSPanel` 800 pt wide with the Pencil 14 pt radius,
  1 px hairline border, and shadow. Its height is exactly the content it shows: the source pane
  (18 pt insets around a 27 pt line that grows with the measured text), the 50 pt control bar, and,
  once a result exists, the result pane (22 pt insets around the result text and an optional note).
  The top edge stays at 20% of the visible screen; growth animates over `motion-height-ms`. The
  panel itself appears and hides at once, like Spotlight.
- Height budget: the source editor is capped at 30% of the visible screen height minus its insets,
  the panel at 70%; both panes scroll on their own past their caps with the Pencil 4 pt thumb. A
  completed result opens at its top; a streaming result keeps its tail in view until the user
  scrolls away.
- Typography: the source is Inter 16 / 26 pt lines; the result is Source Serif 4 17.5 / 29 pt
  lines for Latin output and Noto Serif SC 17 / 31 pt lines for Chinese output, in `text-ink` on
  `surface-paper`. Accent appears only on the selected action label, the streaming caret, and the
  copied feedback.
- Control bar: `翻译 | 改进` segmented control (selected item white with hairline and accent text),
  the `⇥ 切换` hint in `hint`, and one right-hand slot: nothing while typing, `停止 ⌘.` while a
  request runs, `复制结果 ⌘C` once a result exists, `✓ 已复制` on `accent-soft` for 800 ms after
  copying. Every appearance of the panel resets the action to 翻译.
- Result notes share one row under the result: `原文已修改 · ⏎ 重新生成` (result dimmed to 55%),
  `已停止 · ⏎ 重新生成`, and `请求失败：… 按 ⏎ 重试`. A failure without text shows the note alone.
- Streaming matches `Spec — 流式输出动效`: waiting caret breathing at 1.2 s, per-run 120 ms glyph
  reveal behind the caret, 150 ms height growth of the pane and the panel, 200 ms caret fade on
  completion, and the slot crossfading between 停止 and 复制结果 over 150 ms.
- Settings is unchanged: a standard titled window matching the Pencil `l1gIe` board.

## Executable evidence

- `swift test -Xswiftc -warnings-as-errors`: 102 tests, 0 failures (see `functional-qa.md`).
- Native tests pin the panel style mask, content-driven height from a fixed top edge, the height
  budget with result scrolling, submit keeping the source and replacing the result, the stale rule,
  the slot phases, composer growth and shrink measured from TextKit, the input-method composition
  guard, result typography per language, and ⌘C precedence.
- The Tart XCUI suite drives the signed Release panel through the journeys listed in
  `UITests/README.md`; its latest run is recorded in `functional-qa.md`.
- Failures retain approved/current/Pencil/diff images in the `.xcresult`; baseline recording is
  never automatic.

## Remaining certification boundary

Tart proves real macOS interaction and WindowServer composition, not physical 120 Hz cadence.
Physical performance is accepted only when the nonactivating runner detects a real 120 Hz display
and the exact manifest-bound app satisfies the frame budget. A 60 Hz run remains useful diagnostic
evidence but cannot be labeled a 120 Hz pass.
