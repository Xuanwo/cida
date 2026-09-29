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
  const text = panel.querySelector(".result .text");
  const bar = panel.querySelector(".bar");
  const action = bar.querySelector(".bar-action");
  const segmenter = new Intl.Segmenter(document.documentElement.lang, { granularity: "grapheme" });
  const cursor = document.createElement("span");

  const setProcessing = processing => {
    bar.classList.toggle("processing", processing);
    action.innerHTML = processing ? stopAction : copyAction;
  };
  const showPassage = (target, passage, result) => {
    target.querySelector(".source").textContent = passage.source;
    const pane = target.querySelector(".result .text");
    pane.classList.toggle("cjk", passage.cjk);
    pane.textContent = result;
  };

  // The panel grows while it writes, as in the app; the stage keeps the finished height of the
  // longest passage so nothing below it moves.
  const reserveHeight = () => {
    const probe = panel.cloneNode(true);
    probe.setAttribute("aria-hidden", "true");
    Object.assign(probe.style, { position: "absolute", visibility: "hidden", width: `${panel.offsetWidth}px` });
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
    setProcessing(false);
    return;
  }

  // One passage: a simulated network hands over chunks of a few characters, and the renderer
  // drains that buffer at the app's rate (§一), each character fading in behind the head (§二).
  const stream = async passage => {
    const characters = [...segmenter.segment(passage.result)].map(part => part.segment);
    source.textContent = passage.source;
    text.classList.toggle("cjk", passage.cjk);
    text.replaceChildren(cursor);
    cursor.className = "cursor breathing";
    setProcessing(true);
    source.classList.remove("leaving");
    text.classList.remove("leaving");

    const arrivals = [];
    for (let time = 900, count = 0; count < characters.length; time += 60 + Math.random() * 100) {
      count = Math.min(characters.length, count + 3 + Math.floor(Math.random() * 5));
      arrivals.push({ time, count });
    }
    const [catchup, minimum, maximum, alpha] =
      ["catchup-ms", "rate-min-cps", "rate-max-cps", "rate-alpha"].map(motion);
    const start = performance.now();
    let previous = start;
    let rate = minimum;
    let budget = 0;
    let shown = 0;
    while (shown < characters.length) {
      const now = await nextFrame();
      const elapsed = now - start;
      const arrived = arrivals.findLast(arrival => arrival.time <= elapsed)?.count ?? 0;
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

  (async () => {
    for (let index = 0; ; index = (index + 1) % passages.length) {
      await stream(passages[index]);
      await wait(4000);
      source.classList.add("leaving");
      text.classList.add("leaving");
      await wait(300);
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
