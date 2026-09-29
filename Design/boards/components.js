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

// The Settings window (spec/settings.md). tab="model|translation|shortcuts|general"
// picks the tab (model by default); the other attributes name what a state
// changes: config (see below), language="editing", editing="improve",
// shortcut="custom|unset|recording", grants="all", launch="on", update="available".
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

    // spec/settings.md §四: three recordable shortcuts; shortcut="unset" is someone who only
    // captures text, with 显示辞达 and 原处翻译 cleared.
    const unset = `<span class="link">恢复默认</span><span class="chip unset">未设置</span>`;
    const shortcut = is("shortcut", "recording")
      ? row("显示辞达", "⌫ 不设置 · Esc 取消", `<span class="chip recording">按下新组合…</span>`, "end")
      : is("shortcut", "custom")
        ? row("显示辞达", "在任何应用里唤起", `<span class="link">恢复默认</span><span class="chip">⌃ ⌥ T</span>`, "end spaced")
        : is("shortcut", "unset")
          ? row("显示辞达", "在任何应用里唤起", unset, "end spaced")
          : row("显示辞达", "在任何应用里唤起", `<span class="chip">⌥ A</span>`, "end");
    const capture = row("截图翻译", "框选屏幕文字并翻译", `<span class="chip">⌥ S</span>`, "end");
    const layerShortcut = is("shortcut", "unset")
      ? row("原处翻译", "加 ⇧ 翻译整个窗口", unset, "end spaced")
      : row("原处翻译", "加 ⇧ 翻译整个窗口", `<span class="chip">⌥ D</span>`, "end");
    // spec/settings.md §五: 已开启 once granted, otherwise 去授权.
    const permission = (title, caption) => row(title, caption,
      granted ? `<span class="status">已开启</span>` : `<span class="button">去授权</span>`, "end");
    const launch = row("开机启动", "", `<span class="toggle${is("launch", "on") ? " on" : ""}"></span>`, "end");
    const updates = is("update", "available")
      ? row("更新", "新版本 1.1.0 可以安装", `<span class="button">安装…</span>`, "end")
      : row("更新", "每天自动检查", `<span class="button">检查更新</span>`, "end");
    const feedback = row("反馈", "报告问题或提建议", `<span class="button">去反馈</span>`, "end");

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
          ${config === "updated"
            ? `<div class="stack summary"><b>gpt-5 <span class="reasoning">minimal</span></b><small>api.openai.com</small></div>`
            : `<div class="stack summary"><b>deepseek-chat</b><small>api.deepseek.com</small></div>`}
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

    const tab = this.getAttribute("tab") ?? "model";
    const tabs = [
      ["model", "模型", "sparkles"], ["translation", "翻译", "languages"],
      ["shortcuts", "快捷键", "keyboard"], ["general", "通用", "sliders-horizontal"],
    ];
    const tabBar = `<div class="settings-tabs">${tabs.map(([key, title, icon]) =>
      `<span class="${key === tab ? "on" : ""}"><i class="icon icon-${icon}"></i>${title}</span>`).join("")}</div>`;
    // A tab with one group has no heading: the title names it.
    const content = {
      model: `<div class="group">${modelGroup}</div>`,
      translation: `
        <div class="group"><h3>语言</h3>${languages}</div>
        <div class="group"><h3>提示词</h3>${prompt("翻译", "Translate the user-provided text into the target language…")}${improve}</div>`,
      shortcuts: `
        <div class="group"><h3>快捷键</h3>${shortcut}${capture}${layerShortcut}</div>
        <div class="group"><h3>权限</h3>${permission("辅助功能", "选中文字与原处翻译")}${permission("屏幕录制", "截图翻译")}</div>`,
      general: `
        <div class="group">${launch}${updates}${feedback}</div>
        <div class="footer"><span class="wordmark">辞达</span><small>1.0 · 辞达而已矣</small></div>`,
    }[tab];

    this.outerHTML = `
      <section class="window" style="position: relative"${this.hasAttribute("state") ? ` data-state="${this.getAttribute("state")}"` : ""}>
        <div class="titlebar"><div class="lights"><i></i><i></i><i></i></div><div class="title">${tabs.find(([key]) => key === tab)[1]}</div></div>
        ${tabBar}
        <div class="settings">${content}</div>
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
        <div class="veil"${this.hasAttribute("dark") ? ' data-appearance="dark"' : ""}></div>
        ${lifted}
        <div class="capture-hint"><span class="wordmark">辞达</span><span>拖动框选要翻译的文字 · Esc 取消</span></div>
      </section>`;
  }
}

customElements.define("cida-frozen-screen", CidaFrozenScreen);

// The menu bar item's menu (spec/brand.md §三): <cida-status-menu build="dev"> is a development
// build that names itself first; <cida-status-menu shortcuts="capture-only"> has no shortcut for
// 显示辞达 and shows no key.
class CidaStatusMenu extends HTMLElement {
  connectedCallback() {
    const development = this.getAttribute("build") === "dev";
    const item = (title, key = "") => `<span class="item"><b>${title}</b><kbd>${key}</kbd></span>`;
    this.outerHTML = `
      <section class="status-menu-scene" data-state="${this.getAttribute("state")}">
        <div class="menubar"><span class="status-mark"><img src="../../Sources/Cida/Resources/Brand/status-item-glyph.svg" alt="辞达"><img src="../../Sources/Cida/Resources/Brand/status-item-caret.svg" alt=""></span><span>周四 14:40</span></div>
        <div class="status-menu">
          ${development ? `<span class="item disabled"><b>开发版 1.2.0 (170) · c243eb7</b></span><i class="separator"></i>` : ""}
          ${item("显示辞达", this.getAttribute("shortcuts") === "capture-only" ? "" : "⌥ 空格键")}${item("截图翻译", "⌥ S")}${item("设置…", "⌘,")}
          <i class="separator"></i>
          ${item("退出辞达", "⌘Q")}
        </div>
      </section>`;
  }
}

customElements.define("cida-status-menu", CidaStatusMenu);


// Cida's translations over mock app windows (spec/translation-layer.md):
// <cida-layer-scene app="chat|browser" layer="…">. Translations are always on Cida's paper,
// whatever the app looks like. Chat layers, as a walk through:
//   once-pointing  the pointer rests on a message; nothing yet
//   once-pending   ⌥D: a caret breathes after that message while it is translated
//   once-done      it reads in place, among the originals
//   once-two       ⌥D on another message: both translated, the rest original
//   once-restore   ⌥D on a translated message: it turns back, the other stays
//   once-none      ⌥D with no paragraph under the pointer: the hint pill says so
//   once-failed    the request failed: the paragraph stays original, the hint offers a retry
//   window-on      ⌥⇧D: the window is outlined and the hint pill says how to stop
//   translating    a new message breathes while it waits; the rest is translated
//   window-one-original  ⌥D inside the window turns one message back
//   window-off     ⌥⇧D again: translations fade, the hint pill says it stopped
// Every message sits in the hint pill where the panel and the capture hint appear.
class CidaLayerScene extends HTMLElement {
  connectedCallback() {
    const app = this.getAttribute("app") ?? "chat";
    const layer = this.getAttribute("layer") ?? "translated";
    const wordmark = `<span class="wordmark">辞达</span>`;
    const scene = document.createElement("section");
    scene.className = "screen desk";
    scene.dataset.state = this.getAttribute("state");
    const body = app === "chat" ? this.chat(layer, wordmark) : this.browser(layer);
    const outlined = layer === "window-on" ? " data-outline" : "";
    // What Cida says, at the panel's height (spec/translation-layer.md §五 提示胶囊).
    const hint = {
      "once-none": "这里没有可以翻译的文字",
      "once-failed": "翻译失败 · 点按重试",
      "window-on": "翻译整个窗口 · Slack · 再按 ⌥ ⇧ D 停止",
      "window-off": "已停止翻译这个窗口",
    }[layer];
    const pill = hint ? `<div class="capture-hint">${wordmark}<span>${hint}</span></div>` : "";
    scene.innerHTML = `<div class="mock-window"${outlined}>${body}</div>${pill}`;
    this.replaceWith(scene);
    // Measure after the page and its fonts settle, and again whenever the page is resized
    // (the renderer resizes it to the board before taking snapshots).
    const place = () => document.fonts.ready.then(() => this.placeMarks(scene, wordmark));
    if (document.readyState === "complete") place();
    else window.addEventListener("load", place, { once: true });
    window.addEventListener("resize", place);
  }

  // The pointer on the element marked data-pointer, the hint beside it, and the outline
  // around the element marked data-outline.
  placeMarks(scene, wordmark) {
    const origin = scene.getBoundingClientRect();
    scene.querySelectorAll(".layer-outline, .pointer.placed").forEach((element) => element.remove());
    const outlined = scene.querySelector("[data-outline]");
    if (outlined) {
      const r = outlined.getBoundingClientRect();
      const outline = document.createElement("div");
      outline.className = "layer-outline";
      Object.assign(outline.style, {
        left: `${r.left - origin.left - 3}px`, top: `${r.top - origin.top - 3}px`,
        width: `${r.width + 6}px`, height: `${r.height + 6}px`,
      });
      scene.appendChild(outline);
    }
    const target = scene.querySelector("[data-pointer]");
    if (!target) return;
    const r = target.getBoundingClientRect();
    const x = r.left - origin.left + Math.min(r.width * 0.45, 260), y = r.top - origin.top + Math.min(r.height * 0.35, 30);
    const pointer = document.createElement("i");
    pointer.className = "pointer placed";
    Object.assign(pointer.style, { left: `${x}px`, top: `${y}px` });
    scene.appendChild(pointer);
  }

  chat(layer, wordmark) {
    const messages = [
      ["Maya Chen", "10:02", "#C9A27E",
        "Morning! The compaction job finished overnight, but the manifest count on the prod table went from 1.2k to 3.4k: <span class=\"link\">lancedb#3669</span>",
        "早！压缩任务昨晚跑完了，但生产表的 manifest 数从 1.2k 涨到了 3.4k：<span class=\"link\">lancedb#3669</span>"],
      ["Leo Park", "10:05", "#7E9CC9",
        "That's expected after the schema change. We should schedule a cleanup before Friday's release.",
        "改完 schema 之后这是正常的。我们应该在周五发版前安排一次清理。"],
      ["Maya Chen", "10:07", "#C9A27E",
        "Agreed. Can someone double-check the retention settings? I don't want to drop versions people still query.",
        "同意。有人能再核对一下保留策略吗？我不想删掉大家还在查询的版本。"],
      ["Sam Rivera", "10:12", "#8FB89A",
        "I'll take it. Heads up: the nightly benchmark regressed about 12% on scan-heavy workloads.",
        "我来。提醒一下：夜间基准测试在扫描密集型负载上退步了约 12%。"],
      ["Leo Park", "10:14", "#7E9CC9",
        "Could it be the new prefetch default? Let's pair on it after standup.",
        "会不会是新的预取默认值导致的？站会后我们一起看看。"],
    ];
    // Which messages read as translations and which one breathes.
    const all = [0, 1, 2, 3, 4];
    const translated = {
      "once-done": [2], "once-two": [2, 4], "once-restore": [4],
      "window-on": all, translating: [0, 1, 2, 3], "window-one-original": [0, 1, 3, 4],
    }[layer] ?? [];
    const pending = { "once-pending": 2, translating: 4 }[layer];
    const pointed = { "once-failed": 2, "once-pointing": 2, "once-pending": 2, "once-done": 2, "once-two": 4, "once-restore": 2, "window-one-original": 2 }[layer];
    const card = (text) => `<span class="layer-card layer-text">${text}</span>`;
    const rows = messages.map(([who, time, color, original, translation], index) => {
      let text = original;
      if (translated.includes(index)) text = card(translation);
      if (index === pending) text = `<span class="layer-waiting">${original}</span>`;
      const pointer = index === pointed ? " data-pointer" : "";
      return `<div class="chat-msg"><i class="avatar" style="background: ${color}"></i>
        <div><div class="who">${who}<time>${time}</time></div><div class="text"${pointer}>${text}</div></div></div>`;
    }).join("");
    const empty = layer === "once-none" ? `<div class="chat-empty" data-pointer></div>` : "";
    return `
      <div class="chat-top"><div class="mock-lights"><i></i><i></i><i></i></div><div class="search">搜索 Storage Team</div></div>
      <div class="chat-body">
        <div class="chat-rail"><i></i></div>
        <div class="chat-sidebar"><b>Storage Team</b><small>频道</small>
          <span># general</span><span class="on"># storage-eng</span><span># release</span><span># random</span>
          <small>私信</small><span>Maya Chen</span><span>Leo Park</span><span>Sam Rivera</span></div>
        <div class="chat-main">
          <div class="chat-header"># storage-eng</div>
          <div class="chat-messages"><div class="chat-day">今天</div>${rows}${empty}</div>
          <div class="chat-composer">发消息到 #storage-eng</div>
        </div>
      </div>`;
  }

  browser(layer) {
    const translated = layer === "translated";
    // The article's paragraphs share a sheet of paper; the code between them stays as it is
    // and breaks the sheet in two.
    const sheet = translated ? "layer-sheet" : "";
    const t = (original, translation) =>
      translated ? `<span class="layer-text">${translation}</span>` : original;
    return `
      <div class="browser-tabs"><div class="mock-lights"><i></i><i></i><i></i></div><div class="browser-tab">Why we rewrote the file format</div></div>
      <div class="browser-toolbar"><div class="address">example.dev/blog/file-format</div></div>
      <div class="page">
        <div class="page-nav"><b>Example Engineering</b>Blog<br>Docs<br>Community<br>Careers</div>
        <div class="page-article">
          <div class="${sheet}">
            <h1>${t("Why we rewrote the file format", "我们为什么重写了文件格式")}</h1>
            <div class="meta">${t("Engineering · 8 min read", "工程 · 阅读约 8 分钟")}</div>
            <p>${t("Columnar formats were designed for scans that read a few columns across billions of rows. Modern AI workloads also need fast random access to individual rows, and the old layout made every lookup pay for a full page decode.",
              "列式格式原本是为扫描设计的：在数十亿行里只读取少数几列。如今的 AI 负载还需要快速随机读取单行，而旧的布局让每次查找都得解码一整页。")}</p>
            <p>${t("The new format stores each column in small, independently addressable chunks. A point lookup now touches a single chunk:",
              "新格式把每一列存成可独立寻址的小块。点查询现在只会触及一个小块：")}</p>
          </div>
          <pre class="page-code">rows = table.take([42, 1337])
print(len(rows))</pre>
          <div class="${sheet}">
            <p>${t("In our benchmarks, random access became up to 60 times faster with no regression on full-table scans.",
              "在我们的基准测试中，随机读取最多快了 60 倍，全表扫描没有任何退步。")}</p>
          </div>
        </div>
        <div class="page-toc"><b>ON THIS PAGE</b>Background<br>The new layout<br>Benchmarks<br>What's next</div>
      </div>`;
  }
}

customElements.define("cida-layer-scene", CidaLayerScene);
