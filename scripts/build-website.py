#!/usr/bin/env python3
"""Builds cida.xuanwo.io (Design/spec/website.md) from website/ into build/website.

The pages load the app's design tokens, components and brand files from where they live in the
checkout. Publishing them copies website/ as it is, maps each path outside it to a file under
/assets (failing on one it does not know), and fills the data-site values and the
<!-- site:name --> blocks from the newest release tag and docs/releases.

The fonts and clips are prepared ahead and committed: website/assets/fonts holds WOFF2 subsets of
the app's fonts, and the build fails when a page uses a character they do not cover. After
changing the text, subset them again with --subset-fonts, which needs fontTools and brotli
(pip install fonttools brotli). The clips come from scripts/make-demo-media.py.

    scripts/build-website.py [--output build/website]
    scripts/build-website.py --subset-fonts
"""

import argparse
import datetime
import html
import importlib.util
import pathlib
import re
import shutil
import subprocess

PROJECT_ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = PROJECT_ROOT / "website"
PAGES = ["index.html", "en/index.html", "releases/index.html"]
# Files outside website/ that a page may reference, and where they are published.
SHARED = {
    "Design/boards/tokens.css": "/assets/tokens.css",
    "Design/boards/components.css": "/assets/components.css",
    "Design/boards/components.js": "/assets/components.js",
    "Design/rendered/states/brand-icon.png": "/icon.png",
    "Resources/AppIcon.icon/Assets/glyph.svg": "/assets/glyph.svg",
    "Resources/AppIcon.icon/Assets/caret.svg": "/assets/caret.svg",
}
# The app's fonts the site uses, by file, and their subsets; tokens.css drops every other face.
FONTS = {
    "Inter[opsz,wght].ttf": "inter.woff2",
    "SourceSerif4[opsz,wght].ttf": "source-serif-4.woff2",
    "NotoSerifSC[wght].ttf": "noto-serif-sc.woff2",
}
FONT_DIRECTORY = SOURCE / "assets/fonts"
# The characters the subsets cover, one line, written with them.
CHARSET = FONT_DIRECTORY / "charset.txt"
RELEASE_TAG = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")


def releases():
    """The released versions, newest first, with their tag dates and notes."""
    spec = importlib.util.spec_from_file_location(
        "release_notes", PROJECT_ROOT / "scripts/ci/release-notes.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    listing = subprocess.run(
        ["git", "for-each-ref", "--format=%(refname:short) %(creatordate:short)", "refs/tags/v*"],
        cwd=PROJECT_ROOT, check=True, capture_output=True, text=True).stdout
    found = []
    for line in listing.splitlines():
        tag, date = line.split()
        match = RELEASE_TAG.match(tag)
        if not match:
            continue
        notes = PROJECT_ROOT / "docs/releases" / f"{tag[1:]}.md"
        found.append({
            "key": tuple(int(part) for part in match.groups()),
            "version": tag[1:],
            "date": datetime.date.fromisoformat(date),
            "notes": module.read_notes(notes) if notes.is_file() else None,
        })
    found.sort(key=lambda release: release["key"], reverse=True)
    if len(found) < 2 or not found[0]["notes"]:
        raise SystemExit("the site needs two release tags and notes for the newest one; fetch the tags")
    return found


def release_content(found):
    """The data-site values and site: blocks."""
    latest = found[0]
    notes = "\n".join(f"          <p>{html.escape(item)}</p>" for item in latest["notes"])
    rows = []
    for release in (release for release in found if release["notes"]):
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


def fill(page, values, blocks):
    def value(match):
        if match.group(2) not in values:
            raise SystemExit(f"unknown data-site value {match.group(2)}")
        return f"{match.group(1)}{html.escape(values[match.group(2)])}{match.group(3)}"

    def block(match):
        if match.group(1) not in blocks:
            raise SystemExit(f"unknown site block {match.group(1)}")
        return blocks[match.group(1)]

    page = re.sub(r'(<span data-site="([\w-]+)">)[^<]*(</span>)', value, page)
    return re.sub(r"<!-- site:([\w-]+) -->.*?<!-- /site:\1 -->", block, page, flags=re.S)


def publish_shared_paths(page, page_path):
    """Maps each path that leaves website/ to its published file; others stay relative."""

    def attribute(match):
        name, reference = match.groups()
        if re.match(r"^(https?:|mailto:|data:|/|#)", reference):
            return match.group(0)
        target = (page_path.parent / reference).resolve()
        if target.is_relative_to(SOURCE):
            return match.group(0)
        shared = target.relative_to(PROJECT_ROOT).as_posix()
        if shared not in SHARED:
            raise SystemExit(f"{page_path.relative_to(PROJECT_ROOT)}: {reference} is not a published file")
        return f'{name}="{SHARED[shared]}"'

    page = re.sub(r'\b(href|src|poster)="([^"]+)"', attribute, page)
    return re.sub(r"<!-- Rules:.*?-->\n", "", page, flags=re.S)


def publish_tokens(output):
    """tokens.css with each used font pointing at its subset. The pages preload the fonts, so
    `block` shows the text once, in its own face, instead of swapping it in after a fallback."""
    tokens = (PROJECT_ROOT / "Design/boards/tokens.css").read_text(encoding="utf-8")

    def face(match):
        source = re.search(r'url\("[^"]*/([^/"]+)"\)', match.group(0)).group(1)
        source = source.replace("%5B", "[").replace("%5D", "]")
        if source not in FONTS:
            return ""
        return re.sub(r'src: url\("[^"]+"\) format\("truetype"\);',
                      f'src: url("/assets/fonts/{FONTS[source]}") format("woff2");\n  font-display: block;',
                      match.group(0))

    (output / "assets/tokens.css").write_text(
        re.sub(r"@font-face \{.*?\}\n?", face, tokens, flags=re.S), encoding="utf-8")


def site_text():
    """Every character the pages and their scripts can show."""
    files = [SOURCE / name for name in PAGES] + [SOURCE / "site.js", PROJECT_ROOT / "Design/boards/components.js"]
    text = "".join(path.read_text(encoding="utf-8") for path in files)
    return {character for character in text if character.isprintable() and not character.isspace()}


def subset_fonts():
    from fontTools import subset

    # Every printable ASCII character stays, so a small copy edit rarely needs a new subset.
    characters = sorted(site_text() | {chr(code) for code in range(0x21, 0x7F)})
    options = subset.Options()
    options.flavor = "woff2"
    options.layout_features = ["*"]
    FONT_DIRECTORY.mkdir(parents=True, exist_ok=True)
    for source, name in FONTS.items():
        font = subset.load_font(str(PROJECT_ROOT / "Sources/Cida/Resources/Fonts" / source), options)
        subsetter = subset.Subsetter(options)
        subsetter.populate(text="".join(characters))
        subsetter.subset(font)
        subset.save_font(font, str(FONT_DIRECTORY / name), options)
    CHARSET.write_text("".join(characters) + "\n", encoding="utf-8")
    print(f"subset {len(characters)} characters into {FONT_DIRECTORY.relative_to(PROJECT_ROOT)}")


def build(output):
    missing = site_text() - set(CHARSET.read_text(encoding="utf-8").strip())
    if missing:
        raise SystemExit(f"the fonts do not cover {''.join(sorted(missing))}; run {__file__} --subset-fonts")

    shutil.rmtree(output, ignore_errors=True)
    shutil.copytree(SOURCE, output, ignore=shutil.ignore_patterns("wrangler.jsonc", "charset.txt"))
    values, blocks = release_content(releases())
    for name in PAGES:
        page = fill((SOURCE / name).read_text(encoding="utf-8"), values, blocks)
        (output / name).write_text(publish_shared_paths(page, SOURCE / name), encoding="utf-8")
    for shared, published in SHARED.items():
        if shared != "Design/boards/tokens.css":
            shutil.copyfile(PROJECT_ROOT / shared, output / published.lstrip("/"))
    publish_tokens(output)
    print(f"built {output}")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--output", type=pathlib.Path, default=PROJECT_ROOT / "build/website")
    parser.add_argument("--subset-fonts", action="store_true", help="subset the fonts again and stop")
    arguments = parser.parse_args()
    if arguments.subset_fonts:
        subset_fonts()
    else:
        build(arguments.output.resolve())


if __name__ == "__main__":
    main()
