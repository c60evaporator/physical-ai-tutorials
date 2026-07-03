#!/usr/bin/env bash
# =============================================================================
# launch_carla_servers.sh — Launch and manage CARLA host servers.
#
# Reads EVAL_GPUS, CARLA_HOST_PATH, and port settings from ../.env
# (scripts/CarlaGarage/.env).  Automatically starts a watchdog that detects
# and restarts crashed servers.
#
# Port rule (shared with evaluate_b2d_multi.sh):
#   CARLA RPC port = CARLA_BASE_PORT + index × CARLA_PORT_STEP
#   where index is the 0-based position in the EVAL_GPUS comma-separated list.
#   e.g. EVAL_GPUS=0,1  BASE_PORT=2000  STEP=150
#        GPU 0 → port 2000,  GPU 1 → port 2150
#
# Usage:
#   bash launch_carla_servers.sh [start]   # Launch servers + watchdog (default)
#   bash launch_carla_servers.sh stop      # Stop servers + watchdog
#   bash launch_carla_servers.sh status    # Show running servers + watchdog state
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/carla_launch/_carla_lib.sh"

WATCHDOG_SCRIPT="${SCRIPT_DIR}/carla_launch/_carla_watchdog.sh"
WATCHDOG_PID_FILE="${SCRIPT_DIR}/carla_launch/.watchdog.pid"
WATCHDOG_LOG="${LOG_DIR}/watchdog.log"

case "${1:-start}" in

# ── Start ─────────────────────────────────────────────────────────────────────
start)
    if [[ ! -f "${CARLA_SH}" ]]; then
        echo "[ERROR] CarlaUE4.sh not found: ${CARLA_SH}" >&2
        echo "        Set CARLA_HOST_PATH to an absolute path in .env." >&2
        exit 1
    fi
    mkdir -p "${PID_DIR}" "${LOG_DIR}"

    echo "========================================================"
    echo " Launching ${NUM_GPUS} CARLA server(s)"
    echo "   CARLA : ${CARLA_HOST_PATH}"
    echo "   GPUs  : ${EVAL_GPUS}"
    echo "   Ports : ${CARLA_BASE_PORT} + i × ${CARLA_PORT_STEP}"
    echo "   Logs  : ${LOG_DIR}/"
    echo "========================================================"

    failed_gpus=()
    for (( i=0; i<NUM_GPUS; i++ )); do
        launch_one "${i}" || failed_gpus+=("${GPU_LIST[$i]}")
    done
    echo ""

    if [[ ${#failed_gpus[@]} -gt 0 ]]; then
        echo "[WARN] Failed to start GPU(s): ${failed_gpus[*]}" >&2
    fi

    echo "Starting watchdog (interval: ${WATCHDOG_INTERVAL}s)..."
    nohup bash "${WATCHDOG_SCRIPT}" >> "${WATCHDOG_LOG}" 2>&1 &
    # Watchdog writes its own PID to .watchdog.pid after sourcing the lib.
    sleep 1
    if [[ -f "${WATCHDOG_PID_FILE}" ]]; then
        echo "[OK] Watchdog running (PID $(cat "${WATCHDOG_PID_FILE}"))."
    else
        echo "[WARN] Watchdog PID file not yet written — may still be starting."
    fi
    echo "      Log: ${WATCHDOG_LOG}"
    echo ""
    echo "To stop:  bash $(basename "$0") stop"
    echo "To check: bash $(basename "$0") status"
    ;;

# ── Stop ──────────────────────────────────────────────────────────────────────
stop)
    echo "Stopping watchdog..."
    if [[ -f "${WATCHDOG_PID_FILE}" ]]; then
        wpid=$(cat "${WATCHDOG_PID_FILE}")
        if kill "${wpid}" 2>/dev/null; then
            echo "  Watchdog (PID ${wpid}) killed."
        else
            echo "  Watchdog PID ${wpid} already dead."
        fi
        rm -f "${WATCHDOG_PID_FILE}"
    else
        echo "  No watchdog PID file found."
    fi

    echo "Stopping CARLA servers..."
    for (( i=0; i<NUM_GPUS; i++ )); do
        gpu="${GPU_LIST[$i]}"
        port=$(( CARLA_BASE_PORT + i * CARLA_PORT_STEP ))
        echo "  GPU ${gpu} port ${port}..."
        kill_by_port "${port}"
    done
    rm -rf "${PID_DIR}"
    echo "Done."
    ;;

# ── Status ────────────────────────────────────────────────────────────────────
status)
    echo "CARLA servers:"
    for (( i=0; i<NUM_GPUS; i++ )); do
        gpu="${GPU_LIST[$i]}"
        port=$(( CARLA_BASE_PORT + i * CARLA_PORT_STEP ))
        pid=$(find_pid "${port}")
        if [[ -n "${pid}" ]]; then
            echo "  ✓ GPU ${gpu}  port ${port}  (PID ${pid})"
        else
            echo "  ✗ GPU ${gpu}  port ${port}  — stopped"
        fi
    done
    echo "Watchdog:"
    if [[ -f "${WATCHDOG_PID_FILE}" ]]; then
        wpid=$(cat "${WATCHDOG_PID_FILE}")
        if kill -0 "${wpid}" 2>/dev/null; then
            echo "  ✓ Running (PID ${wpid})"
        else
            echo "  ✗ Dead (stale PID file: ${WATCHDOG_PID_FILE})"
        fi
    else
        echo "  ✗ Not running (no PID file)"
    fi
    ;;

*)
    echo "Usage: $0 [start|stop|status]" >&2
    exit 1
    ;;
esac
