#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h:h}

if (( $# != 0 )); then
  echo "Usage: $0" >&2
  exit 64
fi

cd "$project_dir"
filter='InteractionReproductionTests/test(ScrollingUpThroughLargeFoldedHistoryDoesNotReadCompleteResults|FoldedHistoryMaterializesOnlyTheViewportPoolDuringHyperScroll|LongResultUsesIncrementalNaturalTextLayoutWithoutNestedScrolling|HighFrequencyResultUpdatesCoalesceNaturalHeightLayout|ComposerVirtualizesLargeDocumentAndLoadsEarlierPagesOnDemand)'
exec swift test --skip-build -Xswiftc -warnings-as-errors --filter "$filter"
