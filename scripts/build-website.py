#!/usr/bin/env python3
"""Builds cida.xuanwo.io (Design/spec/website.md) from website/ into build/website.

The pages in website/ are written against the checkout, so the design board renders them as
they are. Publishing them:

- maps every local path to a file under /assets, and fails on a path it does not know;
- fills the data-site values and the <!-- site:name --> blocks from the release tags and
  docs/releases, so the page shows the newest version that has actually been released;
- turns each GIF clip into an MP4 with a poster frame;
- ships the fonts as WOFF2 subsets holding only the characters the site uses.

Needs git with the release tags, ffmpeg, and fontTools with brotli (pip install fonttools brotli).

    scripts/build-website.py [--output build/website]
"""

import argparse
import datetime
import html
import importlib.util
import pathlib
import re
import shutil
import subprocess

from fontTools import subset

PROJECT_ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = PROJECT_ROOT / "website"
PAGES = ["index.html", "en/index.html", "releases/index.html"]

# Every file a page may reference, by its path in the checkout, and where it is published.
ASSETS = {
    "Design/boards/tokens.css": "/assets/tokens.css",
    "Design/boards/components.css": "/assets/components.css",
    "Design/boards/components.js": "/assets/components.js",
    "Design/rendered/states/brand-icon.png": "/icon.png",
    "Resources/AppIcon.icon/Assets/glyph.svg": "/assets/glyph.svg",
    "Resources/AppIcon.icon/Assets/caret.svg": "/assets/caret.svg",
    "website/site.css": "/assets/site.css",
    "website/site.js": "/assets/site.js",
}
CLIPS = "docs/images"
# The fonts tokens.css declares that the site uses; any other @font-face is dropped.
FONTS = {
    "Inter[opsz,wght].ttf": "inter.woff2",
    "SourceSerif4[opsz,wght].ttf": "source-serif-4.woff2",
    "NotoSerifSC[wght].ttf": "noto-serif-sc.woff2",
}
RELEASE_TAG = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")


def load_release_notes():
    path = PROJECT_ROOT / "scripts/ci/release-notes.py"
    spec = importlib.util.spec_from_file_location("release_notes", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.read_notes


def releases():
    """The released versions, newest first, with their tag dates and notes."""
    read_notes = load_release_notes()
    listing = subprocess.run(
        ["git", "for-each-ref", "--format=%(refname:short) %(creatordate:short)", "refs/tags/v*"],
        cwd=PROJECT_ROOT, check=True, capture_output=True, text=True).stdout
    found = []
    for line in listing.splitlines():
        tag, date = line.split()
        match = RELEASE_TAG.match(tag)
        if not match:
            continue
        version = tag[1:]
        notes_path = PROJECT_ROOT / "docs/releases" / f"{version}.md"
        notes = read_notes(notes_path) if notes_path.is_file() else None
        found.append({
            "key": tuple(int(part) for part in match.groups()),
            "version": version,
            "date": datetime.date.fromisoformat(date),
            "notes": notes,
        })
    found.sort(key=lambda release: release["key"], reverse=True)
    if len(found) < 2 or not found[0]["notes"]:
        raise SystemExit("the site needs two release tags and notes for the newest one; fetch the tags")
    return found


def fill(page, values, blocks):
    def value(match):
        name = match.group(2)
        if name not in values:
            raise SystemExit(f"unknown data-site value {name}")
        return f"{match.group(1)}{html.escape(values[name])}{match.group(3)}"

    def block(match):
        name = match.group(1)
        if name not in blocks:
            raise SystemExit(f"unknown site block {name}")
        return blocks[name]

    page = re.sub(r'(<span data-site="([\w-]+)">)[^<]*(</span>)', value, page)
    return re.sub(r"<!-- site:([\w-]+) -->.*?<!-- /site:\1 -->", block, page, flags=re.S)


def release_blocks(found):
    latest = found[0]
    notes = "\n".join(f"          <p>{html.escape(item)}</p>" for item in latest["notes"])
    rows = []
    for release in found:
        if not release["notes"]:
            continue
        date = release["date"]
        items = "\n".join(f"      <li>{html.escape(item)}</li>" for item in release["notes"])
        rows.append(
            f'  <article class="release">\n'
            f'    <div><h2>辞达 {release["version"]}</h2>'
            f'<time datetime="{date.isoformat()}">{date.year} 年 {date.month} 月 {date.day} 日</time></div>\n'
            f"    <ul>\n{items}\n    </ul>\n  </article>")
    values = {"version": latest["version"], "previous-version": found[1]["version"]}
    blocks = {"latest-notes": notes.strip(), "releases": "\n".join(rows).strip()}
    return values, blocks


def publish_paths(page, page_path, used):
    """Replaces the page's local paths with published ones and records what it uses."""

    def published(reference):
        target = (page_path.parent / reference).resolve().relative_to(PROJECT_ROOT).as_posix()
        if target not in ASSETS:
            raise SystemExit(f"{page_path.relative_to(PROJECT_ROOT)}: {reference} is not a published asset")
        used.add(target)
        return ASSETS[target]

    def clip(match):
        target = (page_path.parent / match.group(1)).resolve().relative_to(PROJECT_ROOT)
        if target.parent.as_posix() != CLIPS or target.suffix != ".gif":
            raise SystemExit(f"{page_path.relative_to(PROJECT_ROOT)}: clip {match.group(1)} is not in {CLIPS}")
        used.add(target.as_posix())
        name = target.stem
        return (f'<video class="clip" src="/assets/{name}.mp4" poster="/assets/{name}.jpg" '
                f'muted loop playsinline preload="none" aria-label="{match.group(2)}"></video>')

    def attribute(match):
        name, reference = match.group(1), match.group(2)
        if re.match(r"^(https?:|mailto:|data:|/|#)", reference):
            return match.group(0)
        return f'{name}="{published(reference)}"'

    page = re.sub(r'<img class="clip" src="([^"]+)" alt="([^"]*)">', clip, page)
    page = re.sub(r'\b(href|src|poster)="([^"]+)"', attribute, page)
    return re.sub(r"<!-- Rules:.*?-->\n", "", page, flags=re.S)


def publish_tokens(output):
    """tokens.css with each used font pointing at its subset; other faces are dropped."""
    tokens = (PROJECT_ROOT / "Design/boards/tokens.css").read_text(encoding="utf-8")

    def face(match):
        source = re.search(r'url\("[^"]*/([^/"]+)"\)', match.group(0)).group(1)
        source = source.replace("%5B", "[").replace("%5D", "]")
        if source not in FONTS:
            return ""
        return re.sub(r'src: url\("[^"]+"\) format\("truetype"\);',
                      f'src: url("/assets/fonts/{FONTS[source]}") format("woff2");\n  font-display: swap;',
                      match.group(0))

    (output / "assets/tokens.css").write_text(
        re.sub(r"@font-face \{.*?\}\n?", face, tokens, flags=re.S), encoding="utf-8")


def publish_fonts(output, text):
    options = subset.Options()
    options.flavor = "woff2"
    options.layout_features = ["*"]
    (output / "assets/fonts").mkdir(parents=True)
    for source, name in FONTS.items():
        font = subset.load_font(str(PROJECT_ROOT / "Sources/Cida/Resources/Fonts" / source), options)
        subsetter = subset.Subsetter(options)
        subsetter.populate(text=text)
        subsetter.subset(font)
        subset.save_font(font, str(output / "assets/fonts" / name), options)


def publish_clip(output, gif):
    ffmpeg = ["ffmpeg", "-loglevel", "error", "-y", "-i", str(gif)]
    subprocess.run(ffmpeg + [
        "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", "-pix_fmt", "yuv420p",
        "-c:v", "libx264", "-preset", "slow", "-crf", "24", "-movflags", "+faststart",
        str(output / f"assets/{gif.stem}.mp4")], check=True)
    subprocess.run(ffmpeg + ["-frames:v", "1", "-q:v", "3", str(output / f"assets/{gif.stem}.jpg")],
                   check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--output", type=pathlib.Path, default=PROJECT_ROOT / "build/website")
    output = parser.parse_args().output.resolve()
    shutil.rmtree(output, ignore_errors=True)
    (output / "assets").mkdir(parents=True)

    values, blocks = release_blocks(releases())
    used = set()
    shipped_text = []
    for name in PAGES:
        source = SOURCE / name
        page = fill(source.read_text(encoding="utf-8"), values, blocks)
        page = publish_paths(page, source, used)
        (output / name).parent.mkdir(parents=True, exist_ok=True)
        (output / name).write_text(page, encoding="utf-8")
        shipped_text.append(page)

    for target in sorted(used):
        path = PROJECT_ROOT / target
        if target.startswith(CLIPS + "/"):
            publish_clip(output, path)
        elif target == "Design/boards/tokens.css":
            publish_tokens(output)
        else:
            shutil.copyfile(path, output / ASSETS[target].lstrip("/"))
        if path.suffix == ".js":
            shipped_text.append(path.read_text(encoding="utf-8"))

    # Every printable ASCII character stays, so a small copy edit never falls back to another font.
    text = "".join(shipped_text) + "".join(chr(code) for code in range(0x20, 0x7F))
    publish_fonts(output, text)
    for path in sorted(output.rglob("*")):
        if path.is_file():
            print(f"{path.stat().st_size:>9}  {path.relative_to(output)}")


if __name__ == "__main__":
    main()
