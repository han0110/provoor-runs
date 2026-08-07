#!/usr/bin/env bash

set -euo pipefail

# Builds the static results site into site/ from results/ and a
# benchmarkoor checkout, ../benchmarkoor unless BENCHMARKOOR points
# elsewhere. Pass --serve to host the built site on port 3002 afterwards.

REPO_DIR="$(cd "$(dirname "$(dirname "${BASH_SOURCE[0]}")")" && pwd)"
BENCHMARKOOR_DIR="${BENCHMARKOOR:-${REPO_DIR}/../benchmarkoor}"
# Mirrors GO_BUILD_TAGS in the benchmarkoor Makefile.
GO_BUILD_TAGS="exclude_graphdriver_btrfs,exclude_graphdriver_devicemapper,containers_image_openpgp"
RESULTS_DIR="${REPO_DIR}/results"
SITE_DIR="${REPO_DIR}/site"

SERVE=false

usage() {
    echo "Usage: $0 [--serve]"
    echo ""
    echo "Options:"
    echo "  --serve                        Host the built site on port 3002 after building"
    echo "  --help, -h                     Show this help"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --serve)
            SERVE=true
            shift
            ;;
        --help|-h)
            usage
            ;;
        *)
            echo "error: unknown option '$1'" >&2
            usage
            ;;
    esac
done

(cd "${BENCHMARKOOR_DIR}" \
    && CGO_ENABLED=0 go run -tags "${GO_BUILD_TAGS}" ./cmd/benchmarkoor generate-index-file --method local --results-dir "${RESULTS_DIR}" \
    && CGO_ENABLED=0 go run -tags "${GO_BUILD_TAGS}" ./cmd/benchmarkoor generate-suite-stats-file --method local --results-dir "${RESULTS_DIR}")

# Vite copies ui/public into the output and follows its results symlink,
# which may target gigabytes of raw results. The build parks the link
# outside public and restores it afterwards.
public_results="${BENCHMARKOOR_DIR}/ui/public/results"
parked_results="${BENCHMARKOOR_DIR}/ui/results.parked"
if [[ -L "${public_results}" ]]; then
    mv "${public_results}" "${parked_results}"
    trap 'mv "${parked_results}" "${public_results}"' EXIT
fi
(cd "${BENCHMARKOOR_DIR}/ui" && npm ci && npx vite build --outDir "${SITE_DIR}" --emptyOutDir)

mkdir "${SITE_DIR}/results"
cp -a "${RESULTS_DIR}/." "${SITE_DIR}/results/"
printf '{ "dataSource": "/results", "title": "zkVM Benchmarks" }\n' > "${SITE_DIR}/config.json"
# Deep links boot the app through the GitHub Pages 404 fallback.
cp "${SITE_DIR}/index.html" "${SITE_DIR}/404.html"

if [[ "${SERVE}" == true ]]; then
    python3 -m http.server 3002 --bind 0.0.0.0 -d "${SITE_DIR}"
fi
