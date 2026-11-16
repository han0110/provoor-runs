#!/usr/bin/env bash

set -euo pipefail

# Profiles the benchmark runs in results/runs/ with `provoor profile` and
# delivers each profile through one draft pull request from the branch
# profile/<run_id>. The scan mode prints the ids of the runs to profile as a
# JSON array. The run mode profiles one run until the deadline, then commits
# and pushes the results, so a later invocation continues where this one
# stopped. The PROVOOR variable names the provoor binary, and gh reads GH_TOKEN
# and GITHUB_REPOSITORY.

REPO_DIR="$(cd "$(dirname "$(dirname "${BASH_SOURCE[0]}")")" && pwd)"
RUNS_DIR="${REPO_DIR}/results/runs"
# provoor records the run path relative to the working directory.
cd "${REPO_DIR}"

usage() {
    echo "Usage: $0 scan"
    echo "       $0 run RUN_ID DEADLINE"
    echo ""
    echo "Modes:"
    echo "  scan                  Print the ids of the runs to profile as a JSON array"
    echo "  run RUN_ID DEADLINE   Profile one run until DEADLINE in seconds since the epoch"
    exit 1
}

# latest_pull_request prints the state and the draft flag of the newest pull
# request from the branch of the run, or nothing when there is none.
latest_pull_request() {
    gh pr list --repo "${GITHUB_REPOSITORY}" --head "profile/$1" --state all --limit 1 \
        --json state,isDraft --jq '.[] | "\(.state) \(.isDraft)"'
}

scan() {
    local run_ids=() run_dir id status pull_request state blocked=false
    {
        echo "| Run | State |"
        echo "| --- | --- |"
    } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
    shopt -s nullglob
    for run_dir in "${RUNS_DIR}"/*/; do
        id="$(basename "${run_dir}")"
        status="$("${PROVOOR}" profile status "${run_dir}")"
        pull_request="$(latest_pull_request "${id}")"
        if [[ "$(jq -r .supported <<< "${status}")" != true ]]; then
            state="unsupported"
        elif [[ "$(jq -r .missing_files <<< "${status}")" != 0 ]]; then
            state="blocked, $(jq -r .missing_files <<< "${status}") profiled tests have no pprof file"
            blocked=true
        elif [[ "$(jq -r .pending <<< "${status}")" == 0 ]]; then
            state="complete"
        elif [[ "${pull_request}" == "CLOSED "* ]]; then
            state="stopped, the pull request is closed"
        elif [[ "${pull_request}" == "OPEN false" ]]; then
            state="in review"
        else
            state="pending, $(jq -r .pending <<< "${status}") of $(jq -r .tests <<< "${status}") tests"
            run_ids+=("${id}")
        fi
        echo "| ${id} | ${state} |" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
    done
    jq -cn '$ARGS.positional' --args "${run_ids[@]}"
    if [[ "${blocked}" == true ]]; then
        echo "error: a run is blocked, see the summary" >&2
        exit 1
    fi
}

# check_elf rejects an ELF URL that a later push can change, since the profile
# records the ELF that the URL serves at profiling time. It reads the first
# --elf argument in one or two arguments, as provoor does.
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

# ensure_pull_request opens the draft pull request of the run when none is
# open. A closed pull request stops the run, so it gets no replacement. GitHub
# refuses a pull request before the branch differs from main, so a failure
# here is retried after the next push.
ensure_pull_request() {
    case "$(latest_pull_request "$1")" in
        "OPEN "* | "CLOSED "*)
            return
            ;;
    esac
    gh pr create --repo "${GITHUB_REPOSITORY}" --draft --base main --head "profile/$1" \
        --title "feat: add profile of $1" \
        --body "Profiles of run \`$1\`, which the profile workflow fills in 5.5 hour jobs. The workflow marks it ready when every test has a profile or a recorded guest failure." \
        || echo "the pull request opens after the next push"
}

# publish commits and pushes the profile and the estimate of the run.
publish() {
    local id="$1" status path paths=()
    # A profile that stops before its first record leaves no directory to add.
    for path in "results/profiles/${id}" "results/estimates/${id}"; do
        if [[ -e "${REPO_DIR}/${path}" ]]; then
            paths+=("${path}")
        fi
    done
    if (( ${#paths[@]} > 0 )); then
        git -C "${REPO_DIR}" add -A -- "${paths[@]}"
    fi
    if ! git -C "${REPO_DIR}" diff --cached --quiet; then
        status="$("${PROVOOR}" profile status "${RUNS_DIR}/${id}")"
        git -C "${REPO_DIR}" commit -q -m "feat: profile $(( $(jq .tests <<< "${status}") - $(jq .pending <<< "${status}") )) of $(jq .tests <<< "${status}") tests of ${id}"
        git -C "${REPO_DIR}" push -q origin "HEAD:profile/${id}"
    fi
    ensure_pull_request "${id}"
}

run() {
    local id="$1" deadline="$2" branch="profile/$1" pull_request remote_head="" lookup_status=0 status pending_before exit_status=0 remaining
    if [[ ! "${id}" =~ ^[0-9]+_[0-9a-f]{8}_[a-z0-9-]+$ || ! -d "${RUNS_DIR}/${id}" ]]; then
        echo "error: '${id}' is not a run in ${RUNS_DIR}" >&2
        exit 1
    fi
    if [[ ! "${deadline}" =~ ^[0-9]+$ ]]; then
        echo "error: deadline '${deadline}' is not seconds since the epoch" >&2
        exit 1
    fi
    check_elf "${RUNS_DIR}/${id}"

    # A queued invocation starts after the stop decision of the one before.
    pull_request="$(latest_pull_request "${id}")"
    case "${pull_request}" in
        "CLOSED "*)
            echo "the pull request of ${id} is closed"
            return
            ;;
        "OPEN false")
            echo "the pull request of ${id} is in review"
            return
            ;;
    esac
    # ls-remote exits with 2 when the branch does not exist. Any other failure
    # stops the job, since a new branch would replace the pushed results.
    remote_head="$(git -C "${REPO_DIR}" ls-remote --exit-code origin "refs/heads/${branch}" | cut -f1)" || lookup_status=$?
    if (( lookup_status != 0 && lookup_status != 2 )); then
        echo "error: cannot look up ${branch} on origin" >&2
        exit 1
    fi
    # A merged pull request leaves its results on main, so the branch starts
    # again from main. Any other branch holds results that main lacks.
    if [[ -n "${remote_head}" && "${pull_request}" != "MERGED "* ]]; then
        git -C "${REPO_DIR}" fetch -q --depth 1 origin "${branch}"
        git -C "${REPO_DIR}" checkout -q -B "${branch}" FETCH_HEAD
    else
        # A queued job can start after main moved past its checkout. The
        # latest main gives the push a base that origin advertises, and it can
        # hold the complete profile already.
        git -C "${REPO_DIR}" fetch -q --depth 1 origin main
        git -C "${REPO_DIR}" checkout -q -B "${branch}" FETCH_HEAD
        status="$("${PROVOOR}" profile status "${RUNS_DIR}/${id}")"
        if [[ "$(jq -r .missing_files <<< "${status}")" != 0 ]]; then
            echo "error: profiled tests of ${id} on main have no pprof file" >&2
            exit 1
        fi
        if [[ "$(jq -r .pending <<< "${status}")" == 0 ]]; then
            echo "the profile of ${id} is complete on main"
            return
        fi
        git -C "${REPO_DIR}" commit -q --allow-empty -m "chore: start the profile of ${id}"
        git -C "${REPO_DIR}" push -q --force-with-lease="refs/heads/${branch}:${remote_head}" origin "HEAD:${branch}"
    fi
    ensure_pull_request "${id}"

    pending_before="$("${PROVOOR}" profile status "${RUNS_DIR}/${id}" | jq .pending)"
    # A zero duration turns the timeout off.
    remaining=$(( deadline - $(date +%s) ))
    if (( remaining <= 0 )); then
        echo "error: the deadline passed before profiling started" >&2
        exit 1
    fi
    # The interrupt makes provoor save its records. The kill ends a shutdown
    # that does not return. The concurrency defaults to the core count.
    timeout -s INT -k 5m "${remaining}" "${PROVOOR}" profile "${RUNS_DIR}/${id}" || exit_status=$?
    publish "${id}"

    status="$("${PROVOOR}" profile status "${RUNS_DIR}/${id}")"
    echo "profile of ${id}: ${status}"
    if [[ "$(jq -r .missing_files <<< "${status}")" != 0 ]]; then
        echo "error: profiled tests of ${id} have no pprof file" >&2
        exit 1
    fi
    if [[ "$(jq -r .pending <<< "${status}")" == 0 ]]; then
        if [[ "$(latest_pull_request "${id}")" != "OPEN true" ]]; then
            echo "the pull request of ${id} is not an open draft"
            return
        fi
        gh pr ready --repo "${GITHUB_REPOSITORY}" "${branch}"
        gh pr comment --repo "${GITHUB_REPOSITORY}" "${branch}" \
            --body "Profiled $(( $(jq .tests <<< "${status}") - $(jq .failures <<< "${status}") )) of $(jq .tests <<< "${status}") tests. $(jq .failures <<< "${status}") tests have a recorded guest failure."
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
}

case "${1:-}" in
    scan)
        (( $# == 1 )) || usage
        scan
        ;;
    run)
        (( $# == 3 )) || usage
        run "$2" "$3"
        ;;
    *)
        usage
        ;;
esac
