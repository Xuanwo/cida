<p align="center">
  <img src="Design/rendered/states/brand-icon.png" width="128" alt="辞达：「辞」后跟一枚流式光标">
</p>

<h1 align="center">辞达 · Cida</h1>

<p align="center">
  在 Mac 的任何地方，一个快捷键完成翻译和润色。<br>
  <a href="https://github.com/Xuanwo/cida/releases/latest">下载</a> · <a href="README.md">English</a>
</p>

![辞达把一句中文翻译成英文](docs/images/translate.png)

辞达住在菜单栏里。在任何应用里按 <kbd>⌥</kbd> <kbd>Space</kbd>，面板就会带着你选中的文字出现，并且已经开始翻译；按 <kbd>Tab</kbd> 可以改成润色。名字取自《论语》「辞达而已矣」：言辞能把意思表达清楚就够了。

## 特点

- **不打扰。** 面板直接接收输入，但不会切换应用；按 <kbd>Esc</kbd> 就回到原来的地方。面板隐藏后请求照常生成，菜单栏里的光标会一直呼吸到生成结束。
- **带入选区。** 授权辅助功能后，前台应用里选中的文字会直接成为原文并立即翻译。
- **识别屏幕。** <kbd>⌥</kbd> <kbd>S</kbd> 冻结屏幕，框出任意文字，辞达用 Vision 在本机识别后翻译。
- **翻译或润色。** 自动识别中文和英文并互译；润色时保持原文的语言。
- **用你自己的模型。** 支持 DeepSeek、OpenAI、Moonshot、智谱 GLM，以及任何兼容 OpenAI 的接口，包括不需要密钥的本地服务。
- **什么都不留。** API Key 只存在钥匙串里；没有历史记录，没有遥测，截图也不会离开你的 Mac。

## 安装

需要 macOS 15 或更新版本。

1. 从[最新版本](https://github.com/Xuanwo/cida/releases/latest)下载 `Cida-<版本>.zip`。安装包使用 Developer ID 签名，并经过 Apple 公证。
2. 解压后把 **Cida.app** 拖进「应用程序」。
3. 打开辞达，按 <kbd>⌘</kbd> <kbd>,</kbd> 选择服务商并填入 API Key。

<p align="center">
  <img src="docs/images/settings.png" width="480" alt="辞达的设置窗口">
</p>

## 快捷键

| 按键 | 作用 |
| --- | --- |
| <kbd>⌥</kbd> <kbd>Space</kbd> | 显示或隐藏面板，同时带入选中的文字 |
| <kbd>⌥</kbd> <kbd>S</kbd> | 框选屏幕上的文字并翻译 |
| <kbd>Return</kbd> | 执行当前动作（<kbd>⇧</kbd> <kbd>Return</kbd> 换行） |
| <kbd>Tab</kbd> | 在翻译和改进之间切换 |
| <kbd>⌘</kbd> <kbd>C</kbd> | 有选区时复制选区，否则复制结果 |
| <kbd>⌘</kbd> <kbd>.</kbd> | 停止 |
| <kbd>Esc</kbd> | 隐藏 |
| <kbd>⌘</kbd> <kbd>,</kbd> | 设置 |

两个全局快捷键都可以在设置里重新录制。

## 从源码构建

```sh
git clone https://github.com/Xuanwo/cida.git
cd cida
swift run Cida
```

构建需要 Xcode 26 或更新版本。签名构建、测试、发版和架构说明见 [`docs/development.md`](docs/development.md)，设计稿在 [`Design/`](Design/README.md)，参与贡献请遵循 [`AGENTS.md`](AGENTS.md)。

## 许可证

辞达以 [Apache-2.0](LICENSE) 许可证发布。应用内附带的 Inter、Source Serif 4、Noto Serif SC、JetBrains Mono 字体遵循 SIL Open Font License 1.1，Lucide 图标遵循 ISC 许可证。
