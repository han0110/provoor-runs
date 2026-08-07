#!/usr/bin/env bash
# Replaces the value of every variable defined in .env with the variable
# name across results/, so published files never carry real addresses.
# Variables apply in .env order and empty values are skipped. Running it
# again finds nothing to replace.
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f .env ] || { echo "missing .env, copy .env.example and fill it in" >&2; exit 1; }

patterns=()
program=""
while IFS='=' read -r key value; do
    case "$key" in ''|'#'*) continue ;; esac
    [ -n "$value" ] || continue
    patterns+=(-e "$value")
    program+="s|$value|$key|g;"
done < .env
[ ${#patterns[@]} -gt 0 ] || exit 0

grep -rlZF "${patterns[@]}" results | xargs -0 -r sed -i "$program" || true
