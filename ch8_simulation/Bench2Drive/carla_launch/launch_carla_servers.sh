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

# ── Health-check settings ──
# Maximum time (seconds) to wait for each CARLA server's RPC port to open.
CARLA_READY_TIMEOUT="${CARLA_READY_TIMEOUT:-120}"
# Seconds between readiness probes.
CARLA_PROBE_INTERVAL="${CARLA_PROBE_INTERVAL:-5}"
# Maximum number of restart attempts per server.
CARLA_MAX_RETRIES="${CARLA_MAX_RETRIES:-3}"

# find_carla_pid PORT
#   Finds the PID of the CarlaUE4-Linux-Shipping process listening on PORT.
#   CarlaUE4.sh is a thin shell wrapper that forks the real UE4 binary;
#   the wrapper exits almost immediately, so we must track the child.
#   Returns the PID via stdout, or empty string if not found.
find_carla_pid() {
    local port="$1"
    # Look for CarlaUE4-Linux-Shipping with the matching port argument
    pgrep -f "CarlaUE4-Linux-Shipping.*-carla-rpc-port=${port}\\b" 2>/dev/null | head -1
}

# kill_carla_by_port PORT
#   Kills any CarlaUE4 processes (both shell wrapper and binary) for the given port.
kill_carla_by_port() {
    local port="$1"
    # Kill the binary
    local pids
    pids=$(pgrep -f "CarlaUE4.*-carla-rpc-port=${port}\\b" 2>/dev/null || true)
    if [ -n "${pids}" ]; then
        echo "${pids}" | xargs kill -9 2>/dev/null || true
    fi
}

# wait_for_port HOST PORT TIMEOUT_SEC PROBE_INTERVAL_SEC
#   Polls until TCP connection to HOST:PORT succeeds, or TIMEOUT_SEC expires.
#   Also checks that the CARLA binary process is still alive each probe.
#   Returns 0 on success, 1 on timeout/crash.
wait_for_port() {
    local host="$1" port="$2" timeout="$3" interval="$4"
    local elapsed=0
    while (( elapsed < timeout )); do
        # Find the real CarlaUE4-Linux-Shipping PID
        local carla_pid
        carla_pid=$(find_carla_pid "${port}")
        if [ -z "${carla_pid}" ]; then
            # The shell wrapper may still be spawning the binary; give it a moment
            if (( elapsed > 30 )); then
                echo "  [FAIL] No CarlaUE4-Linux-Shipping process found for port ${port} after ${elapsed}s."
                return 1
            fi
        fi
        # Try TCP connection (timeout 2s)
        if timeout 2 bash -c "echo > /dev/tcp/${host}/${port}" 2>/dev/null; then
            return 0
        fi
        sleep "${interval}"
        elapsed=$((elapsed + interval))
    done
    echo "  [FAIL] Port ${port} not ready after ${timeout}s."
    return 1
}

# launch_one_carla INDEX
#   Launches a single CARLA server and waits for it to become ready.
#   Returns 0 on success, 1 on failure after all retries exhausted.
launch_one_carla() {
    local i="$1"
    local GPU_ID=${GPU_LIST[$i]}
    local PORT=$((CARLA_BASE_PORT + i * CARLA_PORT_STEP))
    local PROCESS_NAME="carla_gpu${GPU_ID}_port${PORT}"
    local LOG_FILE="${SCRIPT_DIR}/${PROCESS_NAME}.log"

    for (( attempt=1; attempt<=CARLA_MAX_RETRIES; attempt++ )); do
        echo -e "\033[32m[${i}/${NUM_GPUS}] GPU ${GPU_ID} → port ${PORT} (attempt ${attempt}/${CARLA_MAX_RETRIES})\033[0m"

        # Kill previous attempt if still around
        kill_carla_by_port "${PORT}"
        sleep 2

        # Launch CARLA with dedicated GPU via -graphicsadapter=GPU_ID.
        # Use nohup so it survives if the launching shell exits.
        nohup "${CARLA_SH}" \
            -RenderOffScreen \
            -nosound \
            -carla-rpc-port="${PORT}" \
            -graphicsadapter="${GPU_ID}" \
            > "${LOG_FILE}" 2>&1 &

        local WRAPPER_PID=$!
        echo "  Wrapper PID: ${WRAPPER_PID}, Log: ${LOG_FILE}"

        # Give the wrapper a moment to fork the real binary
        sleep 5

        # Find the real CarlaUE4-Linux-Shipping PID
        local CARLA_PID
        CARLA_PID=$(find_carla_pid "${PORT}")
        if [ -n "${CARLA_PID}" ]; then
            echo "  CarlaUE4-Linux-Shipping PID: ${CARLA_PID}"
            echo "${CARLA_PID}" > "${PID_DIR}/${PROCESS_NAME}.pid"
        else
            echo "  (binary PID not yet found, will poll...)"
            echo "${WRAPPER_PID}" > "${PID_DIR}/${PROCESS_NAME}.pid"
        fi

        # Wait for RPC port to become reachable
        echo "  Waiting for port ${PORT} (timeout ${CARLA_READY_TIMEOUT}s)..."
        if wait_for_port "localhost" "${PORT}" "${CARLA_READY_TIMEOUT}" "${CARLA_PROBE_INTERVAL}"; then
            # Update PID file with the real binary PID
            CARLA_PID=$(find_carla_pid "${PORT}")
            if [ -n "${CARLA_PID}" ]; then
                echo "${CARLA_PID}" > "${PID_DIR}/${PROCESS_NAME}.pid"
            fi
            echo -e "  \033[32m✓ GPU ${GPU_ID} port ${PORT} ready (PID ${CARLA_PID}).\033[0m"
            return 0
        fi

        echo -e "  \033[31m✗ GPU ${GPU_ID} port ${PORT} failed (attempt ${attempt}).\033[0m"
        # Clean up the failed process
        kill_carla_by_port "${PORT}"
        sleep 2
    done

    echo -e "\033[31m[ERROR] GPU ${GPU_ID} port ${PORT}: all ${CARLA_MAX_RETRIES} attempts failed.\033[0m"
    return 1
}

# ── Stop mode ──
if [ "${1:-}" = "stop" ]; then
    echo "Stopping all CARLA host processes..."
    if [ -d "${PID_DIR}" ]; then
        for pidfile in "${PID_DIR}"/*.pid; do
            [ -f "${pidfile}" ] || continue
            pid=$(cat "${pidfile}")
            name=$(basename "${pidfile}" .pid)
            # Extract port from filename (carla_gpuX_portYYYYY)
            port=$(echo "${name}" | grep -oP 'port\K[0-9]+')
            # Kill all CarlaUE4 processes matching this port
            local_pids=$(pgrep -f "CarlaUE4.*-carla-rpc-port=${port}\\b" 2>/dev/null || true)
            if [ -n "${local_pids}" ]; then
                echo "  Stopping ${name} (PIDs: $(echo ${local_pids} | tr '\n' ' '))..."
                echo "${local_pids}" | xargs kill 2>/dev/null || true
                # Wait up to 10s for graceful shutdown
                for _ in $(seq 1 10); do
                    remaining=$(pgrep -f "CarlaUE4.*-carla-rpc-port=${port}\\b" 2>/dev/null || true)
                    [ -z "${remaining}" ] && break
                    sleep 1
                done
                # Force kill if still alive
                remaining=$(pgrep -f "CarlaUE4.*-carla-rpc-port=${port}\\b" 2>/dev/null || true)
                if [ -n "${remaining}" ]; then
                    echo "  Force killing ${name}..."
                    echo "${remaining}" | xargs kill -9 2>/dev/null || true
                fi
            else
                echo "  ${name} already stopped."
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
            pid=$(cat "${pidfile}")
            name=$(basename "${pidfile}" .pid)
            port=$(echo "${name}" | grep -oP 'port\K[0-9]+')
            carla_pid=$(pgrep -f "CarlaUE4-Linux-Shipping.*-carla-rpc-port=${port}\\b" 2>/dev/null | head -1 || true)
            if [ -n "${carla_pid}" ]; then
                echo "  ✓ ${name} (PID ${carla_pid}) — running"
            else
                echo "  ✗ ${name} — stopped"
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

# ── Restart-dead mode: restart only crashed CARLA servers ──
if [ "${1:-}" = "restart-dead" ]; then
    validate_carla
    mkdir -p "${PID_DIR}"
    echo "Checking for crashed CARLA servers and restarting them..."
    restarted=0
    for (( i=0; i<NUM_GPUS; i++ )); do
        GPU_ID=${GPU_LIST[$i]}
        PORT=$((CARLA_BASE_PORT + i * CARLA_PORT_STEP))
        PROCESS_NAME="carla_gpu${GPU_ID}_port${PORT}"
        carla_pid=$(pgrep -f "CarlaUE4-Linux-Shipping.*-carla-rpc-port=${PORT}\\b" 2>/dev/null | head -1 || true)
        if [ -n "${carla_pid}" ]; then
            echo "  ✓ GPU ${GPU_ID} port ${PORT} — already running (PID ${carla_pid})"
        else
            echo "  ✗ GPU ${GPU_ID} port ${PORT} — dead, restarting..."
            if launch_one_carla "${i}"; then
                restarted=$((restarted + 1))
            fi
        fi
    done
    echo ""
    echo "Restarted ${restarted} CARLA server(s)."
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
echo " Ready timeout   : ${CARLA_READY_TIMEOUT}s"
echo " Max retries     : ${CARLA_MAX_RETRIES}"
echo "============================================================"

FAILED_GPUS=()
for (( i=0; i<NUM_GPUS; i++ )); do
    if ! launch_one_carla "${i}"; then
        FAILED_GPUS+=("${GPU_LIST[$i]}")
    fi
done

echo ""
echo "============================================================"
echo " CARLA server launch summary"
echo "============================================================"
for (( i=0; i<NUM_GPUS; i++ )); do
    GPU_ID=${GPU_LIST[$i]}
    PORT=$((CARLA_BASE_PORT + i * CARLA_PORT_STEP))
    PROCESS_NAME="carla_gpu${GPU_ID}_port${PORT}"
    STORED_PID=$(cat "${PID_DIR}/${PROCESS_NAME}.pid" 2>/dev/null || echo "?")
    if [ "${STORED_PID}" != "?" ] && kill -0 "${STORED_PID}" 2>/dev/null; then
        STATUS="\033[32mrunning (PID ${STORED_PID})\033[0m"
    else
        STATUS="\033[31mFAILED (check ${SCRIPT_DIR}/${PROCESS_NAME}.log)\033[0m"
    fi
    echo -e "  [${i}] GPU ${GPU_ID} → localhost:${PORT}  ${STATUS}"
done

if [ ${#FAILED_GPUS[@]} -gt 0 ]; then
    echo ""
    echo -e "\033[31m[WARNING] Failed GPUs: ${FAILED_GPUS[*]}\033[0m"
    echo -e "\033[31m          Check logs above for details.\033[0m"
fi

echo ""
echo "To stop:         bash $(basename "$0") stop"
echo "To status:       bash $(basename "$0") status"
echo "To restart dead: bash $(basename "$0") restart-dead"
