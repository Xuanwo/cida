#!/bin/zsh
set -euo pipefail

# Renders every panel state of `States — 面板交互` plus Settings with an
# isolated, non-activating Debug build, then places each native capture next to
# its Pencil export for review. The per-state Pencil exports live in
# Design/LatestReferenceExport/states (node ids in design-qa.md).

script_dir=${0:A:h}
project_dir=${script_dir:h}
implementation_dir="$project_dir/Design/ImplementationCurrent"
reference_dir="$project_dir/Design/LatestReferenceExport/states"
qa_dir="$project_dir/Design/QACurrent"
binary="$project_dir/.build/debug/Cida"
automation_runner="$script_dir/run-isolated-automation.sh"
comparison_renderer="$script_dir/compose-qa.swift"

mkdir -p "$implementation_dir" "$qa_dir"
swift build --package-path "$project_dir"

# Panel states: the capture is the panel at its content height, 800 pt wide.
for state in empty translate improve stale stopped failed long settings settings-missing-key settings-custom; do
  "$automation_runner" "$binary" \
    --design-state "$state" \
    --snapshot-output "$implementation_dir/$state.png"
done

"$automation_runner" "$binary" \
  --design-state streaming \
  --snapshot-delay-ms 800 \
  --snapshot-output "$implementation_dir/streaming.png"

# Logical-size copies for the visual baseline manifest and side-by-side review.
for image in "$implementation_dir"/*.png; do
  name=${image:t:r}
  width=$(/usr/bin/sips --getProperty pixelWidth "$image" | awk '/pixelWidth/ {print $2}')
  height=$(/usr/bin/sips --getProperty pixelHeight "$image" | awk '/pixelHeight/ {print $2}')
  /usr/bin/sips --resampleHeightWidth $((height / 2)) $((width / 2)) \
    "$image" --out "$qa_dir/implementation-$name.png" >/dev/null
  /usr/bin/sips \
    --setProperty dpiWidth 72 \
    --setProperty dpiHeight 72 \
    "$qa_dir/implementation-$name.png" >/dev/null
done

# Pencil references exported per state node (see design-qa.md for the node ids).
# Pencil exports carry a uniform shadow margin around the node; crop the node's
# own pixels (the native capture's 2x size) from the centre, then resample to
# logical points so both sides of the comparison share one geometry.
if [[ -d "$reference_dir" ]]; then
  for reference in "$reference_dir"/*.png; do
    name=${reference:t:r}
    implementation="$implementation_dir/$name.png"
    [[ -f "$implementation" ]] || continue
    node_width=$(/usr/bin/sips --getProperty pixelWidth "$implementation" | awk '/pixelWidth/ {print $2}')
    node_height=$(/usr/bin/sips --getProperty pixelHeight "$implementation" | awk '/pixelHeight/ {print $2}')
    export_width=$(/usr/bin/sips --getProperty pixelWidth "$reference" | awk '/pixelWidth/ {print $2}')
    export_height=$(/usr/bin/sips --getProperty pixelHeight "$reference" | awk '/pixelHeight/ {print $2}')
    # The nodes carry a downward shadow offset (12 pt on panel states, 24 pt on
    # Settings), so the export's top margin is shorter than its bottom margin
    # by twice that offset in pixels.
    offset_x=$(( (export_width - node_width) / 2 ))
    offset_y=$(( (export_height - node_height) / 2 ))
    if [[ "$name" == settings* ]]; then
      offset_y=$(( offset_y - 48 ))
    else
      offset_y=$(( offset_y - 24 ))
    fi
    if (( offset_x < 0 || offset_y < 0 )); then
      echo "Pencil export for $name is smaller than the native capture" >&2
      exit 65
    fi
    /usr/bin/sips --cropToHeightWidth "$node_height" "$node_width" \
      --cropOffset "$offset_y" "$offset_x" \
      "$reference" --out "$qa_dir/reference-$name.png" >/dev/null
    /usr/bin/sips --resampleHeightWidth $((node_height / 2)) $((node_width / 2)) \
      "$qa_dir/reference-$name.png" >/dev/null
    /usr/bin/xcrun swift "$comparison_renderer" \
      "$qa_dir/reference-$name.png" \
      "$qa_dir/implementation-$name.png" \
      "$qa_dir/comparison-$name.png"
  done
fi

echo "$implementation_dir"
