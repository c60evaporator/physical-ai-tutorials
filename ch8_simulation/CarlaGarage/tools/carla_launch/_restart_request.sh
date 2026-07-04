#!/usr/bin/env bash
# =============================================================================
# _restart_request.sh — Client-side helper to request a CARLA restart.
#
# SOURCE this file; do NOT execute it directly. Used by the container-side
# runner scripts (collect_dataset_multi.sh, evaluate_leaderboard_multi.sh,
# evaluate_b2d_multi.sh) before retrying after a failed attempt.
#
# Rationale: a crashed evaluator attempt leaves its ego vehicle, sensors and
# TrafficManager inside the still-running CARLA server, which poisons
# subsequent attempts (TM port bind errors, ego spawn collisions, async world
# settings) and, for evaluations, silently distorts the scores of the
# remaining routes. Requesting a fresh instance before every retry avoids
# reusing a contaminated server.
#
# Protocol (shared ./tools bind mount):
#   1. touch tools/carla_launch/.restart_request_<port>
#   2. The host-side watchdog (_carla_watchdog.sh) polls these sentinels every
#      5 s, force-restarts the matching server and REMOVES the file once the
#      new instance accepts connections.
#   3. This helper waits for the file to disappear (up to CARLA_WAIT_TIMEOUT
#      seconds). On timeout the request is withdrawn so a late watchdog pickup
#      cannot kill CARLA in the middle of the next attempt, and the caller
#      falls back to reusing the existing instance (previous behaviour).
# =============================================================================

# request_carla_restart PORT [LOG_PREFIX]
#   Returns 0 if the watchdog restarted CARLA, 1 on fallback (no watchdog,
#   timeout or unwritable sentinel). Callers do not need to branch on the
#   return value: the following port-open check handles both outcomes.
request_carla_restart() {
    local port="$1"
    local log_prefix="${2:-[carla-restart]}"
    local sentinel_dir
    sentinel_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local request="${sentinel_dir}/.restart_request_${port}"
    local wait_timeout="${CARLA_WAIT_TIMEOUT:-1800}"
    local wait_loops=$(( wait_timeout / 5 ))
    local w

    if ! touch "${request}" 2>/dev/null; then
        echo "${log_prefix} Could not write ${request} (permissions?). Skipping restart request..."
        return 1
    fi

    echo "${log_prefix} Requested CARLA restart on port ${port}; waiting up to ${wait_timeout}s..."
    for (( w=0; w<wait_loops; w++ )); do
        if [[ ! -f "${request}" ]]; then
            echo "${log_prefix} CARLA on port ${port} was restarted by the watchdog."
            return 0
        fi
        sleep 5
    done

    rm -f "${request}"
    echo "${log_prefix} Restart request not handled within ${wait_timeout}s" \
         "(is launch_carla_servers.sh running on the host?). Reusing the existing instance..."
    return 1
}
