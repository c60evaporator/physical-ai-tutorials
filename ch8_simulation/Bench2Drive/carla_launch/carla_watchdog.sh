#!/bin/bash
# =============================================================================
# CARLA Watchdog — automatically restarts crashed CARLA servers.
#
# Runs as a background process on the host.  Every CHECK_INTERVAL seconds it
# checks whether each CARLA server is alive, and restarts any that have died.
#
# Usage:
#   # Start in the background (from the project root):
#   nohup bash carla_launch/carla_watchdog.sh > carla_launch/watchdog.log 2>&1 &
#
#   # Or run in the foreground for debugging:
#   bash carla_launch/carla_watchdog.sh
#
#   # Stop:
#   kill $(cat carla_launch/.watchdog.pid)
# =============================================================================

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Write our PID so the watchdog can be stopped easily
echo $$ > "${SCRIPT_DIR}/.watchdog.pid"

# ── Load environment variables ──
LOCAL_ENV="${SCRIPT_DIR}/.env"
PARENT_ENV="${PARENT_DIR}/.env"
if [ -f "${PARENT_ENV}" ]; then
    set -a; source "${PARENT_ENV}"; set +a
fi
if [ -f "${LOCAL_ENV}" ]; then
    set -a; source "${LOCAL_ENV}"; set +a
fi

# ── Configuration ──
CHECK_INTERVAL="${WATCHDOG_INTERVAL:-60}"     # seconds between checks
EVAL_GPUS="${EVAL_GPUS:-0}"
CARLA_BASE_PORT="${CARLA_BASE_PORT:-30000}"
CARLA_PORT_STEP="${CARLA_PORT_STEP:-150}"

# Resolve CARLA_HOST_PATH
CARLA_HOST_PATH="${CARLA_HOST_PATH:-./carla}"
CARLA_HOST_PATH="${CARLA_HOST_PATH/#\~/$HOME}"
if [[ "${CARLA_HOST_PATH}" != /* ]]; then
    CARLA_HOST_PATH="$(cd "${PARENT_DIR}" && realpath "${CARLA_HOST_PATH}")"
fi
CARLA_SH="${CARLA_HOST_PATH}/CarlaUE4.sh"

# Health-check settings (for launch_one_carla)
CARLA_READY_TIMEOUT="${CARLA_READY_TIMEOUT:-120}"
CARLA_PROBE_INTERVAL="${CARLA_PROBE_INTERVAL:-5}"
CARLA_MAX_RETRIES="${CARLA_MAX_RETRIES:-3}"

PID_DIR="${SCRIPT_DIR}/.carla_pids"

IFS=',' read -ra GPU_LIST <<< "${EVAL_GPUS}"
NUM_GPUS=${#GPU_LIST[@]}

if [ ! -f "${CARLA_SH}" ]; then
    echo "[watchdog] ERROR: CarlaUE4.sh not found at: ${CARLA_SH}" >&2
    exit 1
fi

# ── Helper functions (same as launch_carla_servers_host.sh) ──

find_carla_pid() {
    local port="$1"
    pgrep -f "CarlaUE4-Linux-Shipping.*-carla-rpc-port=${port}\\b" 2>/dev/null | head -1
}

kill_carla_by_port() {
    local port="$1"
    local pids
    pids=$(pgrep -f "CarlaUE4.*-carla-rpc-port=${port}\\b" 2>/dev/null || true)
    if [ -n "${pids}" ]; then
        echo "${pids}" | xargs kill -9 2>/dev/null || true
    fi
}

wait_for_port() {
    local host="$1" port="$2" timeout="$3" interval="$4"
    local elapsed=0
    while (( elapsed < timeout )); do
        local carla_pid
        carla_pid=$(find_carla_pid "${port}")
        if [ -z "${carla_pid}" ] && (( elapsed > 30 )); then
            echo "  [FAIL] No CarlaUE4-Linux-Shipping process found for port ${port} after ${elapsed}s."
            return 1
        fi
        if timeout 2 bash -c "echo > /dev/tcp/${host}/${port}" 2>/dev/null; then
            return 0
        fi
        sleep "${interval}"
        elapsed=$((elapsed + interval))
    done
    echo "  [FAIL] Port ${port} not ready after ${timeout}s."
    return 1
}

launch_one_carla() {
    local i="$1"
    local GPU_ID=${GPU_LIST[$i]}
    local PORT=$((CARLA_BASE_PORT + i * CARLA_PORT_STEP))
    local PROCESS_NAME="carla_gpu${GPU_ID}_port${PORT}"
    local LOG_FILE="${SCRIPT_DIR}/${PROCESS_NAME}.log"

    for (( attempt=1; attempt<=CARLA_MAX_RETRIES; attempt++ )); do
        echo "[watchdog] Launching GPU ${GPU_ID} → port ${PORT} (attempt ${attempt}/${CARLA_MAX_RETRIES})"

        kill_carla_by_port "${PORT}"
        sleep 2

        nohup "${CARLA_SH}" \
            -RenderOffScreen \
            -nosound \
            -carla-rpc-port="${PORT}" \
            -graphicsadapter="${GPU_ID}" \
            > "${LOG_FILE}" 2>&1 &

        local WRAPPER_PID=$!
        sleep 5

        local CARLA_PID
        CARLA_PID=$(find_carla_pid "${PORT}")
        if [ -n "${CARLA_PID}" ]; then
            echo "${CARLA_PID}" > "${PID_DIR}/${PROCESS_NAME}.pid"
        else
            echo "${WRAPPER_PID}" > "${PID_DIR}/${PROCESS_NAME}.pid"
        fi

        echo "[watchdog] Waiting for port ${PORT} (timeout ${CARLA_READY_TIMEOUT}s)..."
        if wait_for_port "localhost" "${PORT}" "${CARLA_READY_TIMEOUT}" "${CARLA_PROBE_INTERVAL}"; then
            CARLA_PID=$(find_carla_pid "${PORT}")
            if [ -n "${CARLA_PID}" ]; then
                echo "${CARLA_PID}" > "${PID_DIR}/${PROCESS_NAME}.pid"
            fi
            echo "[watchdog] ✓ GPU ${GPU_ID} port ${PORT} ready (PID ${CARLA_PID})."
            return 0
        fi

        echo "[watchdog] ✗ GPU ${GPU_ID} port ${PORT} failed (attempt ${attempt})."
        kill_carla_by_port "${PORT}"
        sleep 2
    done

    echo "[watchdog] ERROR: GPU ${GPU_ID} port ${PORT}: all ${CARLA_MAX_RETRIES} attempts failed."
    return 1
}

# ── Main watchdog loop ──
echo "[watchdog] Started (PID $$). Monitoring ${NUM_GPUS} CARLA server(s) every ${CHECK_INTERVAL}s."
echo "[watchdog] GPUs: ${EVAL_GPUS}, Ports: ${CARLA_BASE_PORT}+${CARLA_PORT_STEP}*i"

while true; do
    for (( i=0; i<NUM_GPUS; i++ )); do
        GPU_ID=${GPU_LIST[$i]}
        PORT=$((CARLA_BASE_PORT + i * CARLA_PORT_STEP))

        carla_pid=$(find_carla_pid "${PORT}")
        if [ -z "${carla_pid}" ]; then
            echo "[watchdog] $(date '+%Y-%m-%d %H:%M:%S') GPU ${GPU_ID} port ${PORT} — DEAD, restarting..."
            if launch_one_carla "${i}"; then
                echo "[watchdog] $(date '+%Y-%m-%d %H:%M:%S') GPU ${GPU_ID} port ${PORT} — restarted successfully."
            else
                echo "[watchdog] $(date '+%Y-%m-%d %H:%M:%S') GPU ${GPU_ID} port ${PORT} — RESTART FAILED."
            fi
        fi
    done

    sleep "${CHECK_INTERVAL}"
done
