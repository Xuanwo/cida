# 流式输出动效

对应 [`boards/panel-states.html`](../boards/panel-states.html) ③④⑦ 与 [`boards/streaming-motion.html`](../boards/streaming-motion.html)。所有量值以 [`boards/tokens.css`](../boards/tokens.css) 的 `motion-*` token 为准；下文数值后括号内为 token 名。

## 一、平滑缓冲 — 渲染速率与网络解耦

- 网络 token 只写入缓冲区，永不直接上屏。
- 渲染器每帧消费缓冲：v = clamp(缓冲字符数 / 0.4s（`motion-catchup-ms`），30（`motion-rate-min-cps`），400（`motion-rate-max-cps`）) 字符/秒。目标：约 0.4 秒内追平缓冲；下限保证可感知的书写感，上限防止瞬间倾泻。
- 速率经指数平滑（α ≈ 0.15/帧，`motion-rate-alpha`）：加减速均为渐变，禁止突变。
- 消费循环挂在 display link 帧回调，不用 Timer（避免引入自身节拍抖动）。
- 上屏粒度为字素簇：中文逐字，英文可按词，禁止拆开 emoji / 合字。

## 二、阶段动效

关键帧见 [`boards/streaming-motion.html`](../boards/streaming-motion.html) T0–T4。

1. 提交瞬间：原文留在原文栏；结果栏以 150ms（`motion-height-ms`）展开并移除上一条结果，面板同步向下生长；结果栏只有一个 accent 色光标（2×20，`motion-cursor-w/h`），呼吸动画 opacity 0.3（`motion-cursor-opacity-min`）↔ 1.0，周期 1.2s（`motion-breathe-ms`）ease-in-out（`motion-ease-breathe`）。
2. 流式中：字符在光标后淡入，每字 120ms（`motion-char-in-ms`）ease-out（`motion-ease-char-in`），blur 2px（`motion-blur-char-px`）→ 0；光标随书写头前进，无呼吸（呼吸仅表示等待）。
3. 高度增长：结果栏与面板高度过渡 150ms（`motion-height-ms`）ease-out（`motion-ease-height`），不逐 token 跳变；面板顶边固定，只向下生长。
4. 滚动锚定：面板到上限（`panel-max-ratio`）后结果栏内部滚动并平滑贴尾；用户上滚立即解除锚定，生成继续；滚回底部自动恢复。
5. 完成：光标 200ms（`motion-cursor-out-ms`）淡出；复制按钮 150ms（`motion-icon-swap-ms`）淡入，与停止按钮交叉淡化；动作选择恢复。
6. 中断 / 出错：已输出文字保留；结果栏末尾展开一行说明「已停止」或「请求失败：…」；光标直接淡出；再次 ⏎ 重新生成。

## 三、约束

- 除最后一行外，已上屏文字的位置永不变化（布局只在尾部生长）。
- 所有时长基于 120fps；系统「减弱动态效果」开启时：去掉逐字淡入、呼吸与高度过渡，保留匀速上屏。
