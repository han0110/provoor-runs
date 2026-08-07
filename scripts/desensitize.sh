#!/usr/bin/env bash

set -euo pipefail

# Replaces the value of every variable defined in .env with the variable
# name across results/, so published files never carry real addresses.
# Variables apply in .env order and empty values are skipped. Running it
# again finds nothing to replace.

REPO_DIR="$(cd "$(dirname "$(dirname "${BASH_SOURCE[0]}")")" && pwd)"
ENV_FILE="${REPO_DIR}/.env"
RESULTS_DIR="${REPO_DIR}/results"

if [[ ! -f "${ENV_FILE}" ]]; then
    echo "error: missing ${ENV_FILE}; copy .env.example and fill it in" >&2
    exit 1
fi

patterns=()
program=""
while IFS='=' read -r key value; do
    case "${key}" in
        ''|'#'*)
            continue
            ;;
    esac
    if [[ -z "${value}" ]]; then
        continue
    fi
    patterns+=(-e "${value}")
    program+="s|${value}|${key}|g;"
done < "${ENV_FILE}"

if [[ ${#patterns[@]} -eq 0 ]]; then
    exit 0
fi

grep -rlZF "${patterns[@]}" "${RESULTS_DIR}" | xargs -0 -r sed -i "${program}" || true
