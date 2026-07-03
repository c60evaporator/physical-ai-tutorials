#!/usr/bin/env bash
# =============================================================================
# _carla_lib.sh — Shared CARLA launch/watchdog library.
#
# SOURCE this file; do NOT execute it directly.
# The caller (launch_carla_servers.sh or _carla_watchdog.sh) must define
# SCRIPT_DIR before sourcing.  Paths inside this library are derived from
# BASH_SOURCE[0] so they are always relative to the actual file location,
# regardless of where the calling script lives.
# =============================================================================

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"  # tools/carla_launch/
_TOOLS_DIR="$(cd "${_LIB_DIR}/.." && pwd)"                 # tools/
_CG_DIR="$(cd "${_TOOLS_DIR}/.." && pwd)"                  # scripts/CarlaGarage/

# ── Environment variables ────────────────────────────────────────────────────
if [[ -f "${_CG_DIR}/.env" ]]; then
    set -a; source "${_CG_DIR}/.env"; set +a
fi

# ── Configuration defaults ───────────────────────────────────────────────────
EVAL_GPUS="${EVAL_GPUS:-0}"
CARLA_BASE_PORT="${CARLA_BASE_PORT:-2000}"
CARLA_PORT_STEP="${CARLA_PORT_STEP:-150}"

# Seconds to wait for CARLA's RPC port to accept connections after launch.
CARLA_READY_TIMEOUT="${CARLA_READY_TIMEOUT:-120}"

# Seconds between TCP readiness probes inside wait_port().
CARLA_PROBE_INTERVAL="${CARLA_PROBE_INTERVAL:-5}"

# Number of launch attempts per server at start time.
# Watchdog handles runtime crashes, so 2 retries at startup is sufficient
# to absorb transient port-residue or GPU driver initialisation issues.
CARLA_MAX_RETRIES="${CARLA_MAX_RETRIES:-2}"

# Seconds between watchdog health checks.
WATCHDOG_INTERVAL="${WATCHDOG_INTERVAL:-60}"

# CARLA_HOST_PATH must be an absolute path (set in .env).
CARLA_HOST_PATH="${CARLA_HOST_PATH:-}"
CARLA_SH="${CARLA_HOST_PATH}/CarlaUE4.sh"

# Parse GPU list into an indexed array.
IFS=',' read -ra GPU_LIST <<< "${EVAL_GPUS}"
NUM_GPUS=${#GPU_LIST[@]}

# ── Directories ──────────────────────────────────────────────────────────────
# PID_DIR: per-server PID files  (tools/carla_launch/.pids/)
# LOG_DIR: CARLA + watchdog logs (tools/logs/)
PID_DIR="${_LIB_DIR}/.pids"
LOG_DIR="${_TOOLS_DIR}/logs"

# ── Helper functions ─────────────────────────────────────────────────────────

# find_pid PORT
#   Prints the PID of CarlaUE4-Linux-Shipping listening on PORT,
#   or nothing if no such process exists.  Always exits 0.
find_pid() {
    local port="$1"
    local result
    result=$(pgrep -f "CarlaUE4-Linux-Shipping.*-carla-rpc-port=${port}\\b" 2>/dev/null || true)
    echo "${result}" | head -1
}

# kill_by_port PORT
#   Force-kills all CarlaUE4 processes (wrapper + binary) for the given port.
kill_by_port() {
    local port="$1"
    local pids
    pids=$(pgrep -f "CarlaUE4.*-carla-rpc-port=${port}\\b" 2>/dev/null || true)
    if [[ -n "${pids}" ]]; then
        echo "${pids}" | xargs kill -9 2>/dev/null || true
    fi
}

# wait_port PORT TIMEOUT_SEC
#   Polls until a TCP connection to localhost:PORT succeeds or TIMEOUT_SEC
#   elapses.  Returns 0 on success, 1 on timeout.
wait_port() {
    local port="$1" timeout="$2"
    local elapsed=0
    while (( elapsed < timeout )); do
        if timeout 2 bash -c "echo > /dev/tcp/localhost/${port}" 2>/dev/null; then
            return 0
        fi
        sleep "${CARLA_PROBE_INTERVAL}"
        elapsed=$(( elapsed + CARLA_PROBE_INTERVAL ))
    done
    echo "  [FAIL] Port ${port} not ready after ${timeout}s." >&2
    return 1
}

# launch_one INDEX
#   Launches a single CARLA server for GPU_LIST[INDEX] on the corresponding
#   RPC port.  Retries up to CARLA_MAX_RETRIES times on failure.
#   Returns 0 on success, 1 if all attempts fail.
launch_one() {
    local i="$1"
    local gpu="${GPU_LIST[$i]}"
    local port=$(( CARLA_BASE_PORT + i * CARLA_PORT_STEP ))
    local name="carla_gpu${gpu}_port${port}"

    mkdir -p "${PID_DIR}" "${LOG_DIR}"

    for (( attempt=1; attempt<=CARLA_MAX_RETRIES; attempt++ )); do
        echo "[carla] GPU ${gpu} port ${port} — attempt ${attempt}/${CARLA_MAX_RETRIES}"
        kill_by_port "${port}"
        sleep 2

        nohup "${CARLA_SH}" \
            -RenderOffScreen \
            -nosound \
            -carla-rpc-port="${port}" \
            -graphicsadapter="${gpu}" \
            > "${LOG_DIR}/${name}.log" 2>&1 &

        # Give the shell wrapper time to fork CarlaUE4-Linux-Shipping.
        sleep 5

        echo "[carla] Waiting for port ${port} (timeout ${CARLA_READY_TIMEOUT}s)..."
        if wait_port "${port}" "${CARLA_READY_TIMEOUT}"; then
            local pid
            pid=$(find_pid "${port}")
            echo "${pid:-?}" > "${PID_DIR}/${name}.pid"
            echo "[carla] ✓ GPU ${gpu} port ${port} ready (PID ${pid:-?})."
            return 0
        fi

        echo "[carla] ✗ GPU ${gpu} port ${port} not ready (attempt ${attempt})."
        kill_by_port "${port}"
        sleep 2
    done

    echo "[carla] ERROR: GPU ${gpu} port ${port} — all ${CARLA_MAX_RETRIES} attempts failed." >&2
    return 1
}
