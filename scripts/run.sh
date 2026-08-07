#!/usr/bin/env bash
# Materializes runnable benchmarkoor configs from the *.example.yaml
# templates in the benchmarkoor checkout, ../benchmarkoor unless
# BENCHMARKOOR points elsewhere. Substitutes the placeholders with values
# from .env and writes each result next to its template without the
# .example suffix.
set -euo pipefail
cd "$(dirname "$0")/.."

benchmarkoor=${BENCHMARKOOR:-../benchmarkoor}

[ -f .env ] || { echo "missing .env, copy .env.example and fill it in" >&2; exit 1; }
set -a
. ./.env
set +a
: "${CLUSTER_IP:?CLUSTER_IP missing in .env}"

for template in "$benchmarkoor"/examples/provoor/*.example.yaml; do
    sed "s|\${CLUSTER_IP}|$CLUSTER_IP|g" "$template" > "${template%.example.yaml}.yaml"
done
