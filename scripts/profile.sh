#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$(dirname "${BASH_SOURCE[0]}")")" && pwd)"
RUNS_DIR="${REPO_DIR}/results/runs"
cd "${REPO_DIR}"

usage() {
    echo "Usage: $0 scan [RUN_ID]"
    echo "       $0 run RUN_ID DEADLINE"
    exit 1
}

check_run_id() {
    if [[ ! "$1" =~ ^[0-9]+_[0-9a-f]{8}_[a-z0-9-]+$ || ! -d "${RUNS_DIR}/$1" ]]; then
        echo "error: '$1' is not a run in ${RUNS_DIR}" >&2
        exit 1
    fi
}

latest_pull_request() {
    gh pr list --repo "${GITHUB_REPOSITORY}" --head "profile/$1" --state all --limit 1 \
        --json state,isDraft --jq '.[] | "\(.state) \(.isDraft)"'
}

scan() {
    local run_ids=() blocked_ids=() run_dirs run_dir id status pull_request state
    if [[ -n "$1" ]]; then
        check_run_id "$1"
        run_dirs=("${RUNS_DIR}/$1/")
    else
        shopt -s nullglob
        run_dirs=("${RUNS_DIR}"/*/)
    fi
    echo "| Run | State |" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
    echo "| --- | --- |" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
    for run_dir in "${run_dirs[@]}"; do
        id="$(basename "${run_dir}")"
        if ! status="$("${PROVOOR}" profile status "${run_dir}")"; then
            state="blocked, provoor profile status failed"
            blocked_ids+=("${id}")
        elif [[ "$(jq -r .supported <<< "${status}")" != true ]]; then
            state="unsupported"
        elif [[ "$(jq -r .missing_files <<< "${status}")" != 0 ]]; then
            state="blocked, $(jq -r .missing_files <<< "${status}") profiled tests have no pprof file"
            blocked_ids+=("${id}")
        elif [[ "$(jq -r .pending <<< "${status}")" == 0 ]]; then
            state="complete"
        else
            pull_request="$(latest_pull_request "${id}")"
            if [[ "${pull_request}" == "CLOSED "* ]]; then
                state="stopped, the pull request is closed"
            elif [[ "${pull_request}" == "OPEN false" ]]; then
                state="in review"
            else
                state="pending, $(jq -r .pending <<< "${status}") of $(jq -r .tests <<< "${status}") tests"
                run_ids+=("${id}")
            fi
        fi
        echo "| ${id} | ${state} |" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
    done
    jq -cn --argjson runs "$(jq -cn '$ARGS.positional' --args "${run_ids[@]}")" \
        '{runs: $runs, blocked: $ARGS.positional}' --args "${blocked_ids[@]}"
}

check_elf() {
    local elf
    elf="$(jq -r '(.instance.extra_args // []) as $args | [range($args | length) as $i
        | if $args[$i] | startswith("--elf=") then $args[$i] | ltrimstr("--elf=")
          elif $args[$i] == "--elf" and $i + 1 < ($args | length) then $args[$i + 1]
          else empty end][0] // ""' "$1/config.json")"
    if [[ ! "${elf}" =~ ^https://github\.com/[^/]+/[^/]+/releases/download/[^/]+/[^/]+$ \
        && ! "${elf}" =~ ^https://raw\.githubusercontent\.com/[^/]+/[^/]+/[0-9a-f]{40}/.+$ ]]; then
        echo "error: ELF '${elf}' is not a release asset or a commit URL" >&2
        exit 1
    fi
}

ensure_pull_request() {
    case "$(latest_pull_request "$1")" in
        "OPEN "* | "CLOSED "*)
            return
            ;;
    esac
    gh pr create --repo "${GITHUB_REPOSITORY}" --draft --base main --head "profile/$1" \
        --title "feat: add profile of $1" --body "Profiles of run \`$1\`." \
        || echo "the pull request opens after the next push"
}

publish() {
    local id="$1" status
    git add -A results/profiles results/estimates
    if ! git diff --cached --quiet; then
        status="$("${PROVOOR}" profile status "${RUNS_DIR}/${id}")"
        git commit -q -m "feat: profile $(( $(jq .tests <<< "${status}") - $(jq .pending <<< "${status}") )) of $(jq .tests <<< "${status}") tests of ${id}"
        git push -q origin "HEAD:profile/${id}"
    fi
    ensure_pull_request "${id}"
}

run() {
    local id="$1" deadline="$2" branch="profile/$1" pull_request remote_head="" lookup_status=0 status pending_before exit_status=0 remaining
    check_run_id "${id}"
    if [[ ! "${deadline}" =~ ^[0-9]+$ ]]; then
        echo "error: deadline '${deadline}' is not seconds since the epoch" >&2
        exit 1
    fi
    check_elf "${RUNS_DIR}/${id}"

    pull_request="$(latest_pull_request "${id}")"
    case "${pull_request}" in
        "CLOSED "* | "OPEN false")
            echo "the pull request of ${id} is ${pull_request}"
            return
            ;;
    esac
    # Exit status 2 means that the branch does not exist.
    remote_head="$(git ls-remote --exit-code origin "refs/heads/${branch}" | cut -f1)" || lookup_status=$?
    if (( lookup_status != 0 && lookup_status != 2 )); then
        echo "error: cannot look up ${branch} on origin" >&2
        exit 1
    fi
    if [[ -n "${remote_head}" && "${pull_request}" != "MERGED "* ]]; then
        git fetch -q --depth 1 origin "${branch}"
        git checkout -q -B "${branch}" FETCH_HEAD
    else
        git fetch -q --depth 1 origin main
        git checkout -q -B "${branch}" FETCH_HEAD
        if [[ "$("${PROVOOR}" profile status "${RUNS_DIR}/${id}" | jq .pending)" == 0 ]]; then
            echo "the profile of ${id} is complete on main"
            return
        fi
        git commit -q --allow-empty -m "chore: start the profile of ${id}"
        git push -q --force-with-lease="refs/heads/${branch}:${remote_head}" origin "HEAD:${branch}"
    fi
    ensure_pull_request "${id}"

    pending_before="$("${PROVOOR}" profile status "${RUNS_DIR}/${id}" | jq .pending)"
    remaining=$(( deadline - $(date +%s) ))
    # A zero duration turns the timeout off.
    if (( remaining <= 0 )); then
        echo "error: the deadline passed before profiling started" >&2
        exit 1
    fi
    timeout -s INT -k 5m "${remaining}" "${PROVOOR}" profile "${RUNS_DIR}/${id}" || exit_status=$?
    publish "${id}"

    status="$("${PROVOOR}" profile status "${RUNS_DIR}/${id}")"
    echo "profile of ${id}: ${status}"
    if [[ "$(jq -r .missing_files <<< "${status}")" != 0 ]]; then
        echo "error: profiled tests of ${id} have no pprof file" >&2
        exit 1
    fi
    if [[ "$(jq -r .pending <<< "${status}")" == 0 ]]; then
        if [[ "$(latest_pull_request "${id}")" == "OPEN true" ]]; then
            gh pr ready --repo "${GITHUB_REPOSITORY}" "${branch}"
            gh pr comment --repo "${GITHUB_REPOSITORY}" "${branch}" \
                --body "Profiled $(( $(jq .tests <<< "${status}") - $(jq .failures <<< "${status}") )) of $(jq .tests <<< "${status}") tests. $(jq .failures <<< "${status}") tests have a recorded guest failure."
        fi
        return
    fi
    if (( exit_status != 0 && exit_status != 124 )); then
        echo "error: provoor profile exited with status ${exit_status}" >&2
        exit 1
    fi
    if [[ "$(jq -r .pending <<< "${status}")" == "${pending_before}" ]]; then
        echo "error: no test of ${id} was profiled" >&2
        exit 1
    fi
    gh workflow run profile.yaml --repo "${GITHUB_REPOSITORY}" --ref main -f "run_id=${id}"
}

# run checks out other versions of this file, which bash reads as it runs, so
# exit shares the line of esac.
case "${1:-}" in
    scan)
        (( $# <= 2 )) || usage
        scan "${2:-}"
        ;;
    run)
        (( $# == 3 )) || usage
        run "$2" "$3"
        ;;
    *)
        usage
        ;;
esac; exit
