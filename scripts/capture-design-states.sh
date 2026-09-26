#!/bin/zsh
set -euo pipefail

# Renders every design board (Design/boards) and every panel and Settings
# state with an isolated, non-activating Debug build, then places each native
# capture next to the board's render of the same state for review. The state
# names are the boards' data-state values (Design/README.md).

script_dir=${0:A:h}
project_dir=${script_dir:h}
implementation_dir="$project_dir/Design/ImplementationCurrent"
reference_dir="$project_dir/Design/rendered/states"
qa_dir="$project_dir/Design/QACurrent"
binary="$project_dir/.build/debug/Cida"
automation_runner="$script_dir/run-isolated-automation.sh"
comparison_renderer="$script_dir/compose-qa.swift"
design_renderer="$script_dir/render-design.swift"

mkdir -p "$implementation_dir" "$qa_dir"
/usr/bin/xcrun swift "$design_renderer" >/dev/null
swift build --package-path "$project_dir"

# Panel states: the capture is the panel at its content height, 800 pt wide.
for state in empty translate improve stale stopped failed long \
  settings settings-custom settings-recording settings-update-available settings-language-editing \
  settings-config-unset settings-config-copied settings-config-ready settings-config-updated \
  settings-config-checking settings-config-failed \
  lifecycle-welcome lifecycle-welcome-submitted lifecycle-update-checking lifecycle-update-found \
  lifecycle-update-downloading lifecycle-update-ready lifecycle-update-current \
  lifecycle-update-failed lifecycle-update-read-only; do
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

# Board renders are the state's own pixels at 2x; resample them to logical
# points so both sides of the comparison share one geometry.
if [[ -d "$reference_dir" ]]; then
  for reference in "$reference_dir"/*.png; do
    name=${reference:t:r}
    implementation="$implementation_dir/$name.png"
    [[ -f "$implementation" ]] || continue
    width=$(/usr/bin/sips --getProperty pixelWidth "$reference" | awk '/pixelWidth/ {print $2}')
    height=$(/usr/bin/sips --getProperty pixelHeight "$reference" | awk '/pixelHeight/ {print $2}')
    /usr/bin/sips --resampleHeightWidth $((height / 2)) $((width / 2)) \
      "$reference" --out "$qa_dir/reference-$name.png" >/dev/null
    /usr/bin/sips \
      --setProperty dpiWidth 72 \
      --setProperty dpiHeight 72 \
      "$qa_dir/reference-$name.png" >/dev/null
    /usr/bin/xcrun swift "$comparison_renderer" \
      "$qa_dir/reference-$name.png" \
      "$qa_dir/implementation-$name.png" \
      "$qa_dir/comparison-$name.png"
  done
fi

echo "$implementation_dir"
