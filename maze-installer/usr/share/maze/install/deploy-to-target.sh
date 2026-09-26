#!/usr/bin/env bash
#
# deploy-to-target.sh — Make an installed Maze Linux system match the live ISO.
#
# Called by Calamares (shellprocess_mazedeploy module) with the target
# mountpoint as $1 (e.g. /mnt). It runs in the LIVE environment, so the live
# system's own Maze configuration is the source for everything it copies.
#
# Arguments (shellprocess_mazedeploy.conf passes `${ROOT} 'all' ''`):
#   $1  target mountpoint (required)
#   $2  security-feature CSV; empty or "all" enables every feature
#   $3  ignored (kept for compatibility with older Calamares configs)
#
# THE WORK LIVES IN steps/NN-name.sh, run here in order, in THIS shell (so the
# variables one step sets are there for the next, exactly as when this was one
# 2500-line file — the split was mechanical and verified byte-for-byte).
#
# What this driver adds on top:
#   - every step is announced, timed, and its warnings are counted;
#   - a summary (per-step status + every warning, in one place instead of
#     scattered through a thousand lines of output) is printed at the end and
#     written to /var/log/maze-install-summary.txt on the installed system;
#   - CRITICAL problems — the install will not boot, the disk unlocks without
#     the passphrase, root can log in without a password, a passwordless sudo
#     rule survived — make this script exit non-zero, so Calamares reports the
#     installation as FAILED instead of "done". Everything else stays
#     best-effort: a warning is reported, the install carries on.
#
# Re-running a single step on an already-deployed target (repair, testing):
#   MAZE_DEPLOY_STEPS="70-cmdline-uki 96-verify-boot" deploy-to-target.sh /mnt
# 00-setup and 10-helpers always run first; they only define things.

MAZE_STEP_DIR="${MAZE_STEP_DIR:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/steps}"
if [[ ! -d "${MAZE_STEP_DIR}" ]]; then
    echo "deploy-to-target.sh: step directory ${MAZE_STEP_DIR} is missing" >&2
    exit 1
fi

MAZE_STEP="driver"
MAZE_WARNINGS=()          # every warn(), prefixed with the step it came from
MAZE_CRITICAL=()          # every critical(); any entry fails the install
MAZE_STEP_REPORT=()       # "name|seconds|warnings" per step, for the summary

_steps=()
for _f in "${MAZE_STEP_DIR}"/[0-9][0-9]-*.sh; do
    _n="$(basename "${_f}" .sh)"
    if [[ -n "${MAZE_DEPLOY_STEPS:-}" ]]; then
        case "${_n}" in
            00-setup|10-helpers) ;;
            *) [[ " ${MAZE_DEPLOY_STEPS} " == *" ${_n} "* ]] || continue ;;
        esac
    fi
    _steps+=("${_f}")
done

_total=${#_steps[@]}
_i=0
for _f in "${_steps[@]}"; do
    _i=$((_i + 1))
    MAZE_STEP="$(basename "${_f}" .sh)"
    _w0=${#MAZE_WARNINGS[@]}
    _t0=${SECONDS}
    # log() only exists once 10-helpers has been sourced.
    printf '[maze-deploy] ==== [%02d/%02d] %s ====\n' "${_i}" "${_total}" "${MAZE_STEP}"
    # shellcheck source=/dev/null
    source "${_f}" "$@"
    MAZE_STEP_REPORT+=("${MAZE_STEP}|$((SECONDS - _t0))|$(( ${#MAZE_WARNINGS[@]} - _w0 ))")
done
MAZE_STEP="summary"

# --- summary ------------------------------------------------------------------
_summary() {
    local r n s w
    echo "Maze Linux — installation summary ($(date -Is 2>/dev/null))"
    echo
    printf '  %-26s %6s  %s\n' "step" "time" "warnings"
    for r in "${MAZE_STEP_REPORT[@]}"; do
        IFS='|' read -r n s w <<<"${r}"
        printf '  %-26s %5ss  %s\n' "${n}" "${s}" "$([[ "${w}" -gt 0 ]] && echo "${w}" || echo "-")"
    done
    echo
    if [[ ${#MAZE_CRITICAL[@]} -gt 0 ]]; then
        echo "CRITICAL — this installation is NOT safe to use as it is:"
        printf '  - %s\n' "${MAZE_CRITICAL[@]}"
        echo
    fi
    if [[ ${#MAZE_WARNINGS[@]} -gt 0 ]]; then
        echo "Warnings (${#MAZE_WARNINGS[@]}):"
        printf '  - %s\n' "${MAZE_WARNINGS[@]}"
    else
        echo "No warnings."
    fi
}
_summary_text="$(_summary)"
printf '\n%s\n' "${_summary_text}" | sed 's/^/[maze-deploy] /'
if [[ -n "${TARGET:-}" && -d "${TARGET}/var/log" ]]; then
    printf '%s\n' "${_summary_text}" > "${TARGET}/var/log/maze-install-summary.txt" 2>/dev/null || true
fi

if [[ ${#MAZE_CRITICAL[@]} -gt 0 ]]; then
    echo "[maze-deploy] Installation finished with ${#MAZE_CRITICAL[@]} CRITICAL problem(s) — see above." >&2
    exit 1
fi
exit 0
