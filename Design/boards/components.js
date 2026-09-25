// Parts that repeat across states, as small custom elements so a state reads
// as what differs: <cida-bar mode action processing> and <cida-note kind>.

class CidaBar extends HTMLElement {
  connectedCallback() {
    const mode = this.getAttribute("mode") ?? "translate";
    const action = this.getAttribute("action") ?? "none";
    const actions = {
      none: "",
      stop: `<div class="bar-action"><i class="stop-icon"></i><span class="label">停止</span><span class="key">⌘.</span></div>`,
      copy: `<div class="bar-action"><i class="icon icon-copy"></i><span class="label">复制结果</span><span class="key">⌘C</span></div>`,
      copied: `<div class="bar-action copied"><i class="icon icon-check"></i><span class="label">已复制</span></div>`,
    };
    this.outerHTML = `
      <div class="bar${this.hasAttribute("processing") ? " processing" : ""}">
        <div class="action-group">
          <div class="seg">
            <span${mode === "translate" ? ' class="on"' : ""}>翻译</span>
            <span${mode === "improve" ? ' class="on"' : ""}>改进</span>
          </div>
          <span class="tab-hint">⇥ 切换</span>
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
// changes: provider="custom", key="missing", editing="improve",
// shortcut="custom|recording", grants="all", launch="on", menu="open".
class CidaSettings extends HTMLElement {
  connectedCallback() {
    const is = (name, value) => this.getAttribute(name) === value;
    const custom = is("provider", "custom");
    const granted = is("grants", "all");
    const row = (title, caption, controls, align = "") => `
      <div class="row">
        <div class="labels"><b>${title}</b>${caption ? `<small>${caption}</small>` : ""}</div>
        <div class="controls ${align}">${controls}</div>
      </div>`;
    const menu = (value) => `<span class="menu">${value}<i class="icon icon-chevron-down"></i></span>`;
    const field = (value, extra = "") => `<span class="field ${extra}">${value}</span>`;

    const provider = row("服务商", "", custom
      ? menu("自定义（OpenAI 兼容）")
      : `<div class="stack">${menu("DeepSeek")}<small>api.deepseek.com · Chat Completions</small></div>`);
    const endpoint = row("端点", "OpenAI 格式的接口", field("http://127.0.0.1:8080/v1/chat/completions", "focused"));
    const key = row("API Key", "只存本机钥匙串", custom
      ? field("本地端点可留空", "placeholder")
      : is("key", "missing") ? field("粘贴 API Key", "placeholder") : field("sk-••••••••••••••••3f2a"));
    const model = row("模型", "", custom ? field("qwen3-32b") : menu("deepseek-chat"));
    const readiness = custom
      ? `<div class="readiness"><i></i>本地端点 · 无需 API Key</div>`
      : is("key", "missing")
        ? `<div class="readiness pending"><i></i>还差 API Key</div>`
        : `<div class="readiness"><i></i>已就绪</div>`;

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
    const selection = granted
      ? row("选中文字", "唤起时带入并翻译", `<span class="status">已开启</span>`, "end")
      : row("选中文字", "需要辅助功能权限", `<span class="button">去授权</span>`, "end");
    const launch = row("开机启动", "", `<span class="toggle${is("launch", "on") ? " on" : ""}"></span>`, "end");

    const popover = is("menu", "open")
      ? `<div class="popover" style="left: 172px; top: 107px">
           <span class="current">DeepSeek<i class="icon icon-check"></i></span>
           <span>OpenAI</span><span>Moonshot</span><span>Kimi For Coding</span><span>智谱 GLM</span><span>自定义（OpenAI 兼容）</span>
         </div>`
      : "";

    this.outerHTML = `
      <section class="window" style="position: relative" data-state="${this.getAttribute("state")}">
        <div class="titlebar"><div class="lights"><i></i><i></i><i></i></div><div class="title">设置</div></div>
        <div class="settings">
          <div class="group"><h3>模型</h3>${provider}${custom ? endpoint + model + key : key + model}${readiness}</div>
          <div class="group"><h3>提示词</h3>${prompt("翻译", "Translate the user-provided text into the target language…")}${improve}</div>
          <div class="group"><h3>唤起</h3>${shortcut}${capture}${selection}${launch}</div>
          <div class="footer"><span class="wordmark">辞达</span><small>1.0 · 辞达而已矣</small></div>
        </div>
        ${popover}
      </section>`;
  }
}

customElements.define("cida-settings", CidaSettings);

// A frozen screen for the capture overlay (spec/panel.md §一 截图翻译):
// <cida-frozen-screen dark lifted hint>. The lifted sheet frames the second
// paragraph and shows the frozen window through its own opening.
class CidaFrozenScreen extends HTMLElement {
  connectedCallback() {
    const window = (style = "") => `
      <div class="frozen-window" style="${style}">
        <h2>Storage engine</h2>
        <p>The new storage engine keeps every write in an append-only log and compacts it in the background, so reads never wait for a merge.</p>
        <p>Snapshots are taken without pausing writers. Each one records the log position it saw, and recovery replays the log from there.</p>
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
        <div class="veil"></div>
        ${lifted}
        <div class="capture-hint"><span class="wordmark">辞达</span><span>拖动框选要翻译的文字 · Esc 取消</span></div>
      </section>`;
  }
}

customElements.define("cida-frozen-screen", CidaFrozenScreen);
