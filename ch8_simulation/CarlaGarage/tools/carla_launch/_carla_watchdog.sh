#!/usr/bin/env bash
# =============================================================================
# _carla_watchdog.sh — CARLA server watchdog.
#
# Monitors all configured CARLA servers and automatically restarts any that
# have crashed.  Launched by launch_carla_servers.sh; do NOT run directly.
#
# Restart requests (sentinel files):
#   A client (e.g. collect_dataset_multi.sh inside the container, via the
#   shared ./tools bind mount) can force-restart a *still-running* CARLA —
#   e.g. one contaminated by a crashed evaluator attempt (leftover ego,
#   sensors, TrafficManager) — by touching
#       tools/carla_launch/.restart_request_<port>
#   The watchdog kills and relaunches that server, then REMOVES the file once
#   the new instance accepts connections; the requester waits for the file to
#   disappear. Requests are polled every 5 s (health checks stay on
#   WATCHDOG_INTERVAL).
#
# To stop: kill $(cat tools/carla_launch/.watchdog.pid)
#          or: bash launch_carla_servers.sh stop
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_carla_lib.sh"

# Record own PID so launch_carla_servers.sh stop can kill us cleanly.
# Written AFTER sourcing the lib to ensure the lib's echo output does not
# race with the PID file write.
echo $$ > "${SCRIPT_DIR}/.watchdog.pid"

echo "[watchdog] Started (PID $$). Monitoring ${NUM_GPUS} server(s) every ${WATCHDOG_INTERVAL}s."
echo "[watchdog] GPUs: ${EVAL_GPUS} | Base port: ${CARLA_BASE_PORT} | Step: ${CARLA_PORT_STEP}"

# Drop stale restart requests from previous sessions so they cannot kill a
# healthy server long after the requester has given up waiting.
rm -f "${SCRIPT_DIR}"/.restart_request_* 2>/dev/null || true

# handle_restart_requests
#   Serves .restart_request_<port> sentinel files: force-restarts the matching
#   server (launch_one kills the old instance first) and removes the sentinel
#   once the new instance is ready. On failure the sentinel is kept so the
#   next poll retries.
handle_restart_requests() {
    for (( i=0; i<NUM_GPUS; i++ )); do
        gpu="${GPU_LIST[$i]}"
        port=$(( CARLA_BASE_PORT + i * CARLA_PORT_STEP ))
        request="${SCRIPT_DIR}/.restart_request_${port}"
        if [[ -f "${request}" ]]; then
            echo "[watchdog] $(date '+%Y-%m-%d %H:%M:%S') GPU ${gpu} port ${port} — restart requested, relaunching..."
            if launch_one "${i}"; then
                rm -f "${request}"
                echo "[watchdog] $(date '+%Y-%m-%d %H:%M:%S') GPU ${gpu} port ${port} — restarted OK (request cleared)."
            else
                echo "[watchdog] $(date '+%Y-%m-%d %H:%M:%S') GPU ${gpu} port ${port} — RESTART FAILED (request kept)."
            fi
        fi
    done
}

while true; do
    for (( i=0; i<NUM_GPUS; i++ )); do
        gpu="${GPU_LIST[$i]}"
        port=$(( CARLA_BASE_PORT + i * CARLA_PORT_STEP ))
        pid=$(find_pid "${port}")
        if [[ -z "${pid}" ]]; then
            echo "[watchdog] $(date '+%Y-%m-%d %H:%M:%S') GPU ${gpu} port ${port} — DEAD, restarting..."
            if launch_one "${i}"; then
                echo "[watchdog] $(date '+%Y-%m-%d %H:%M:%S') GPU ${gpu} port ${port} — restarted OK."
            else
                echo "[watchdog] $(date '+%Y-%m-%d %H:%M:%S') GPU ${gpu} port ${port} — RESTART FAILED."
            fi
        fi
    done

    # Poll restart requests every 5 s between health checks.
    poll_slices=$(( WATCHDOG_INTERVAL / 5 ))
    for (( s=0; s<poll_slices; s++ )); do
        handle_restart_requests
        sleep 5
    done
done
