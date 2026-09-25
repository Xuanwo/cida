<p align="center">
  <img src="Design/rendered/states/brand-icon.png" width="112" alt="Cida's icon: 辞 followed by a caret">
</p>

<h1 align="center">Cida · 辞达</h1>

<p align="center">
  Translate and polish text anywhere on your Mac, with the language model you choose.<br>
  <a href="https://github.com/Xuanwo/cida/releases/latest">Download</a> · <a href="README.md">简体中文</a>
</p>

<p align="center">
  <img src="docs/images/demo.gif" width="800" alt="Selecting English text and pressing Option-Space translates it into Chinese; Tab improves it; Option-S translates text framed on screen">
</p>

## How it works

- **Select text and press <kbd>⌥</kbd> <kbd>Space</kbd>.** The panel appears with your selection and the translation starts streaming in. Chinese and English are detected and translated into each other.
- **Press <kbd>Tab</kbd>, then <kbd>Return</kbd>, to improve the writing instead.** The improved text stays in its own language.
- **For text on the screen, press <kbd>⌥</kbd> <kbd>S</kbd>.** Frame what you want translated; Cida recognizes it on your Mac and translates it.

<kbd>Esc</kbd> takes you back to your app. A request keeps running while the panel is hidden, and the result is there when you bring it back.

The interface is in Simplified Chinese.

## Install

You need macOS 15 or newer and an API key for a language model service.

1. Download the zip from the [latest release](https://github.com/Xuanwo/cida/releases/latest). It is signed with a Developer ID and notarized by Apple.
2. Unzip it, move **Cida.app** to Applications and open it. Cida lives in the menu bar, not the Dock.
3. Press <kbd>⌘</kbd> <kbd>,</kbd>, choose a provider and paste your API key.

DeepSeek, OpenAI, Moonshot, Kimi For Coding (the Kimi Code subscription) and 智谱 GLM are built in, and any endpoint compatible with OpenAI Chat Completions works too; a model running on your Mac (such as `http://127.0.0.1:8080`) needs no key. Cida is free; your provider charges for the requests.

Two permissions are optional. Turn them on with 去授权 in the 唤起 section of Settings:

| Permission | With it | Without it |
| --- | --- | --- |
| Accessibility | <kbd>⌥</kbd> <kbd>Space</kbd> brings in the selected text | Copy with <kbd>⌘</kbd> <kbd>C</kbd>, then paste into the panel |
| Screen Recording | <kbd>⌥</kbd> <kbd>S</kbd> translates text on screen | Screenshot translation is unavailable |

## Privacy

- The API key is stored only in the macOS Keychain.
- There is no history and no telemetry; requests go only to the provider you chose.
- Screenshots are recognized on your Mac with Apple's Vision and never leave it.

## Keys

| Key | Action |
| --- | --- |
| <kbd>⌥</kbd> <kbd>Space</kbd> | Show or hide the panel |
| <kbd>⌥</kbd> <kbd>S</kbd> | Translate text on screen |
| <kbd>Tab</kbd> | Switch between translate and improve |
| <kbd>Return</kbd> | Run (<kbd>⇧</kbd> <kbd>Return</kbd> for a new line) |
| <kbd>Esc</kbd> | Hide the panel |

Both global shortcuts can be recorded again in Settings.

## Contributing

```sh
git clone https://github.com/Xuanwo/cida.git
cd cida
swift run Cida
```

Building needs Xcode 26 or newer. [`docs/development.md`](docs/development.md) covers building, testing and releasing, [`Design/`](Design/README.md) holds the design, and [`AGENTS.md`](AGENTS.md) lists the rules for changes.

## License

[Apache-2.0](LICENSE).

The name comes from the *Analects*: 辞达而已矣, words need only get the meaning across.
