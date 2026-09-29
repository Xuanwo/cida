# 外观

2026-09-30 加入深色外观。状态见 [`boards/appearance.html`](../boards/appearance.html)（每个状态左边浅色、右边深色），量值以 [`boards/tokens.css`](../boards/tokens.css) 为准：`:root` 是浅色，`[data-appearance="dark"]` 用同样的名字重新定义深色。

## 一、跟随系统

- 辞达跟随 macOS 的外观（浅色 / 深色 / 自动），没有自己的外观开关：系统设置已经有这个选择，辞达再给一个只会让两处不一致。
- 系统切换外观时，已经显示的面板、设置、提示胶囊与原处翻译的译文立即换色，不做过渡；正在生成的请求、光标呼吸和面板高度都不受影响。
- 菜单栏标志是模板图，由系统着色（`spec/brand.md` §三）；菜单栏菜单、红绿灯、滚动条、文字选区与输入光标是系统控件，跟随系统。

## 二、深色的纸与墨

深色不是把浅色反过来，而是同一套材质在夜里：

- 原文栏与控制条是抬起的 `surface`，结果栏是沉下去的暖色纸 `surface-paper`，与浅色一样用材质区分「输入」与「输出」，不加线条。
- 结果的墨色 `text-ink` 是偏暖的白，不用纯白；界面文字 `text-primary` 是中性的白。文字层级（`text-secondary`、`text-tertiary`、`hint`）在深底上保持和浅色相近的相对强弱。
- `accent` 提亮到 #5E9C7C，与应用图标暗色外观的光标同一个值（`spec/brand.md` §二）；它出现的地方不变（`spec/panel.md` §七、`spec/settings.md` §七）。`accent-soft` 是同色相的深绿。
- 深色背景上阴影看不见：面板与提示胶囊的边改由 12% 白色细线（`panel-edge`）勾出，阴影加深（`panel-shadow`）。
- 开关的圆钮在两种外观下都是白色。

## 三、各处

- 面板与「辞达说」的各个时刻（欢迎、更新）：全部取自上面的 token，没有深色专用的规则。
- 设置：窗口底 `bg`，标题栏由系统画；其余同浅色的规则。
- 提示胶囊（截图框选、原处翻译）：跟随外观。
- 截图的纸雾不跟外观，跟冻结画面的亮度（`spec/panel.md` §一）：亮屏用浅色外观的 `surface-paper` 72%，暗屏用深色外观的 `surface-paper` 45%。
- 原处翻译的纸与墨就是当前外观的 `surface-paper` 与 `text-ink`，链接 `accent`（`spec/translation-layer.md` §五）。
- 不跟外观的：应用图标（由系统按图标风格选择，`spec/brand.md` §二）、DMG 背景（Finder 窗口里是一张固定的图）。

## 四、实现

- `CidaColorToken` 同时带浅色与深色两个值；`swiftUI` 与 `appKit` 是动态颜色，在绘制时按所在视图的外观取值。
- 图层上的颜色（`CGColor`）不会自己变：面板的圆角底与描边、结果栏的光标、原处翻译的纸与光标在视图外观改变时（`viewDidChangeEffectiveAppearance`）重新设置。
- 离屏截图 `--design-state dark-<状态>` 用深色外观画出 `<状态>`，`scripts/capture-design-states.sh` 拿它和本稿的 `dark-*` 状态对比。
