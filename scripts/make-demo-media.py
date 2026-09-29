#!/usr/bin/env python3
"""Makes the demo clips from the screen recordings of the demo journey (docs/development.md).

Each recording is a Retina capture of the guest display. The clip is the Chrome window with a
margin of wallpaper, with idle stretches shortened so it keeps moving, and with the last frame
held before it loops. From that one cut it writes:

- docs/images/demo-<name>.gif for the READMEs, sized for their 720 px column on a Retina display;
- website/assets/clips/<name>.mp4 and <name>@2x.mp4 for the website, 760 and 1520 px wide, and
  <name>.jpg, the first frame as the poster.

The outputs are committed; run this again only when the recordings change. Needs ffmpeg.

    scripts/make-demo-media.py <recordings directory with translate.mov, improve.mov, ...>
"""

import argparse
import pathlib
import re
import subprocess

PROJECT_ROOT = pathlib.Path(__file__).resolve().parents[1]
NAMES = ["translate", "improve", "capture", "paragraph", "window"]
# Display pixels of the 1512 × 982 pt guest at 2x: the Chrome window with even margins.
CROP = "crop=2544:1632:240:180"
FPS = 30
# A still stretch keeps this much of itself, in seconds; the last one holds the result.
KEEP_MIDDLE, KEEP_END, HOLD = 1.7, 2.5, 1.5


def still_spans(source):
    """The stretches where nothing moves, and the recording's length."""
    probe = ["ffmpeg", "-hide_banner", "-i", str(source),
             "-vf", f"{CROP},scale=640:-1,fps=12,freezedetect=n=0.002:d=0.6", "-f", "null", "-"]
    log = subprocess.run(probe, capture_output=True, text=True).stderr
    hours, minutes, seconds = re.search(r"Duration: (\d+):(\d+):([\d.]+)", log).groups()
    duration = int(hours) * 3600 + int(minutes) * 60 + float(seconds)
    starts = [float(x) for x in re.findall(r"freeze_start: ([\d.]+)", log)]
    ends = [float(x) for x in re.findall(r"freeze_end: ([\d.]+)", log)]
    ends += [duration] * (len(starts) - len(ends))
    return list(zip(starts, ends)), duration


def cut_filter(source, fps):
    """Crops, drops most of each still stretch, and holds the last frame."""
    spans, duration = still_spans(source)
    cuts = []
    for start, end in spans:
        last = end >= duration - 0.05
        keep = KEEP_END if last else KEEP_MIDDLE
        if end - start > keep:
            cuts.append((start + (keep if last else keep / 2), end - (0 if last else keep / 2)))
    dropped = "+".join(f"between(t,{a:.3f},{b:.3f})" for a, b in cuts) or "0"
    return (f"fps={fps},{CROP},select='not({dropped})',setpts=N/{fps}/TB,"
            f"tpad=stop_mode=clone:stop_duration={HOLD}")


def run(*arguments):
    subprocess.run(["ffmpeg", "-v", "error", "-y", *arguments], check=True)


def make_video(source, cut, width, output):
    run("-i", str(source), "-vf", f"{cut},scale={width}:-2:flags=lanczos",
        "-c:v", "libx264", "-preset", "veryslow", "-tune", "animation", "-crf", "20",
        "-pix_fmt", "yuv420p", "-movflags", "+faststart", "-an", str(output))


def make_gif(source, name, width, fps, output, scratch):
    cut = cut_filter(source, fps)
    palette = scratch / f"{name}-palette.png"
    scaled = f"{cut},scale={width}:-1:flags=lanczos"
    run("-i", str(source), "-vf", f"{scaled},palettegen=max_colors=256:stats_mode=diff", str(palette))
    run("-i", str(source), "-i", str(palette), "-lavfi",
        f"{scaled} [x]; [x][1:v] paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle", str(output))


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("recordings", type=pathlib.Path)
    parser.add_argument("--only", choices=NAMES, action="append", help="make only these clips")
    parser.add_argument("--gif-width", type=int, default=1440)
    parser.add_argument("--gif-fps", type=int, default=15)
    arguments = parser.parse_args()

    clips = PROJECT_ROOT / "website/assets/clips"
    clips.mkdir(parents=True, exist_ok=True)
    scratch = PROJECT_ROOT / "build/demo-media"
    scratch.mkdir(parents=True, exist_ok=True)
    for name in arguments.only or NAMES:
        source = arguments.recordings / f"{name}.mov"
        cut = cut_filter(source, FPS)
        make_video(source, cut, 760, clips / f"{name}.mp4")
        make_video(source, cut, 1520, clips / f"{name}@2x.mp4")
        run("-i", str(clips / f"{name}@2x.mp4"), "-frames:v", "1", "-q:v", "3", str(clips / f"{name}.jpg"))
        gif = PROJECT_ROOT / f"docs/images/demo-{name}.gif"
        make_gif(source, name, arguments.gif_width, arguments.gif_fps, gif, scratch)
        sizes = ", ".join(f"{path.name} {path.stat().st_size / 1e6:.2f} MB" for path in
                          [clips / f"{name}.mp4", clips / f"{name}@2x.mp4", gif])
        print(f"{name}: {sizes}")


if __name__ == "__main__":
    main()
