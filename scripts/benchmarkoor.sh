#!/usr/bin/env bash

set -euo pipefail

# Proxy for the benchmarkoor CLI. Arguments pass through untouched except
# --config values pointing at a *.example.yaml template, which are
# materialized next to the template with the placeholders substituted
# from .env and swapped for the generated file.

REPO_DIR="$(cd "$(dirname "$(dirname "${BASH_SOURCE[0]}")")" && pwd)"
ENV_FILE="${REPO_DIR}/.env"

materialize() {
    local template="$1"
    local generated="${template%.example.yaml}.yaml"
    if [[ ! -f "${ENV_FILE}" ]]; then
        echo "error: missing ${ENV_FILE}; copy .env.example and fill it in" >&2
        exit 1
    fi
    set -a
    # shellcheck disable=SC1090
    . "${ENV_FILE}"
    set +a
    : "${CLUSTER_IP:?CLUSTER_IP missing in .env}"
    sed "s|\${CLUSTER_IP}|${CLUSTER_IP}|g" "${template}" > "${generated}"
    printf '%s' "${generated}"
}

args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)
            args+=("$1")
            shift
            case "$1" in
                *.example.yaml)
                    args+=("$(materialize "$1")")
                    ;;
                *)
                    args+=("$1")
                    ;;
            esac
            ;;
        --config=*)
            value="${1#--config=}"
            case "${value}" in
                *.example.yaml)
                    args+=("--config=$(materialize "${value}")")
                    ;;
                *)
                    args+=("$1")
                    ;;
            esac
            ;;
        *)
            args+=("$1")
            ;;
    esac
    shift
done

exec benchmarkoor "${args[@]+"${args[@]}"}"
