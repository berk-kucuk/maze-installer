#!/usr/bin/env bash
#
# deploy-to-target.sh — Make an installed Maze Linux system match the live ISO.
#
# It runs in the LIVE environment, so the live system's own Maze configuration
# is the source for everything it copies, and arch-chroots into the target.
#
#   deploy-to-target.sh TARGET [security-csv] [ignored]
#       Run every step, then the summary. (Manual runs, repair, the tests.)
#
#   deploy-to-target.sh --list
#       The steps, one per line: name TAB timeout TAB weight TAB title TAB title.tr
#   deploy-to-target.sh --begin TARGET [security-csv]
#       Start a run: check the target, clear the state of any earlier run.
#   deploy-to-target.sh --step NAME TARGET [security-csv]
#       Run one step.
#   deploy-to-target.sh --summary TARGET
#       Print and write the summary; exit 1 if the install is not safe to use.
#
#   Calamares' mazedeploy job module makes exactly those calls, so the progress
#   bar names the step that is running and the debug log shows its output.
#
#   security-csv: empty or "all" enables every security feature (85-services).
#
# THE WORK LIVES IN steps/NN-name.sh. Two kinds:
#   - "# @library" files (00-setup, 10-helpers, *-functions) only define what
#     the steps share. They are sourced at the start of every step.
#   - every other file is a step. Each one runs in a FRESH bash process, under
#     its own timeout (# @timeout), with its output in its own log. A step that
#     crashes, hangs or is killed is recorded as failed and the next step still
#     runs; it no longer takes the rest of the install down with it, and it can
#     no longer leave a half-set variable behind for the next step to trip on.
#     The few values a later step needs are named in the step's "# @exports"
#     line and handed on through state.sh — nothing else crosses from one step
#     to the next.
#
# On top of that the driver:
#   - announces and times every step and counts its warnings;
#   - writes everything to /var/log/maze-installer/ on the installed system:
#       steps/NN-name.log  full output of each step
#       steps.tsv          name, result, seconds, warnings
#       warnings.txt       every warning, prefixed with its step
#       critical.txt       every critical problem
#       summary.txt        the summary (also /var/log/maze-install-summary.txt)
#   - FAILS the install (exit 1 from --summary, and so from the full run) when
#     a step reported a CRITICAL problem — the install will not boot, the disk
#     unlocks without the passphrase, root can log in without a password, a
#     passwordless sudo rule survived — or did not finish. Everything else is
#     best-effort: a warning is reported, the install carries on.
#
# Re-running chosen steps on an already-deployed target (repair, testing):
#   MAZE_DEPLOY_STEPS="70-cmdline-uki 96-verify-boot" deploy-to-target.sh /mnt
# The @library files are always loaded.

set -uo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
export MAZE_STEP_DIR="${MAZE_STEP_DIR:-$(dirname "${SELF}")/steps}"

# --- step files ---------------------------------------------------------------
# Header metadata: "# @key value" in the first lines of a step file.
_meta() {
    sed -n -E "1,15{s/^# @${2//./\\.}[[:space:]]+//p}" "$1" 2>/dev/null | head -n1
}
_is_library() { head -n 15 "$1" 2>/dev/null | grep -q '^# @library'; }

_library_files() {
    local f
    for f in "${MAZE_STEP_DIR}"/[0-9][0-9]-*.sh; do
        [[ -f "${f}" ]] && _is_library "${f}" && printf '%s\n' "${f}"
    done
}
_step_files() {
    local f n
    for f in "${MAZE_STEP_DIR}"/[0-9][0-9]-*.sh; do
        [[ -f "${f}" ]] || continue
        _is_library "${f}" && continue
        n="$(basename "${f}" .sh)"
        if [[ -n "${MAZE_DEPLOY_STEPS:-}" && " ${MAZE_DEPLOY_STEPS} " != *" ${n} "* ]]; then
            continue
        fi
        printf '%s\n' "${f}"
    done
}

# --- target and state -----------------------------------------------------------
# Everything below reads, writes and DELETES under the target. Calamares runs
# this un-chrooted, so an empty or "/" target would aim it at the LIVE system.
_check_target() {
    local t="${1:-}"
    t="${t%/}"
    if [[ -z "${1:-}" ]]; then
        echo "deploy-to-target.sh: no target given (usage: deploy-to-target.sh <target-mountpoint> [security-csv])" >&2
        return 1
    fi
    if [[ -z "${t}" ]]; then
        echo "deploy-to-target.sh: refusing to operate on '/' — that is the live system, not the install target." >&2
        return 1
    fi
    if [[ ! -d "${t}" ]]; then
        echo "deploy-to-target.sh: target '${t}' is not a directory." >&2
        return 1
    fi
}

_state_init() {
    TARGET="${1%/}"
    export MAZE_STATE_DIR="${MAZE_STATE_DIR:-${TARGET}/var/log/maze-installer}"
    ST_VARS="${MAZE_STATE_DIR}/state.sh"
    ST_WARN="${MAZE_STATE_DIR}/warnings.txt"
    ST_CRIT="${MAZE_STATE_DIR}/critical.txt"
    ST_STEPS="${MAZE_STATE_DIR}/steps.tsv"
    ST_LOGS="${MAZE_STATE_DIR}/steps"
}

_count() { [[ -s "$1" ]] && wc -l < "$1" || echo 0; }

# --- one step, in its own process ----------------------------------------------
# --exec NAME TARGET [args]: the child. Kept at the TOP LEVEL of the script (not
# in a function) so that what the libraries, state.sh and the step declare is
# global, exactly as when every step was sourced into one shell.
if [[ "${1:-}" == "--exec" ]]; then
    MAZE_STEP="$2"
    shift 2
    _state_init "$1"
    MAZE_WARNINGS=()
    MAZE_CRITICAL=()
    # The preflight is the libraries' own run: their warnings (BIOS firmware)
    # count once, there. For a step they are reloaded quietly.
    if [[ "${MAZE_STEP}" == "preflight" ]]; then
        MAZE_WARN_FILE="${ST_WARN}"
        MAZE_CRITICAL_FILE="${ST_CRIT}"
    fi
    while IFS= read -r _lib; do
        if [[ "${MAZE_STEP}" == "preflight" ]]; then
            # shellcheck source=/dev/null
            source "${_lib}" "$@"
        else
            # shellcheck source=/dev/null
            source "${_lib}" "$@" >/dev/null
        fi
    done < <(_library_files)
    [[ "${MAZE_STEP}" == "preflight" ]] && exit 0

    MAZE_WARNINGS=()
    MAZE_CRITICAL=()
    MAZE_WARN_FILE="${ST_WARN}"
    MAZE_CRITICAL_FILE="${ST_CRIT}"
    # shellcheck source=/dev/null
    [[ -f "${ST_VARS}" ]] && source "${ST_VARS}"

    # shellcheck source=/dev/null
    source "${MAZE_STEP_DIR}/${MAZE_STEP}.sh" "$@"

    # Hand on what this step declared it exports; nothing else survives it.
    for _v in $(_meta "${MAZE_STEP_DIR}/${MAZE_STEP}.sh" exports); do
        declare -p "${_v}" >> "${ST_VARS}" 2>/dev/null \
            || printf '[maze-deploy] note: %s exports %s but never set it\n' "${MAZE_STEP}" "${_v}" >&2
    done
    exit 0
fi

# --- driver ---------------------------------------------------------------------
_begin() {
    _check_target "${1:-}" || return 1
    _state_init "$1"
    mkdir -p "${ST_LOGS}" || { echo "deploy-to-target.sh: cannot create ${ST_LOGS}" >&2; return 1; }
    chmod 700 "${MAZE_STATE_DIR}" 2>/dev/null || true
    rm -f "${ST_WARN}" "${ST_CRIT}" "${ST_STEPS}" "${MAZE_STATE_DIR}/summary.txt" 2>/dev/null
    if [[ -z "${MAZE_DEPLOY_STEPS:-}" ]]; then
        # A full run starts from nothing.
        rm -f "${ST_VARS}" "${ST_LOGS}"/*.log 2>/dev/null
        : > "${ST_VARS}"
    else
        # A repair run (chosen steps only) keeps what the earlier full run
        # handed on in state.sh — re-running 70-cmdline-uki alone needs the
        # values 60 and 65 exported — and the other steps' logs. The re-run
        # steps append to their own log.
        [[ -f "${ST_VARS}" ]] || : > "${ST_VARS}"
        echo "deploy-to-target.sh: repair run of: ${MAZE_DEPLOY_STEPS}" >&2
    fi
    : > "${ST_WARN}"; : > "${ST_CRIT}"; : > "${ST_STEPS}"
    chmod 600 "${ST_VARS}" 2>/dev/null || true

    local t0=${SECONDS} rc
    bash "${SELF}" --exec preflight "$@" 2>&1 | tee -a "${ST_LOGS}/preflight.log"
    rc=${PIPESTATUS[0]}
    if [[ ${rc} -ne 0 ]]; then
        echo "deploy-to-target.sh: preflight failed (exit ${rc}) — nothing was changed by the steps" >&2
        return "${rc}"
    fi
    printf 'preflight\tok\t%s\t%s\n' "$((SECONDS - t0))" "$(_count "${ST_WARN}")" >> "${ST_STEPS}"
}

# A step stopped by its timeout may have been killed in the middle of a pacman
# transaction, leaving pacman's lock behind: every later pacman call — the
# remaining steps, and the user's first update — would fail with "unable to
# lock database". Remove it, but only when no pacman is still running inside
# the target (timeout(1) killed the step's whole process group, so normally
# none is).
_clear_stale_pacman_lock() {
    local lck="${TARGET}/var/lib/pacman/db.lck" pid
    [[ -e "${lck}" ]] || return 0
    for pid in $(pgrep -x pacman 2>/dev/null); do
        if [[ "$(readlink -f "/proc/${pid}/root" 2>/dev/null)" == "$(readlink -f "${TARGET}")" ]]; then
            printf '[%s] pacman is still running in the target (pid %s); its lock was left in place\n' \
                "$1" "${pid}" >> "${ST_WARN}"
            return 0
        fi
    done
    rm -f "${lck}" \
        && printf '[%s] removed the pacman lock the stopped step left behind\n' "$1" >> "${ST_WARN}"
}

# _run_step NAME TARGET [args]
# Prints one machine-readable line at the end for the Calamares module:
#   @@maze-step NAME RESULT SECONDS WARNINGS
# RESULT: ok | warnings | critical | failed | timeout
_run_step() {
    local name="$1"; shift
    local f="${MAZE_STEP_DIR}/${name}.sh"
    _state_init "$1"
    if [[ ! -f "${f}" ]] || _is_library "${f}"; then
        echo "deploy-to-target.sh: no step named '${name}'" >&2
        return 2
    fi
    local timeout title log t0 rc dt w0 c0 w c result
    timeout="$(_meta "${f}" timeout)"
    [[ "${timeout}" =~ ^[0-9]+$ ]] || timeout=1800
    title="$(_meta "${f}" title)"
    log="${ST_LOGS}/${name}.log"
    mkdir -p "${ST_LOGS}" 2>/dev/null || true
    w0=$(_count "${ST_WARN}")
    c0=$(_count "${ST_CRIT}")

    printf '[maze-deploy] ==== %s%s ====\n' "${name}" "${title:+ — ${title}}"
    t0=${SECONDS}
    # timeout(1) signals the whole process group, so a hung pacman or makepkg
    # under arch-chroot goes too. --kill-after: a step that ignores TERM.
    timeout --kill-after=60 "${timeout}" bash "${SELF}" --exec "${name}" "$@" 2>&1 \
        | tee -a "${log}"
    rc=${PIPESTATUS[0]}
    dt=$((SECONDS - t0))

    case "${rc}" in
        0) ;;
        124|137)
            printf '[%s] did not finish within %ss and was stopped — see %s\n' \
                "${name}" "${timeout}" "${log#"${TARGET}"}" >> "${ST_CRIT}"
            _clear_stale_pacman_lock "${name}" ;;
        *)
            printf '[%s] stopped with an error (exit %s) before it finished — see %s\n' \
                "${name}" "${rc}" "${log#"${TARGET}"}" >> "${ST_CRIT}" ;;
    esac
    w=$(( $(_count "${ST_WARN}") - w0 ))
    c=$(( $(_count "${ST_CRIT}") - c0 ))
    if   [[ ${rc} -eq 124 || ${rc} -eq 137 ]]; then result=timeout
    elif [[ ${rc} -ne 0 ]];                   then result=failed
    elif [[ ${c} -gt 0 ]];                    then result=critical
    elif [[ ${w} -gt 0 ]];                    then result=warnings
    else                                           result=ok
    fi
    printf '%s\t%s\t%s\t%s\n' "${name}" "${result}" "${dt}" "${w}" >> "${ST_STEPS}"
    printf '[maze-deploy] ---- %s: %s (%ss, %s warning(s)) ----\n' "${name}" "${result}" "${dt}" "${w}"
    printf '@@maze-step %s %s %s %s\n' "${name}" "${result}" "${dt}" "${w}"
    [[ "${result}" == ok || "${result}" == warnings ]]
}

_summary_text() {
    local n r s w nw nc
    echo "Maze Linux — installation summary ($(date -Is 2>/dev/null))"
    echo
    printf '  %-26s %6s  %-8s  %s\n' "step" "time" "warnings" "result"
    while IFS=$'\t' read -r n r s w; do
        [[ -n "${n}" ]] || continue
        printf '  %-26s %5ss  %-8s  %s\n' "${n}" "${s}" "$([[ "${w}" -gt 0 ]] && echo "${w}" || echo "-")" "${r}"
    done < "${ST_STEPS}"
    echo
    nc=$(_count "${ST_CRIT}")
    nw=$(_count "${ST_WARN}")
    if [[ ${nc} -gt 0 ]]; then
        echo "CRITICAL — this installation is NOT safe to use as it is:"
        sed 's/^/  - /' "${ST_CRIT}"
        echo
    fi
    if [[ ${nw} -gt 0 ]]; then
        echo "Warnings (${nw}):"
        sed 's/^/  - /' "${ST_WARN}"
    else
        echo "No warnings."
    fi
    echo
    echo "Full log of every step: ${ST_LOGS#"${TARGET}"}/"
}

_summary() {
    _check_target "${1:-}" || return 1
    _state_init "$1"
    [[ -f "${ST_STEPS}" ]] || { echo "deploy-to-target.sh: no run recorded under ${MAZE_STATE_DIR} (--begin first)" >&2; return 1; }
    local text
    text="$(_summary_text)"
    printf '\n%s\n' "${text}" | sed 's/^/[maze-deploy] /'
    printf '%s\n' "${text}" > "${MAZE_STATE_DIR}/summary.txt" 2>/dev/null || true
    if [[ -d "${TARGET}/var/log" ]]; then
        printf '%s\n' "${text}" > "${TARGET}/var/log/maze-install-summary.txt" 2>/dev/null || true
    fi
    local nc
    nc=$(_count "${ST_CRIT}")
    if [[ ${nc} -gt 0 ]]; then
        echo "[maze-deploy] Installation finished with ${nc} CRITICAL problem(s) — see above." >&2
        return 1
    fi
    return 0
}

_list() {
    local f
    while IFS= read -r f; do
        printf '%s\t%s\t%s\t%s\t%s\n' "$(basename "${f}" .sh)" \
            "$(_meta "${f}" timeout)" "$(_meta "${f}" weight)" \
            "$(_meta "${f}" title)" "$(_meta "${f}" title.tr)"
    done < <(_step_files)
}

if [[ ! -d "${MAZE_STEP_DIR}" ]]; then
    echo "deploy-to-target.sh: step directory ${MAZE_STEP_DIR} is missing" >&2
    exit 1
fi

case "${1:-}" in
    --list)    _list ;;
    --begin)   shift; _begin "$@" ;;
    --step)    shift; [[ $# -ge 2 ]] || { echo "usage: deploy-to-target.sh --step NAME TARGET [security-csv]" >&2; exit 2; }
               _run_step "$@" ;;
    --summary) shift; _summary "$@" ;;
    -h|--help) sed -n '2,/^$/p' "${SELF}" | sed 's/^# \{0,1\}//' ;;
    -*)        echo "deploy-to-target.sh: unknown option '$1'" >&2; exit 2 ;;
    *)
        _begin "$@" || exit 1
        # stdin from /dev/null: the step list is this loop's stdin, and a step
        # that reads stdin must not swallow the rest of it.
        while IFS= read -r _f; do
            _run_step "$(basename "${_f}" .sh)" "$@" < /dev/null || true
        done < <(_step_files)
        _summary "$1"
        ;;
esac
