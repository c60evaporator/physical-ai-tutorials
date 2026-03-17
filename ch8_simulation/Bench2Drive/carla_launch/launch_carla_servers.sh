#!/bin/bash
# =============================================================================
# Launch / stop multiple CARLA servers directly on the host (no Docker).
#
# Reads EVAL_GPUS, CARLA_HOST_PATH, and port settings from ../.env.
# Each CARLA server runs on a dedicated GPU with a unique RPC port.
#
# Port rule (shared with run_evaluation_multi_uniad.sh):
#   CARLA RPC port = CARLA_BASE_PORT + index * CARLA_PORT_STEP
#   where "index" is the 0-based position in the EVAL_GPUS list.
#   e.g. EVAL_GPUS=0,2,5, BASE_PORT=30000, STEP=150
#        GPU 0 → port 30000, GPU 2 → port 30150, GPU 5 → port 30300
#
# Usage (from scripts/Bench2Drive/):
#   bash carla_launch/launch_carla_servers_host.sh            # Start servers
#   bash carla_launch/launch_carla_servers_host.sh stop       # Stop all servers
#   bash carla_launch/launch_carla_servers_host.sh status     # Show running servers
# =============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"  # scripts/Bench2Drive/
LOCAL_ENV="${SCRIPT_DIR}/.env"
PARENT_ENV="${PARENT_DIR}/.env"

# ── Load environment variables ──
if [ -f "${PARENT_ENV}" ]; then
    set -a; source "${PARENT_ENV}"; set +a
fi
if [ -f "${LOCAL_ENV}" ]; then
    set -a; source "${LOCAL_ENV}"; set +a
fi

# ── Configuration ──
EVAL_GPUS="${EVAL_GPUS:-0}"
CARLA_BASE_PORT="${CARLA_BASE_PORT:-30000}"
CARLA_PORT_STEP="${CARLA_PORT_STEP:-150}"

# Resolve CARLA_HOST_PATH (expand ~ and relative paths)
CARLA_HOST_PATH="${CARLA_HOST_PATH:-./carla}"
CARLA_HOST_PATH="${CARLA_HOST_PATH/#\~/$HOME}"
# Relative paths are resolved from PARENT_DIR (scripts/Bench2Drive/)
if [[ "${CARLA_HOST_PATH}" != /* ]]; then
    CARLA_HOST_PATH="$(cd "${PARENT_DIR}" && realpath "${CARLA_HOST_PATH}")"
fi

CARLA_SH="${CARLA_HOST_PATH}/CarlaUE4.sh"
PID_DIR="${SCRIPT_DIR}/.carla_pids"

# Parse GPU list
IFS=',' read -ra GPU_LIST <<< "${EVAL_GPUS}"
NUM_GPUS=${#GPU_LIST[@]}

# ── Validate CARLA installation ──
validate_carla() {
    if [ ! -f "${CARLA_SH}" ]; then
        echo "[ERROR] CarlaUE4.sh not found at: ${CARLA_SH}" >&2
        echo "        Set CARLA_HOST_PATH in .env to your CARLA installation directory." >&2
        exit 1
    fi
}

# ── Stop mode ──
if [ "${1:-}" = "stop" ]; then
    echo "Stopping all CARLA host processes..."
    if [ -d "${PID_DIR}" ]; then
        for pidfile in "${PID_DIR}"/*.pid; do
            [ -f "${pidfile}" ] || continue
            pgid=$(cat "${pidfile}")
            name=$(basename "${pidfile}" .pid)
            # Kill the entire process group (shell wrapper + CarlaUE4-Linux-Shipping)
            if kill -0 -"${pgid}" 2>/dev/null; then
                echo "  Stopping ${name} (PGID ${pgid})..."
                kill -- -"${pgid}" 2>/dev/null || true
                # Wait up to 10s for graceful shutdown
                for _ in $(seq 1 10); do
                    kill -0 -"${pgid}" 2>/dev/null || break
                    sleep 1
                done
                # Force kill if still alive
                if kill -0 -"${pgid}" 2>/dev/null; then
                    echo "  Force killing ${name} (PGID ${pgid})..."
                    kill -9 -- -"${pgid}" 2>/dev/null || true
                fi
            else
                echo "  ${name} (PGID ${pgid}) already stopped."
            fi
            rm -f "${pidfile}"
        done
        rmdir "${PID_DIR}" 2>/dev/null || true
    else
        echo "  No PID directory found. Nothing to stop."
    fi
    echo "Done."
    exit 0
fi

# ── Status mode ──
if [ "${1:-}" = "status" ]; then
    echo "CARLA host processes:"
    if [ -d "${PID_DIR}" ]; then
        found=false
        for pidfile in "${PID_DIR}"/*.pid; do
            [ -f "${pidfile}" ] || continue
            found=true
            pgid=$(cat "${pidfile}")
            name=$(basename "${pidfile}" .pid)
            if kill -0 -"${pgid}" 2>/dev/null; then
                echo "  ✓ ${name} (PGID ${pgid}) — running"
            else
                echo "  ✗ ${name} (PGID ${pgid}) — stopped"
            fi
        done
        if [ "${found}" = false ]; then
            echo "  No CARLA processes tracked."
        fi
    else
        echo "  No PID directory found."
    fi
    exit 0
fi

# ── Launch mode ──
validate_carla
mkdir -p "${PID_DIR}"

echo "============================================================"
echo " Launching ${NUM_GPUS} CARLA server(s) on host"
echo " CARLA path      : ${CARLA_HOST_PATH}"
echo " GPU list        : ${EVAL_GPUS}"
echo " Base port       : ${CARLA_BASE_PORT}"
echo " Port step       : ${CARLA_PORT_STEP}"
echo "============================================================"

for (( i=0; i<NUM_GPUS; i++ )); do
    GPU_ID=${GPU_LIST[$i]}
    PORT=$((CARLA_BASE_PORT + i * CARLA_PORT_STEP))
    PROCESS_NAME="carla_gpu${GPU_ID}_port${PORT}"
    LOG_FILE="${SCRIPT_DIR}/${PROCESS_NAME}.log"

    echo -e "\033[32m[${i}/${NUM_GPUS}] GPU ${GPU_ID} → port ${PORT}\033[0m"

    # Launch CARLA with dedicated GPU via -graphicsadapter=GPU_ID.
    # setsid creates a new process group so we can kill the entire group later.
    setsid nohup "${CARLA_SH}" \
        -RenderOffScreen \
        -nosound \
        -carla-rpc-port="${PORT}" \
        -graphicsadapter="${GPU_ID}" \
        > "${LOG_FILE}" 2>&1 &

    CARLA_PID=$!
    # Store the PGID (= PID of the setsid leader) for group-kill on stop
    echo "${CARLA_PID}" > "${PID_DIR}/${PROCESS_NAME}.pid"
    echo "  PGID: ${CARLA_PID}, Log: ${LOG_FILE}"

    sleep 2
done

echo ""
echo "============================================================"
echo " All CARLA servers launched. Waiting 30s for initialization..."
echo "============================================================"
sleep 30

echo ""
echo "CARLA servers ready. Port mapping:"
for (( i=0; i<NUM_GPUS; i++ )); do
    GPU_ID=${GPU_LIST[$i]}
    PORT=$((CARLA_BASE_PORT + i * CARLA_PORT_STEP))
    PROCESS_NAME="carla_gpu${GPU_ID}_port${PORT}"
    PGID=$(cat "${PID_DIR}/${PROCESS_NAME}.pid" 2>/dev/null || echo "?")
    if kill -0 -"${PGID}" 2>/dev/null; then
        STATUS="running"
    else
        STATUS="FAILED (check ${SCRIPT_DIR}/${PROCESS_NAME}.log)"
    fi
    echo "  [${i}] GPU ${GPU_ID} → localhost:${PORT}  (PGID ${PGID}, ${STATUS})"
done
echo ""
echo "To stop:   bash $(basename "$0") stop"
echo "To status: bash $(basename "$0") status"
