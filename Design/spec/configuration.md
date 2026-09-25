# 配置

2026-09-25 确认：模型服务不再在设置里逐项填写，而是由辞达的命令行描述全部选项，用户把一段提示词交给 AI 助手，助手用命令行配好并自己检查。状态见 [`boards/configuration.html`](../boards/configuration.html)。

## 一、为什么

- 各家服务的差异（端点、请求格式、鉴权方式、特有参数）用预设吸收，每接一家就要改一次界面和代码。
- AI 助手能查文档、改配置、发请求验证、失败再改；命令行给它一个完整且可验证的接口。

## 二、命令行

- 就是应用本身的可执行文件 `/Applications/Cida.app/Contents/MacOS/Cida`，不另外安装，不改 PATH。带子命令运行时不启动界面，与正在运行的辞达共用同一份配置和钥匙串条目（同一个签名，读钥匙串不弹授权）。
- 输出给人看的是中文；每个命令都有 `--json`，给助手稳定的结构。
- 命令：
  - `config schema`：全部字段的名称、类型、取值、默认值、示例与说明。
  - `config show`：当前配置；API Key 只显示「已保存在钥匙串」或「未设置」，不输出任何片段。
  - `config set 字段=值 …`：一次写入多项，全部校验通过才生效，任何一项不合法都不改动；写入后正在运行的辞达立即改用新配置。
  - `config set api-key --stdin | --file 路径 | --env 名称`：敏感字段只从这三处读取，读到的值存进钥匙串；直接写在命令里的值被拒绝，免得留在 shell 历史和助手的对话里。`--env`、`--file` 只在执行时读一次，之后不再依赖它们（从访达打开的辞达看不到终端的环境变量）。
  - `config unset 字段`、`config reset`：恢复默认。
  - `check`：用当前配置真的请求一次（让模型把 hello 译成中文），报告是否可用、耗时和回复。`check --verbose` 失败时列出实际请求的 URL、请求头、请求体、HTTP 状态与服务商返回的原文；API Key 在所有输出里（包括服务商回显的错误信息）都替换为 `••••`。
- 退出码：成功 0；配置不合法 64；检查失败 69。

## 三、字段

| 字段 | 取值 | 说明 |
| --- | --- | --- |
| `endpoint` | http(s) URL | 请求发往的完整地址 |
| `format` | `chat-completions` / `responses` / `anthropic-messages` | 请求与流式响应的格式 |
| `model` | 文本 | 模型名 |
| `api-key` | 敏感 | 只能 `--stdin` / `--file` / `--env`；本地端点可不设 |
| `auth` | `bearer` / `x-api-key` / `api-key` / `none` | Key 放在哪个请求头；默认随 `format`（Anthropic 为 `x-api-key`，其余 `bearer`） |
| `headers` | JSON 对象 | 额外请求头 |
| `body` | JSON 对象 | 合并进请求体的额外参数（如关闭推理） |
| `translation-prompt` / `improvement-prompt` | 文本，可 `--file` / `--stdin` | 与设置里的提示词相同 |
| `shortcut` / `capture-shortcut` | 如 `option+space` | 与设置里的快捷键相同 |
| `launch-at-login` / `automatic-updates` | `true` / `false` | 与设置里的开关相同 |

原来的四个预设在升级时换算成对应的 `endpoint`、`format`、`model`，已配置的用户不受影响。

## 四、设置里的「模型」

- 还没有模型服务：这一组只有一张纸（`surface-paper`，`radius-card`，1px `border`，padding 16/18）。标题「还没有模型服务」（13.5 medium），说明「复制配置提示词，交给 Claude Code、Codex 等 AI 助手。它会问你用哪家服务，配好后自己检查。」（11.5 `text-tertiary`），右侧带复制图标的「复制配置提示词」边框按钮。
- 复制后：按钮 800ms 内为「✓ 已复制」（`accent-soft` 底，同面板的已复制），说明换成「已复制。粘贴给你的 AI 助手，配好后这里会自动更新。」，直到配置出现。
- 已配置：纸收起。
  - 「模型服务」一行：标签下是状态（6pt 圆点 + 说明：已就绪 / 正在检查… / 检查失败）；控件列左对齐两行，模型名（13.5 `text-primary`）与「<域名> · <格式>」（11.5 `text-tertiary`）；最右「检查」边框按钮，进行中为「检查中…」。
  - 「调整配置」一行：说明「交给 AI 助手」，右侧同一个「复制配置提示词」按钮。
- 检查失败：「模型服务」一行下、控件列起始处一行说明（提示图标 + 11.5 `text-secondary`）：「<状态码> · <原因>。复制配置提示词，让 AI 助手修好。」
- 状态以最近一次检查为准：配置改动后还没检查过时为「已就绪」（配置完整即可）；设置里的「检查」与命令行 `check` 的结果都会记录，设置窗口开着时实时刷新。
- 助手通过命令行改完配置时，窗口开着就实时刷新，状态说明带「 · 刚刚更新」3 秒。
- 设置里不再有服务商菜单、端点、模型与 API Key 输入框。提示词、唤起、更新三组不变。

## 五、配置提示词

复制出的全文（命令行路径与当前配置按实际填入）：

```
帮我配置辞达（macOS 上的翻译与改写应用）使用的模型服务。

辞达的命令行：/Applications/Cida.app/Contents/MacOS/Cida
当前配置：deepseek-chat · api.deepseek.com · Chat Completions

请这样做：
1. 问我想用哪家模型服务和哪个模型；我没想好时推荐两三个并说明差别。
2. 运行 `Cida config schema` 了解全部字段，查这家服务的官方文档，确定端点、请求格式和需要的参数。
3. 用 `Cida config set 字段=值 …` 一次写入。
4. API Key 不要让我发给你，也不要打印或写进文件：请我先复制 Key，再运行 `pbpaste | Cida config set api-key --stdin`；Key 已经在环境变量或文件里时，用 `--env` 或 `--file`。
5. 运行 `Cida check`；失败时用 `Cida check --verbose` 找原因、修改配置，直到通过。
6. 最后用 `Cida config show` 告诉我配置结果。

如果你不能运行命令，就把每一步的命令写给我，我粘贴到「终端」里运行，再把输出贴给你。
```

## 六、第一次使用

见 `spec/lifecycle.md` §三：还没有模型服务时，欢迎面板指向设置里的配置提示词。
