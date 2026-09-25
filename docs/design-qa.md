# Design QA

## Source of truth

The design lives in `Design/` (see `Design/README.md`): one spec per topic under `Design/spec` and
one HTML board per topic under `Design/boards`, drawn from the shared `tokens.css`,
`components.css` and `components.js`.

| Contract | Rules | Board |
| --- | --- | --- |
| Panel shape, structure, actions, states, keys, selection import, capture | `spec/panel.md` | `boards/panel-states.html` |
| Capture framing overlay | `spec/panel.md` §一 截图翻译 | `boards/capture.html` |
| Streaming buffer and motion, keyframes T0–T4 | `spec/streaming-motion.md` | `boards/streaming-motion.html` |
| Settings | `spec/settings.md` | `boards/settings-states.html` |
| Model service configuration: the command line, Settings' 模型 group, the prompt | `spec/configuration.md` | `boards/configuration.html` |
| Brand: mark, app icon, menu bar image, wordmark | `spec/brand.md` | `boards/brand.html` |
| Updates: checks, channels, update reminders, menu bar menu | `spec/updates.md` | `boards/updates.html` |

Each state carries a `data-state` name; the ones the app can render with `--design-state` are
compared natively:

| Board state | `data-state` | `--design-state` |
| --- | --- | --- |
| ① 空态 | `empty` | `empty` |
| ② 输入中 | `typing` | (typing, no fixture) |
| ③ 生成中 · 等待首字 / 流式 | `waiting` / `streaming` | `streaming` |
| ④ 完成 | `translate` | `translate` |
| ⑤ 已复制 | `copied` | (transient, 800 ms) |
| ⑥ 已修改 | `stale` | `stale` |
| ⑦ 已停止 / 出错 | `stopped` / `failed` | `stopped` / `failed` |
| ⑧ 改进 · 完成 | `improve` | `improve` |
| ⑨ 再次唤起 · 全选 | `reopened` | (selection, no fixture) |
| ⑩ 带入选区 | `selection-imported` | (global shortcut; XCUI `testShortcutBringsInANewSelectionAndLeavesTheSameOneAlone`) |
| ⑪ 截图 · 未识别到文字 | `capture-unrecognized` | (capture shortcut; XCUI `testCaptureShortcutFramesTextOnTheFrozenScreenAndTranslatesIt`) |
| ⑫ 最大高度 | `long` | `long` |
| 设置 · 默认 | `settings` | `settings` |
| 设置 · 编辑改进提示词 · 自定义快捷键 · 已授权 · 开机启动 | `settings-custom` | `settings-custom` |
| 设置 · 录制快捷键 | `settings-recording` | `settings-recording` |
| 设置 · 有新版本可以安装 | `settings-update-available` | `settings-update-available` |
| 配置 · 还没有模型服务 | `settings-config-unset` | `settings-config-unset` |
| 配置 · 已复制提示词 | `settings-config-copied` | `settings-config-copied` |
| 配置 · 已就绪 | `settings-config-ready` | `settings-config-ready` |
| 配置 · 助手刚改完 | `settings-config-updated` | `settings-config-updated` |
| 配置 · 检查中 | `settings-config-checking` | `settings-config-checking` |
| 配置 · 检查失败 | `settings-config-failed` | `settings-config-failed` |
| 配置 · 提示词全文 / 助手的一次配置 / 助手自己闭环 | `configuration-prompt` / `configuration-agent-session` / `configuration-agent-errors` | (text and command-line output; `ModelConfigurationTests` and `CommandLineInterfaceTests` pin the strings) |
| 菜单栏菜单 · 平时 / 发现新版本 | `status-menu` / `status-menu-update-available` | (native menu, no fixture) |
| 截图框选 · 拖动前 / 框选中 / 暗屏 | `capture-veiled` / `capture-lifted` / `capture-lifted-dark` | (overlay; XCUI attaches `capture-overlay-veiled`) |

`swift scripts/render-design.swift` renders every board off screen to `Design/rendered/boards` and
every state to `Design/rendered/states` at 2x. `scripts/capture-design-states.sh` renders the boards,
captures every `--design-state` offscreen with an isolated, non-activating Debug build into
`Design/ImplementationCurrent`, and writes logical-size reference, implementation, and side-by-side
comparison images to `Design/QACurrent`.

## Approved visual contracts

`UITests/Resources/VisualBaselines/manifest.json` binds each executable baseline to the approved
native image, the board's render of the same state, and the board file by SHA-256. A changed image
or board cannot silently reuse an old approval; a change to the shared styles shows up as a changed
render once the boards are rendered again.

| Baseline | Logical size | Mask |
| --- | ---: | --- |
| Panel, empty | 800 × 113 | none |
| Settings, default | 560 × 744 | native title bar, 46 pt |

The remaining states are retained as reviewable reference/current comparisons and are protected by
deterministic geometry and interaction assertions (panel height budget, source cap, result
scrolling, slot phases, notes). They are not misreported as pixel baselines.

All native captures are made by isolated, nonactivating app instances. Interactive pixel checks run
inside a disposable headless Tart macOS session. Neither path activates the tested app on the host.

## Alignment result

- The panel is a borderless, non-activating `NSPanel` 800 pt wide with the design's 14 pt radius,
  1 px hairline border, and shadow. Its height is exactly the content it shows: the source pane
  (18 pt insets around a 27 pt line that grows with the measured text), the 50 pt control bar, and,
  once a result exists, the result pane (22 pt insets around the result text and an optional note).
  The top edge stays at 20% of the visible screen; growth animates over `motion-height-ms`. The
  panel itself appears and hides at once, like Spotlight.
- Height budget: the source editor is capped at 30% of the visible screen height minus its insets,
  the panel at 70%; both panes scroll on their own past their caps with the system overlay scroll bar, which the static board states do not draw. A
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
- Settings follows `Spec — 设置`: a fixed-width (560 pt) titled window whose height follows its
  content up to the screen's visible height, with four groups in the order of the user's
  questions. The 模型 group follows `spec/configuration.md` §四: without a complete configuration
  it is one `surface-paper` card (还没有模型服务, the caption, and 复制配置提示词, which shows
  `✓ 已复制` on `accent-soft` for 800 ms and turns the caption into the next step until a
  configuration arrives); with one it is the 模型服务 row (a 6 pt status dot and 已就绪 / 正在检查… /
  检查失败 under the label, `· 刚刚更新` for three seconds after the command line changed it, the
  model over `<host> · <format>`, and 检查 / 检查中…), a failure line under it when the latest
  check of this configuration failed, and 调整配置 with the same copy button. Prompts collapse to a
  one-line preview with `编辑` and expand into a `surface-paper` sheet (Inter 13 / 21 pt lines in
  `text-ink`, accent focus ring). Accent appears only on the ready dot, the copied feedback, focus
  rings, and the switch.

## Executable evidence

- `swift test -Xswiftc -warnings-as-errors`: 102 tests, 0 failures (see `functional-qa.md`).
- Native tests pin the panel style mask, content-driven height from a fixed top edge, the height
  budget with result scrolling, submit keeping the source and replacing the result, the stale rule,
  the slot phases, composer growth and shrink measured from TextKit, the input-method composition
  guard, result typography per language, and ⌘C precedence.
- The Tart XCUI suite drives the signed Release panel through the journeys listed in
  `UITests/README.md`; its latest run is recorded in `functional-qa.md`.
- Failures retain approved/current/design/diff images in the `.xcresult`; baseline recording is
  never automatic.

## Remaining certification boundary

Tart proves real macOS interaction and WindowServer composition, not physical 120 Hz cadence.
Physical performance is accepted only when the nonactivating runner detects a real 120 Hz display
and the exact manifest-bound app satisfies the frame budget. A 60 Hz run remains useful diagnostic
evidence but cannot be labeled a 120 Hz pass.
