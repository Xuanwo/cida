// The page's motion (Design/spec/website.md §三): the hero panel translates its passages the way
// the app streams a result (Design/spec/streaming-motion.md), and each usage clip plays only
// while it is on screen. Without JavaScript the page keeps the still frame it was drawn with.

const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;

// The panel's right-hand slot, as components.js draws it.
const stopAction = `<i class="stop-icon"></i><span class="label">停止</span><span class="key">⌘.</span>`;
const copyAction = `<i class="icon icon-copy"></i><span class="label">复制结果</span><span class="key">⌘C</span>`;

const motion = name =>
  Number(getComputedStyle(document.documentElement).getPropertyValue(`--motion-${name}`));
const wait = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
const nextFrame = () => new Promise(resolve => requestAnimationFrame(resolve));

function playHero() {
  const panel = document.querySelector(".hero .panel");
  const data = document.getElementById("hero-passages");
  if (!panel || !data) return;
  const passages = JSON.parse(data.textContent);
  const stage = panel.parentElement;
  const source = panel.querySelector(".source");
  const result = panel.querySelector(".result");
  const text = result.querySelector(".text");
  const bar = panel.querySelector(".bar");
  const action = bar.querySelector(".bar-action");
  const segmenter = new Intl.Segmenter(document.documentElement.lang, { granularity: "grapheme" });
  const graphemes = string => [...segmenter.segment(string)].map(part => part.segment);
  const cursor = text.querySelector(".cursor") ?? document.createElement("span");

  const showPassage = (target, passage, completed) => {
    target.querySelector(".source").textContent = passage.source;
    const pane = target.querySelector(".result .text");
    pane.classList.toggle("cjk", passage.cjk);
    pane.textContent = completed;
  };

  // The panel grows while it writes, as in the app; the stage keeps the finished height of the
  // longest passage so nothing below it moves.
  const reserveHeight = () => {
    const probe = panel.cloneNode(true);
    probe.setAttribute("aria-hidden", "true");
    Object.assign(probe.style, { position: "absolute", visibility: "hidden", width: `${panel.offsetWidth}px` });
    for (const pane of probe.querySelectorAll(".source, .result")) pane.style.height = "";
    stage.append(probe);
    let tallest = 0;
    for (const passage of passages) {
      showPassage(probe, passage, passage.result);
      tallest = Math.max(tallest, probe.offsetHeight);
    }
    probe.remove();
    stage.style.minHeight = `${tallest}px`;
  };
  reserveHeight();
  addEventListener("resize", reserveHeight);

  if (reducedMotion) {
    showPassage(panel, passages[0], passages[0].result);
    bar.classList.remove("processing");
    action.innerHTML = copyAction;
    return;
  }

  // Each pane follows its content's height through a transition (spec/streaming-motion.md §二.3),
  // so the panel grows and settles line by line instead of jumping.
  const sourceText = document.createElement("span");
  sourceText.textContent = source.textContent;
  source.replaceChildren(sourceText);
  const followHeight = (pane, content) => {
    const style = getComputedStyle(pane);
    const padding = parseFloat(style.paddingTop) + parseFloat(style.paddingBottom);
    const minimum = parseFloat(style.minHeight) || 0;
    const update = () => { pane.style.height = `${Math.max(minimum, content.offsetHeight + padding)}px`; };
    update();
    new ResizeObserver(update).observe(content);
  };
  followHeight(source, sourceText);
  followHeight(result, text);

  // The right-hand slot cross-fades between 停止 and 复制结果 (streaming-motion §二.5).
  const setProcessing = processing => {
    bar.classList.toggle("processing", processing);
    action.innerHTML = processing ? stopAction : copyAction;
    action.animate([{ opacity: 0 }, { opacity: 1 }], { duration: motion("icon-swap-ms"), easing: "ease-out" });
  };

  // The next passage arrives the way a new selection does (spec/panel.md §一): the source changes
  // and the finished result turns stale; then it is submitted, the old result clears and the pane
  // settles to one waiting line before the new translation streams in.
  const introduce = async passage => {
    source.classList.add("changing");
    await wait(180);
    sourceText.textContent = passage.source;
    source.classList.remove("changing");
    text.classList.add("stale");
    await wait(900);
    setProcessing(true);
    text.classList.add("clearing");
    await wait(motion("height-ms"));
    text.classList.remove("stale", "clearing");
    text.classList.toggle("cjk", passage.cjk);
    cursor.className = "cursor breathing";
    text.replaceChildren(cursor);
  };

  // One passage: a simulated network hands over chunks of a few characters, and the renderer
  // drains that buffer at the app's rate (§一), each character fading in behind the head (§二).
  // With `resuming`, the page's still frame is the first part of the passage: its characters stay
  // where they are and the fading ones finish their fade, so the first paint is never replaced.
  const stream = async (passage, resuming) => {
    const characters = graphemes(passage.result);
    let shown = 0;
    if (resuming) {
      shown = graphemes(text.textContent).length;
      for (const fading of text.querySelectorAll(".char-in")) fading.classList.add("settled");
    }

    const arrivals = [];
    for (let time = resuming ? 0 : 900, count = shown; count < characters.length; time += 60 + Math.random() * 100) {
      count = Math.min(characters.length, count + 3 + Math.floor(Math.random() * 5));
      arrivals.push({ time, count });
    }
    const [catchup, minimum, maximum, alpha] =
      ["catchup-ms", "rate-min-cps", "rate-max-cps", "rate-alpha"].map(motion);
    const start = performance.now();
    let previous = start;
    let rate = minimum;
    let budget = 0;
    while (shown < characters.length) {
      const now = await nextFrame();
      const elapsed = now - start;
      const arrived = arrivals.findLast(arrival => arrival.time <= elapsed)?.count ?? shown;
      const buffered = arrived - shown;
      const target = Math.min(maximum, Math.max(minimum, buffered / (catchup / 1000)));
      rate += alpha * (target - rate);
      budget = buffered > 0 ? budget + rate * ((now - previous) / 1000) : 0;
      previous = now;
      for (; budget >= 1 && shown < arrived; budget -= 1, shown += 1) {
        const character = document.createElement("span");
        character.className = "arrive";
        character.textContent = characters[shown];
        text.insertBefore(character, cursor);
        cursor.classList.remove("breathing");
      }
    }
    cursor.classList.add("gone");
    setProcessing(false);
  };

  let resuming = text.textContent !== "" && passages[0].result.startsWith(text.textContent);
  (async () => {
    for (let index = 0; ; index = (index + 1) % passages.length) {
      if (!resuming) await introduce(passages[index]);
      await stream(passages[index], resuming);
      resuming = false;
      await wait(3500);
    }
  })();
}

function playClips() {
  const clips = document.querySelectorAll("video.clip");
  if (reducedMotion) {
    clips.forEach(clip => { clip.controls = true; });
    return;
  }
  const observer = new IntersectionObserver(entries => {
    for (const entry of entries) {
      if (entry.isIntersecting) entry.target.play().catch(() => {});
      else entry.target.pause();
    }
  }, { threshold: 0.4 });
  clips.forEach(clip => observer.observe(clip));
}

playHero();
playClips();
