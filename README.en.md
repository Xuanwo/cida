<p align="center">
  <img src="Design/rendered/states/brand-icon.png" width="112" alt="Cida's icon: 辞 followed by a caret">
</p>

<h1 align="center">Cida · 辞达</h1>

<p align="center">
  Translate and polish text anywhere on your Mac, with the language model you choose.<br>
  <a href="https://cida-releases.xuanwo.io/latest/Cida.dmg">Download</a> · <a href="README.md">简体中文</a>
</p>

<p align="center">
  <img src="docs/images/demo.gif" width="800" alt="Selecting English text and pressing Option-Space translates it into Chinese; Tab improves it; Option-S translates text framed on screen">
</p>

## How it works

- **Select text and press <kbd>⌥</kbd> <kbd>Space</kbd>.** The panel appears with your selection and the translation starts streaming in. Text in your language goes into your usual foreign language and anything else comes into yours; they default to Simplified Chinese and English, and Settings takes any language, dialect or register, such as Cantonese or British English.
- **Press <kbd>Tab</kbd>, then <kbd>Return</kbd>, to improve the writing instead.** The improved text stays in its own language.
- **For text on the screen, press <kbd>⌥</kbd> <kbd>S</kbd>.** Frame what you want translated; Cida recognizes it on your Mac and translates it.
- **To read in place, press <kbd>⌥</kbd> <kbd>D</kbd>.** Click a paragraph and its translation covers the original; <kbd>⇧</kbd>-click an area, such as Slack's message list or an article, and its foreign text keeps showing as translations that follow scrolling. Rest the pointer on a translation to see the original; clicks and scrolling still reach the app.

<kbd>Esc</kbd> takes you back to your app. A request keeps running while the panel is hidden, and the result is there when you bring it back.

The interface is in Simplified Chinese.

## Install

You need macOS 15 or newer and a language model service.

1. Download [Cida.dmg](https://cida-releases.xuanwo.io/latest/Cida.dmg). It is signed with a Developer ID and notarized by Apple.
2. Open the DMG, drag 辞达 into Applications (应用程序), then open it from Launchpad or Spotlight. Cida lives in the menu bar, not the Dock.
3. Press <kbd>⌘</kbd> <kbd>,</kbd>, click 复制配置提示词 to copy the configuration prompt, and give it to an AI assistant such as Claude Code or Codex. It asks which service you want, configures Cida through its [command line](#command-line) and runs `check` to confirm the model answers.

Your API key never passes through the assistant: it asks you to copy the key and run one command that stores it in the Keychain. Cida speaks OpenAI Chat Completions, Responses and Anthropic Messages; a model running on your Mac (such as `http://127.0.0.1:8080`) needs no key. Cida is free; your provider charges for the requests.

Two permissions are optional. Turn them on with 去授权 on the 快捷键 tab of Settings:

| Permission | With it | Without it |
| --- | --- | --- |
| Accessibility | <kbd>⌥</kbd> <kbd>Space</kbd> brings in the selected text; <kbd>⌥</kbd> <kbd>D</kbd> translates in place | Copy with <kbd>⌘</kbd> <kbd>C</kbd>, then paste into the panel; no in-place translation |
| Screen Recording | <kbd>⌥</kbd> <kbd>S</kbd> translates text on screen; in-place translations take the original's colours and follow scrolling frame by frame | Screenshot translation is unavailable; in-place translations sit on paper and hide while scrolling |

## Privacy

- The API key is stored only in the macOS Keychain.
- There is no history and no telemetry; translation and improvement requests go only to the provider you chose.
- Screenshots are recognized on your Mac with Apple's Vision and never leave it. In-place translation reads only the text apps expose through Accessibility; frames are compared in memory and never saved or sent.

## Keys

| Key | Action |
| --- | --- |
| <kbd>⌥</kbd> <kbd>Space</kbd> | Show or hide the panel |
| <kbd>⌥</kbd> <kbd>S</kbd> | Translate text on screen |
| <kbd>⌥</kbd> <kbd>D</kbd> | Translate in place: click a paragraph once, <kbd>⇧</kbd>-click an area to keep it |
| <kbd>Tab</kbd> | Switch between translate and improve |
| <kbd>Return</kbd> | Run (<kbd>⇧</kbd> <kbd>Return</kbd> for a new line) |
| <kbd>Esc</kbd> | Hide the panel |

All three global shortcuts can be recorded again in Settings.

## Command line

The executable inside the app is Cida's command line; there is nothing else to install. It shares its configuration with the running Cida, which picks up every change at once:

```sh
cida=/Applications/Cida.app/Contents/MacOS/Cida
$cida config schema                        # every field, its values and what it does
$cida config show
$cida config set model=deepseek-chat       # several fields at once; unset and reset too
pbpaste | $cida config set api-key --stdin
$cida check --verbose                      # one real request; on failure, the request and response
```

Every command takes `--json`. The API key is read only from `--stdin`, `--file` or `--env`; a key written as an argument is refused. [`Design/spec/configuration.md`](Design/spec/configuration.md) describes every field.

## Updates

Cida checks `https://cida-releases.xuanwo.io/appcast.xml` once a day. When a new version is out, its panel shows the update notes and installs the update once you agree. The check sends no system information, and you can turn it off on the 通用 tab of Settings.

## Uninstall

Quit Cida and move it from Applications to the Trash. To remove every trace, also delete the Keychain Access item named `com.xuanwo.Cida` and `~/Library/Preferences/com.xuanwo.Cida.plist`.

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
