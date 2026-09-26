// Parts that repeat across states, as small custom elements so a state reads
// as what differs: <cida-bar mode action processing> and <cida-note kind>.

// The panel's own actions by default; a lifecycle panel (spec/lifecycle.md §一) passes its
// choices as options="移到「应用程序」|暂不" with selected="0", and a status text for the slot.
class CidaBar extends HTMLElement {
  connectedCallback() {
    const mode = this.getAttribute("mode") ?? "translate";
    const action = this.getAttribute("action") ?? "none";
    const actions = {
      none: "",
      stop: `<div class="bar-action"><i class="stop-icon"></i><span class="label">停止</span><span class="key">⌘.</span></div>`,
      copy: `<div class="bar-action"><i class="icon icon-copy"></i><span class="label">复制结果</span><span class="key">⌘C</span></div>`,
      copied: `<div class="bar-action copied"><i class="icon icon-check"></i><span class="label">已复制</span></div>`,
      settings: `<div class="bar-action"><span class="label">打开设置</span><span class="key">⌘,</span></div>`,
      status: `<span class="bar-status">${this.getAttribute("status") ?? ""}</span>`,
    };
    const options = this.getAttribute("options")?.split("|") ?? ["翻译", "改进"];
    const selected = this.hasAttribute("options")
      ? Number(this.getAttribute("selected") ?? 0)
      : (mode === "improve" ? 1 : 0);
    const segments = options
      .map((option, index) => `<span${index === selected ? ' class="on"' : ""}>${option}</span>`)
      .join("");
    const hint = options.length > 1 ? `<span class="tab-hint">⇥ 切换</span>` : "";
    this.outerHTML = `
      <div class="bar${this.hasAttribute("processing") ? " processing" : ""}">
        <div class="action-group">
          <div class="seg">${segments}</div>
          ${hint}
        </div>
        ${actions[action]}
      </div>`;
  }
}

class CidaNote extends HTMLElement {
  connectedCallback() {
    const icons = {
      stale: "info",
      unrecognized: "info",
      stopped: "circle-stop",
      failed: "circle-alert",
    };
    const icon = icons[this.getAttribute("kind")] ?? "info";
    this.outerHTML = `<div class="note"><i class="icon icon-${icon}"></i><span>${this.innerHTML}</span></div>`;
  }
}

class CidaMotionNote extends HTMLElement {
  connectedCallback() {
    this.outerHTML = `<div class="motion-note"><i class="icon icon-timer"></i><span>${this.innerHTML}</span></div>`;
  }
}

customElements.define("cida-bar", CidaBar);
customElements.define("cida-note", CidaNote);
customElements.define("cida-motion-note", CidaMotionNote);

// The Settings window (spec/settings.md). Attributes name what a state
// changes: config (see below), language="editing", editing="improve",
// shortcut="custom|recording", grants="all", launch="on", update="available".
class CidaSettings extends HTMLElement {
  connectedCallback() {
    const is = (name, value) => this.getAttribute(name) === value;
    const granted = is("grants", "all");
    const row = (title, caption, controls, align = "") => `
      <div class="row">
        <div class="labels"><b>${title}</b>${caption ? `<small>${caption}</small>` : ""}</div>
        <div class="controls ${align}">${controls}</div>
      </div>`;

    // spec/settings.md §三: free text; language="editing" shows the second field focused.
    const field = (value, extra = "") => `<span class="field text ${extra}">${value}</span>`;
    const languages = row("互译", "其他语言都译成左边",
      `${field("简体中文")}<span class="swap">⇄</span>${is("language", "editing")
        ? field("英式英语<i class=\"caret\"></i>", "focused") : field("English")}`);

    const prompt = (title, preview) => `
      <div class="row prompt">
        <div class="labels"><b>${title}</b><small>${preview}</small></div>
        <span class="button">编辑</span>
      </div>`;
    const improve = is("editing", "improve")
      ? `<div class="prompt-editor">
           <div class="head"><b>改进</b><span class="link">恢复默认</span></div>
           <div class="sheet">You are a writing assistant. Improve the user-provided text for clarity, grammar, and natural tone. Keep the original language and meaning. Prefer precise technical wording. Return only the improved text.</div>
           <small>自动保存 · 目标语言与任务由应用传入，不必写占位符</small>
         </div>`
      : prompt("改进", "You are a writing assistant. Improve the user-provided text…");

    const shortcut = is("shortcut", "recording")
      ? row("全局快捷键", "Esc 取消", `<span class="chip recording">按下新组合…</span>`, "end")
      : is("shortcut", "custom")
        ? row("全局快捷键", "在任何应用里显示辞达", `<span class="link">恢复默认</span><span class="chip">⌃ ⌥ T</span>`, "end spaced")
        : row("全局快捷键", "在任何应用里显示辞达", `<span class="chip">⌥ Space</span>`, "end");
    const capture = granted
      ? row("截图翻译", "框选屏幕文字并翻译", `<span class="chip">⌥ S</span>`, "end")
      : row("截图翻译", "需要屏幕录制权限", `<span class="button">去授权</span><span class="chip">⌥ S</span>`, "end");
    const imageWindow = this.getAttribute("capture-result") === "image-window";
    const captureResult = row("截图结果", "下次截图生效", `<div class="capture-mode"><span class="${imageWindow ? "" : "selected"}">原屏幕覆盖</span><span class="${imageWindow ? "selected" : ""}">独立图片窗口</span></div>`, "end");
    const selection = granted
      ? row("选中文字", "唤起时带入并翻译", `<span class="status">已开启</span>`, "end")
      : row("选中文字", "需要辅助功能权限", `<span class="button">去授权</span>`, "end");
    const launch = row("开机启动", "", `<span class="toggle${is("launch", "on") ? " on" : ""}"></span>`, "end");
    const updates = is("update", "available")
      ? row("自动检查更新", "新版本 1.1.0 可以安装", `<span class="button">安装…</span><span class="toggle on"></span>`, "end spaced")
      : row("自动检查更新", "每天检查一次", `<span class="button">检查更新</span><span class="toggle on"></span>`, "end spaced");

    // The agent-configured model group (spec/configuration.md §四):
    // config="unset|unset-copied|ready|updated|checking|failed".
    const config = this.getAttribute("config") ?? "ready";
    const copyIcon = `<i class="icon icon-copy"></i>`;
    const statusCaption = {
      ready: `<span class="dot-caption"><i></i>已就绪</span>`,
      updated: `<span class="dot-caption"><i></i>已就绪 · 刚刚更新</span>`,
      checking: `<span class="dot-caption pending"><i></i>正在检查…</span>`,
      failed: `<span class="dot-caption pending"><i></i>检查失败</span>`,
    }[config];
    const serviceRow = `
      <div class="row">
        <div class="labels"><b>模型服务</b><small>${statusCaption}</small></div>
        <div class="controls">
          <div class="stack summary"><b>deepseek-chat</b><small>api.deepseek.com · Chat Completions</small></div>
          <span class="button push">${config === "checking" ? "检查中…" : "检查"}</span>
        </div>
      </div>`;
    const failure = config === "failed"
      ? `<div class="row-note"><i class="icon icon-circle-alert"></i><span>401 · 服务商拒绝了 API Key。复制配置提示词，让 AI 助手修好。</span></div>`
      : "";
    const adjustRow = row("调整配置", "交给 AI 助手", `<span class="button with-icon">${copyIcon}复制配置提示词</span>`, "end");
    const onboarding = (copied) => `
      <div class="agent-card">
        <div class="labels">
          <b>还没有模型服务</b>
          <small>${copied
            ? "已复制。粘贴给你的 AI 助手，配好后这里会自动更新。"
            : "复制配置提示词，交给 Claude Code、Codex 等 AI 助手。它会问你用哪家服务，配好后自己检查。"}</small>
        </div>
        ${copied
          ? `<span class="button copied with-icon"><i class="icon icon-check"></i>已复制</span>`
          : `<span class="button with-icon">${copyIcon}复制配置提示词</span>`}
      </div>`;
    const modelGroup = config.startsWith("unset")
        ? onboarding(config === "unset-copied")
        : `${serviceRow}${failure}${adjustRow}`;

    this.outerHTML = `
      <section class="window" style="position: relative" data-state="${this.getAttribute("state")}">
        <div class="titlebar"><div class="lights"><i></i><i></i><i></i></div><div class="title">设置</div></div>
        <div class="settings">
          <div class="group"><h3>模型</h3>${modelGroup}</div>
          <div class="group"><h3>语言</h3>${languages}</div>
          <div class="group"><h3>提示词</h3>${prompt("翻译", "Translate the user-provided text into the target language…")}${improve}</div>
          <div class="group"><h3>唤起</h3>${shortcut}${capture}${captureResult}${selection}${launch}</div>
          <div class="group"><h3>更新</h3>${updates}</div>
          <div class="footer"><span class="wordmark">辞达</span><small>1.0 · 辞达而已矣</small></div>
        </div>
      </section>`;
  }
}

customElements.define("cida-settings", CidaSettings);

// A frozen screen for the capture overlay (spec/panel.md §一 截图翻译):
// <cida-frozen-screen dark lifted hint>. The lifted sheet frames the second
// paragraph and shows the frozen window through its own opening.
class CidaFrozenScreen extends HTMLElement {
  connectedCallback() {
    const phase = this.getAttribute("phase");
    const statuses = {
      recognizing: "正在识别文字…",
      translating: "正在翻译…",
      translated: "翻译完成 · 按住空格查看原文",
      unrecognized: "截图里没有识别到文字",
      failed: "文字识别失败，请重新框选。",
    };
    const window = (style = "") => `
      <div class="frozen-window" style="${style}">
        <h2>Storage engine</h2>
        <p>The new storage engine keeps every write in an append-only log and compacts it in the background, so reads never wait for a merge.</p>
        <p>${phase === "translated" ? "快照无需暂停写入。每个快照记录当时的日志位置，恢复时从该位置重放日志。" : "Snapshots are taken without pausing writers. Each one records the log position it saw, and recovery replays the log from there."}</p>
        <p>Benchmarks on a four-core machine show three times the read throughput of the previous engine while data stays consistent.</p>
      </div>`;
    const sheet = { left: 164, top: 364, width: 872, height: 74 };
    const lifted = this.hasAttribute("lifted")
      ? `<div class="lifted" style="left: ${sheet.left}px; top: ${sheet.top}px; width: ${sheet.width}px; height: ${sheet.height}px">
           ${window(`left: ${120 - sheet.left - 1}px; top: ${210 - sheet.top - 1}px`)}
         </div>`
      : "";
    this.outerHTML = `
      <section class="screen${this.hasAttribute("dark") ? " dark" : ""}" data-state="${this.getAttribute("state")}">
        ${window()}
        ${phase ? "" : '<div class="veil"></div>'}
        ${lifted}
        ${phase ? `<div class="capture-status">${statuses[phase]} · Esc 退出</div>` : '<div class="capture-hint"><span class="wordmark">辞达</span><span>拖动框选要翻译的文字 · Esc 取消</span></div>'}
      </section>`;
  }
}

customElements.define("cida-frozen-screen", CidaFrozenScreen);

// The menu bar item's menu (spec/updates.md §二): <cida-status-menu update="available">.
class CidaStatusMenu extends HTMLElement {
  connectedCallback() {
    const available = this.getAttribute("update") === "available";
    const item = (title, key = "") => `<span class="item"><b>${title}</b><kbd>${key}</kbd></span>`;
    this.outerHTML = `
      <section class="status-menu-scene" data-state="${this.getAttribute("state")}">
        <div class="menubar"><span class="status-mark"><img src="../../Sources/Cida/Resources/Brand/status-item-glyph.svg" alt="辞达"><img src="../../Sources/Cida/Resources/Brand/status-item-caret.svg" alt=""></span><span>周四 14:40</span></div>
        <div class="status-menu">
          ${item("显示辞达", "⌥ 空格键")}${item("截图翻译", "⌥ S")}${item("设置…", "⌘,")}
          ${available ? item("安装新版本 1.1.0…") : item("检查更新…")}
          <i class="separator"></i>
          ${item("退出辞达", "⌘Q")}
        </div>
      </section>`;
  }
}

customElements.define("cida-status-menu", CidaStatusMenu);
