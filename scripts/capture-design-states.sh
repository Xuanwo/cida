#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
implementation_dir="$project_dir/Design/ImplementationCurrent"
reference_dir="$project_dir/Design/LatestReferenceExport"
qa_dir="$project_dir/Design/QACurrent"
binary="$project_dir/.build/debug/Cida"
automation_runner="$script_dir/run-isolated-automation.sh"
comparison_renderer="$script_dir/compose-qa.swift"

mkdir -p "$implementation_dir" "$qa_dir"
swift build --package-path "$project_dir"

for state in translate improve large-input history-folded wide-reading-column settings; do
  "$automation_runner" "$binary" \
    --design-state "$state" \
    --snapshot-output "$implementation_dir/$state.png"
done

"$automation_runner" "$binary" \
  --design-state streaming \
  --snapshot-delay-ms 800 \
  --snapshot-output "$implementation_dir/streaming.png"

/usr/bin/sips --cropToHeightWidth 640 860 --cropOffset 67 90 \
  "$reference_dir/mlf3o.png" \
  --out "$qa_dir/reference-translate.png" >/dev/null
/usr/bin/sips --cropToHeightWidth 640 860 --cropOffset 67 90 \
  "$reference_dir/csGeO.png" \
  --out "$qa_dir/reference-improve.png" >/dev/null
/usr/bin/sips --cropToHeightWidth 640 860 --cropOffset 67 90 \
  "$reference_dir/r2rxd9.png" \
  --out "$qa_dir/reference-large-input.png" >/dev/null
/usr/bin/sips --cropToHeightWidth 640 860 --cropOffset 67 90 \
  "$reference_dir/J9Vlmv.png" \
  --out "$qa_dir/reference-streaming.png" >/dev/null
/usr/bin/sips --cropToHeightWidth 1306 1122 --cropOffset 132 180 \
  "$reference_dir/l1gIe.png" \
  --out "$qa_dir/reference-settings.png" >/dev/null
/usr/bin/sips --resampleHeightWidth 660 560 \
  "$qa_dir/reference-settings.png" >/dev/null

/usr/bin/sips --resampleHeightWidth 640 860 \
  "$implementation_dir/translate.png" \
  --out "$qa_dir/implementation-translate.png" >/dev/null
/usr/bin/sips --resampleHeightWidth 640 860 \
  "$implementation_dir/improve.png" \
  --out "$qa_dir/implementation-improve.png" >/dev/null
/usr/bin/sips --resampleHeightWidth 640 860 \
  "$implementation_dir/large-input.png" \
  --out "$qa_dir/implementation-large-input.png" >/dev/null
/usr/bin/sips --resampleHeightWidth 640 860 \
  "$implementation_dir/streaming.png" \
  --out "$qa_dir/implementation-streaming.png" >/dev/null
/usr/bin/sips --resampleHeightWidth 640 860 \
  "$implementation_dir/history-folded.png" \
  --out "$qa_dir/implementation-history-folded.png" >/dev/null
/usr/bin/sips --resampleHeightWidth 720 1280 \
  "$implementation_dir/wide-reading-column.png" \
  --out "$qa_dir/implementation-wide-reading-column.png" >/dev/null
/usr/bin/sips --resampleHeightWidth 660 560 \
  "$implementation_dir/settings.png" \
  --out "$qa_dir/implementation-settings.png" >/dev/null
for image in "$qa_dir"/implementation-*.png; do
  /usr/bin/sips \
    --setProperty dpiWidth 72 \
    --setProperty dpiHeight 72 \
    "$image" >/dev/null
done

for state in translate improve large-input streaming settings; do
  /usr/bin/xcrun swift "$comparison_renderer" \
    "$qa_dir/reference-$state.png" \
    "$qa_dir/implementation-$state.png" \
    "$qa_dir/comparison-$state.png"
done

echo "$implementation_dir"
