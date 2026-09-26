# 品牌

2026-09-25 确认方向 C「字与光标」，取代菜单栏的 SF Symbol `translate` 与没有图标的应用包。状态见 [`boards/brand.html`](../boards/brand.html)。

## 一、标志

- 标志是「辞」后跟一枚光标。光标就是结果栏的流式光标（`accent`，直角，宽为高的 1/10）：话正在抵达，对应「辞达而已矣」的「达」。
- 字形取自应用自带的 Noto Serif SC，字重 700，转成路径，不依赖运行时字体。
- 几何：光标高为字形墨迹高的 0.86，与字形间距 0.06 em，光标中心比字形中心低墨迹高的 7%；字形与光标作为一组水平居中，字形垂直居中。光标宽度小于 1.5pt 时取 1.5pt。
- 矢量文件由 `swift scripts/generate-brand-marks.swift` 从字体与上述几何生成，改几何只改脚本里的常量，再重新生成。

## 二、应用图标

- `Resources/AppIcon.icon`（Icon Composer 格式）：1024 画布，墨迹高 560；底色 `surface-paper`，字形 `text-ink`，光标 `accent`。两层都关掉 Liquid Glass，保持纸上墨字的平面感；只有图标外形由系统加玻璃边。
- 暗色外观：底 `text-ink`，字 `surface-paper`，光标 #5E9C7C（`accent` 在深底上对比不足，提亮到同色相）。着色外观由系统从图层生成。
- 构建脚本用 `scripts/compile-app-icon.sh` 把它编译进应用包：macOS 26 起读 `Assets.car`，macOS 15 读 `AppIcon.icns`；`Cida-Info.plist` 的 `CFBundleIconName` / `CFBundleIconFile` 都是 `AppIcon`。
- 辞达不进 Dock，图标出现在 Finder、授权弹窗、「隐私与安全性」的辅助功能与屏幕录制列表、登录项、钥匙串提示里。

## 三、菜单栏

- 18×18pt 单色模板图，墨迹高 14，光标宽 1.5；由系统按菜单栏明暗着色，不带 accent。字形与光标是两层（`Sources/Cida/Resources/Brand/status-item-glyph.svg`、`status-item-caret.svg`），运行时叠成一张模板图。
- 呼吸（2026-09-25 决定）：面板隐藏、请求仍在生成（等待首字或逐字显示）时，只有光标呼吸，与结果栏等待光标同一曲线：opacity 0.3（`motion-cursor-opacity-min`）↔ 1，周期 1.2s（`motion-breathe-ms`），ease-in-out。呼吸从 opacity 1 的相位开始；请求结束、被停止或失败，或面板重新出现，光标用 200ms（`motion-cursor-out-ms`，`motion-ease-cursor-out`）缓回 1。面板可见时不呼吸，进度由面板自己显示。
- 呼吸期间按钮的辅助功能值为「正在生成」，平时为空。开启「减弱动态效果」时不动画，光标停在 0.3。
- 资源缺失时退回文字「辞」。

## 四、字标

- 「辞达」（`font-brand` 12 semibold，字距 2，`text-secondary`）后紧跟一枚 accent 光标：高 0.8 em（9.6pt），宽 1.5pt，下移 0.06 em。实现是 `CidaWordmark`，board 是 `.wordmark`。
- 只用在两处：设置页脚、截图提示胶囊（取代原来的竖分隔线）。面板里不放标志或字标，面板只显示内容；面板里的 accent 仍只有 `spec/panel.md` 列出的三处。
