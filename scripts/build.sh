#!/usr/bin/env bash
# Builds the static results site into site/ from results/ and a benchmarkoor
# checkout, ../benchmarkoor unless BENCHMARKOOR points elsewhere. Pass
# --serve to host the built site on port 3002 afterwards.
set -euo pipefail
cd "$(dirname "$0")/.."

serve=false
case "${1:-}" in
    "") ;;
    --serve) serve=true ;;
    *) echo "usage: scripts/build.sh [--serve]" >&2; exit 1 ;;
esac

benchmarkoor=${BENCHMARKOOR:-../benchmarkoor}
# Mirrors GO_BUILD_TAGS in the benchmarkoor Makefile.
tags=exclude_graphdriver_btrfs,exclude_graphdriver_devicemapper,containers_image_openpgp
results=$PWD/results
site=$PWD/site

(cd "$benchmarkoor" &&
    CGO_ENABLED=0 go run -tags "$tags" ./cmd/benchmarkoor generate-index-file --method local --results-dir "$results" &&
    CGO_ENABLED=0 go run -tags "$tags" ./cmd/benchmarkoor generate-suite-stats-file --method local --results-dir "$results")

# Vite copies ui/public into the output and follows its results symlink,
# which may target gigabytes of raw results. The build parks the link
# outside public and restores it afterwards.
publicResults=$benchmarkoor/ui/public/results
parkedResults=$benchmarkoor/ui/results.parked
if [ -L "$publicResults" ]; then
    mv "$publicResults" "$parkedResults"
    trap 'mv "$parkedResults" "$publicResults"' EXIT
fi
(cd "$benchmarkoor/ui" && npm ci && npx vite build --outDir "$site" --emptyOutDir)

mkdir "$site/results"
cp -a "$results/." "$site/results/"
printf '{ "dataSource": "/results", "title": "zkVM Benchmarks" }\n' > "$site/config.json"
# Deep links boot the app through the GitHub Pages 404 fallback.
cp "$site/index.html" "$site/404.html"

if $serve; then
    python3 -m http.server 3002 --bind 0.0.0.0 -d "$site"
fi
