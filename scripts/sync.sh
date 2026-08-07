#!/usr/bin/env bash
# Pulls a pruned copy of a remote benchmarkoor results tree into results/.
# Raw runner logs and JSON-RPC request payloads are excluded at transfer
# time, so the repository only ever holds the publishable subset.
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
    echo "usage: scripts/sync.sh --host <user@host> --path <remote-results-dir>" >&2
    exit 1
}

host=""
path=""
while [ $# -gt 0 ]; do
    case "$1" in
        --host) host=$2; shift 2 ;;
        --path) path=$2; shift 2 ;;
        *) usage ;;
    esac
done
[ -n "$host" ] && [ -n "$path" ] || usage

mkdir -p results
rsync -a \
    --exclude container.log \
    --exclude benchmarkoor.log \
    --exclude '*.request' \
    "$host:$path/" results/
