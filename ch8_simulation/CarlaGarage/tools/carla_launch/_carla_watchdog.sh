#!/usr/bin/env bash
# =============================================================================
# _carla_watchdog.sh — CARLA server watchdog.
#
# Monitors all configured CARLA servers and automatically restarts any that
# have crashed.  Launched by launch_carla_servers.sh; do NOT run directly.
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
    sleep "${WATCHDOG_INTERVAL}"
done
