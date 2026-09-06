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
# GitHub Pages serves this repo from a subpath, not the domain root, so asset
# and data URLs are built against it.
PAGES_PATH="provoor-runs"
BASE_PATH="/${PAGES_PATH}/"

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
serve_root=""

cleanup() {
    if [[ -L "${parked_results}" ]]; then
        mv "${parked_results}" "${public_results}"
    fi
    if [[ -n "${serve_root}" ]]; then
        rm -rf "${serve_root}"
    fi
}
trap cleanup EXIT

if [[ -L "${public_results}" ]]; then
    mv "${public_results}" "${parked_results}"
fi
(cd "${BENCHMARKOOR_DIR}/ui" && npm ci && npx vite build --base "${BASE_PATH}" --outDir "${SITE_DIR}" --emptyOutDir)

mkdir "${SITE_DIR}/results"
# The results are hard linked, so the site holds no second copy of them. The
# site never edits a file it links, and a delete below drops only its own name.
cp -al "${RESULTS_DIR}/." "${SITE_DIR}/results/"
# The runner logs of a run serve local debugging only, so the site drops them.
find "${SITE_DIR}/results" -name '*.log' -delete
printf '{ "dataSource": "%sresults", "title": "zkVM Benchmarks" }\n' "${BASE_PATH}" > "${SITE_DIR}/config.json"
# Deep links boot the app through the GitHub Pages 404 fallback.
cp "${SITE_DIR}/index.html" "${SITE_DIR}/404.html"

if [[ "${SERVE}" == true ]]; then
    # Serve under BASE_PATH so the preview matches the deployed URL layout. A
    # path with no file answers 404 with the app as the body, the way GitHub
    # Pages does, so a deep link survives a reload and a probe for a missing
    # artifact still reads 404.
    serve_root="$(mktemp -d)"
    ln -s "${SITE_DIR}" "${serve_root}/${PAGES_PATH}"
    echo "Serving http://0.0.0.0:3002${BASE_PATH}"
    python3 - "${serve_root}" "${SITE_DIR}/404.html" <<'EOF'
import http.server, io, os, sys

root, fallback = sys.argv[1], sys.argv[2]

class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=root, **kwargs)

    def send_head(self):
        if os.path.exists(self.translate_path(self.path)):
            return super().send_head()
        body = open(fallback, "rb").read()
        self.send_response(404)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        return io.BytesIO(body)

http.server.ThreadingHTTPServer(("0.0.0.0", 3002), Handler).serve_forever()
EOF
fi
