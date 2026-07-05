#!/bin/bash
# This script is used to collect dataset for PDM-Lite in CarlaGarage.
# Getting --resume option
set -euo pipefail
RESUME=0
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --resume)
      RESUME=1
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done
set -- "${POSITIONAL[@]+"${POSITIONAL[@]}"}"  # Restore positional parameters so $1, $2 work as expected

ROUTES_DIR="${1:?Please specify the routes directory. Usage: $0 <routes_dir>}" # Directory containing route XML files for dataset collection
COLLECTION_ROUTES="$(basename "$(realpath "$ROUTES_DIR")")"  # Use folder name of ROUTES_DIR as route definition name
AGENT_NAME="${2:-}"
OUTPUT_FORMAT_NAME="garage"

if [ "$AGENT_NAME" = "pdmlite" ]; then
    TEAM_AGENT=${TEAM_AGENT:-${CARLA_GARAGE_ROOT}/team_code/data_agent.py}  # PDM-Lite data collection agent
    CHALLENGE_TRACK_CODENAME=MAP
    OUTPUT_FORMAT_NAME="garage"
elif [ "$AGENT_NAME" = "pdmlite_nuscenes" ]; then
    TEAM_AGENT=${TEAM_AGENT:-${CARLA_GARAGE_ROOT}/team_code/data_agents/data_agent_nuscenes.py}  # PDM-Lite data collection agent with nuScenes camera rig
    CHALLENGE_TRACK_CODENAME=MAP_QUALIFIER
    OUTPUT_FORMAT_NAME="garage_nuscenes"
elif [ -z "$AGENT_NAME" ]; then
    TEAM_AGENT=${TEAM_AGENT:?Please set TEAM_AGENT environment variable when AGENT_NAME is omitted.}
    CHALLENGE_TRACK_CODENAME=MAP_QUALIFIER
else
    TEAM_AGENT=${TEAM_AGENT:?Please set TEAM_AGENT environment variable for agent '${AGENT_NAME}'.}
    CHALLENGE_TRACK_CODENAME=MAP_QUALIFIER
fi

# Create DATA_SAVE_DIR based on COLLECTION_ROUTES and timestamp
DATA_SAVE_ROOT=${PROJECT_DATA_ROOT:-/workspace/data}/data_collection/${OUTPUT_FORMAT_NAME}
# --resume flag implies reusing the latest existing directory
if [ "${RESUME}" -eq 1 ]; then
    CREATE_NEW=${CREATE_NEW:-0}
else
    CREATE_NEW=${CREATE_NEW:-1}
fi
# If set to 1, create a new timestamped directory; if set to 0, use the latest existing directory.
if [ "${CREATE_NEW}" = "1" ]; then
    TIMESTAMP=$(date +%Y%m%d%H%M)
    DATA_SAVE_DIR=${DATA_SAVE_ROOT}/${COLLECTION_ROUTES}_pdmlite_${TIMESTAMP}
else
    # Find the newest existing directory starting with ${COLLECTION_ROUTES}_pdmlite
    DATA_SAVE_DIR=$(find "${DATA_SAVE_ROOT}" -maxdepth 1 -type d -name "${COLLECTION_ROUTES}_pdmlite_*" | sort | tail -n 1)
    if [ -z "${DATA_SAVE_DIR}" ]; then
        echo "Error: No existing directory matching '${COLLECTION_ROUTES}_pdmlite_*' found under ${DATA_SAVE_ROOT}" >&2
        exit 1
    fi
    echo "Resuming with existing DATA_SAVE_DIR: ${DATA_SAVE_DIR}"
fi
mkdir -p \
    "${DATA_SAVE_DIR}/data" \
    "${DATA_SAVE_DIR}/results" \
    "${DATA_SAVE_DIR}/logs"

# ── CARLA Port settings (match launch_carla_servers.sh) ──
CARLA_HOST=${CARLA_HOST:-localhost}
BASE_PORT=${CARLA_BASE_PORT:-30000}
BASE_TM_PORT=${CARLA_BASE_TM_PORT:-50000}
PORT_STEP=${CARLA_PORT_STEP:-150}

# ── GPU list from EVAL_GPUS ──
EVAL_GPUS="${EVAL_GPUS:-0,1,2,3,4,5,6,7}"
IFS=',' read -ra GPU_ARRAY <<< "${EVAL_GPUS}"
NUM_GPUS=${#GPU_ARRAY[@]}

# Collect all route XML files (filepath-based ordering)
mapfile -t ROUTE_FILES < <(find "$ROUTES_DIR" -type f -name "*.xml" | sort)
if [ "${#ROUTE_FILES[@]}" -eq 0 ]; then
    echo "No XML files found under: $ROUTES_DIR" >&2
    exit 1
fi
TOTAL_FILES="${#ROUTE_FILES[@]}"

# Split the route XML files for multi-GPU (split equally into NUM_GPUS parts)
# First (TOTAL_FILES % NUM_GPUS) GPUs get one extra file
declare -a START_IDX
declare -a END_IDX

base=$(( TOTAL_FILES / NUM_GPUS ))
rem=$(( TOTAL_FILES % NUM_GPUS ))
start=0

for ((i=0; i<NUM_GPUS; i++)); do
    chunk_size=$base
    if [ "$i" -lt "$rem" ]; then
        chunk_size=$((chunk_size + 1))
    fi

    START_IDX[$i]=$start
    END_IDX[$i]=$((start + chunk_size))
    start=$((start + chunk_size))
done

# ── Retry / watchdog parameters ─────────────────────────────────────────────
MAX_RETRIES=${MAX_RETRIES:-5}  # max restart attempts per route before skipping it
RETRY_WAIT=${RETRY_WAIT:-30}  # seconds to wait before retrying after a crash
CARLA_WAIT_TIMEOUT=${CARLA_WAIT_TIMEOUT:-1800}  # seconds to wait for CARLA port to reopen (watchdog restart)
# request_carla_restart(): asks the host-side watchdog for a fresh CARLA
# instance via a sentinel file in tools/carla_launch/ (shared ./tools mount).
TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TOOLS_DIR}/carla_launch/_restart_request.sh"

# run_route GPU_RANK PORT TM_PORT ROUTES SAVE_PATH CHECKPOINT TRACK TOWN
# Runs collect_dataset.sh with automatic retry on CARLA crash.
# Output goes to the caller's stdout (redirected to log file by the outer subshell).
# A route that fails all retries is logged and SKIPPED (return 0) so the GPU
# continues with remaining routes.
#
# CARLA recovery:
#   After each failure the script requests a fresh CARLA instance via
#   request_carla_restart() (see carla_launch/_restart_request.sh for the
#   sentinel protocol and rationale), then confirms the port is open and
#   retries. Without a running host-side watchdog it falls back to reusing
#   the existing instance (previous behaviour).
#
# always_resume:
#   After the first failure, resume=1 is passed so leaderboard_evaluator does
#   NOT call clear_records(), preserving any partial checkpoint data.
#
# Agent-failure detection (exit code 0):
#   The evaluator only exits non-zero for 'Simulation crashed'; agent setup
#   failures and agent runtime crashes are recorded as
#   'Failed - Agent couldn't be set up' / 'Failed - Agent crashed' in the
#   checkpoint and exit 0. Those are detected from the checkpoint records and
#   retried too. Because such failures still advance the checkpoint progress
#   (a resumed retry would no-op), the checkpoint is deleted and the retry
#   runs fresh (resume=0).
run_route() {
    local gpu_rank="$1"
    local port="$2"
    local tm_port="$3"
    local routes="$4"
    local save_path="$5"
    local checkpoint="$6"
    local track="$7"
    local town="$8"
    local team_config="${routes}"  # PDM-Lite uses the route XML file as its config
    local route_label
    route_label=$(basename "${routes}" .xml)
    local always_resume=${RESUME}

    set +e
    for (( attempt=1; attempt<=MAX_RETRIES; attempt++ )); do
        echo "[GPU ${gpu_rank}/${route_label}] Attempt ${attempt}/${MAX_RETRIES}"

        CUDA_VISIBLE_DEVICES="${gpu_rank}" \
        bash -e "${CARLA_GARAGE_ROOT}/../tools/leaderboard_local/collect_dataset.sh" \
            "${CARLA_HOST}" "${port}" "${tm_port}" "${routes}" \
            "${TEAM_AGENT}" "${team_config}" "${checkpoint}" "${save_path}" \
            "${always_resume}" "${track}" "${town}"

        local exit_code=$?

        if [[ ${exit_code} -eq 0 ]]; then
            # The evaluator exits 0 even when the agent failed to set up or
            # crashed mid-route: only 'Simulation crashed' exits non-zero (see
            # FAILURE_MESSAGES and leaderboard_evaluator_local.py). Inspect the
            # checkpoint so agent failures are retried instead of being
            # silently recorded as complete.
            local agent_failure
            agent_failure=$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        records = json.load(f)['_checkpoint']['records']
    print(next((r['status'] for r in records if str(r.get('status', '')).startswith('Failed - Agent')), ''))
except Exception:
    print('')
" "${checkpoint}" 2>/dev/null || echo '')

            if [[ -z "${agent_failure}" ]]; then
                echo "[GPU ${gpu_rank}/${route_label}] Completed."
                set -e
                return 0
            fi

            echo "[GPU ${gpu_rank}/${route_label}] Evaluator exited 0 but the checkpoint says \"${agent_failure}\"" \
                 "(attempt ${attempt}/${MAX_RETRIES}). Treating as a failure."
            # The failure advanced the checkpoint's progress, so a resumed retry
            # would consider the route done and no-op. Delete the checkpoint
            # (it only holds the worthless failed record) and start fresh.
            rm -f "${checkpoint}"
            always_resume=0
        else
            echo "[GPU ${gpu_rank}/${route_label}] Failed (exit=${exit_code}, attempt ${attempt}/${MAX_RETRIES})."

            # After first failure, pass resume=1 to avoid clear_records() wiping the checkpoint.
            always_resume=1
        fi

        if [[ ${attempt} -lt ${MAX_RETRIES} ]]; then
            local wait_loops=$(( CARLA_WAIT_TIMEOUT / 5 ))

            # Ask the host-side watchdog for a fresh CARLA instance and wait
            # for the restart to finish (falls back if no watchdog responds).
            request_carla_restart "${port}" "[GPU ${gpu_rank}]"

            # Confirm the port accepts connections before retrying.
            local carla_back=false
            echo "[GPU ${gpu_rank}] Waiting for CARLA on port ${port} (up to ${CARLA_WAIT_TIMEOUT}s)..."
            for (( w=0; w<wait_loops; w++ )); do
                if timeout 2 bash -c "echo > /dev/tcp/localhost/${port}" 2>/dev/null; then
                    carla_back=true
                    break
                fi
                sleep 5
            done
            if [[ "${carla_back}" = true ]]; then
                echo "[GPU ${gpu_rank}] CARLA on port ${port} is back. Retrying in ${RETRY_WAIT}s..."
            else
                echo "[GPU ${gpu_rank}] CARLA on port ${port} not reachable after ${CARLA_WAIT_TIMEOUT}s. Retrying anyway..."
            fi
            sleep "${RETRY_WAIT}"
        fi
    done

    echo "[GPU ${gpu_rank}/${route_label}] All ${MAX_RETRIES} retries failed. Skipping route."
    set -e
    return 0  # Return 0 so the GPU continues with remaining routes.
}

# Iterate over GPUs and launch evaluations in parallel
for (( i=0; i<NUM_GPUS; i++ )); do
    PORT=$((BASE_PORT + i * PORT_STEP))
    TM_PORT=$((BASE_TM_PORT + i * PORT_STEP))
    GPU_RANK=${GPU_ARRAY[$i]}
    start_idx="${START_IDX[$i]}"
    end_idx="${END_IDX[$i]}"
    
    # Skip idle GPUs when TOTAL_FILES < NUM_GPUS
    if [ "$start_idx" -ge "$end_idx" ]; then
        echo "[GPU ${GPU_RANK}] No assigned routes. Skipping."
        continue
    fi

    echo "[GPU ${GPU_RANK}] Processing files index range: ${start_idx} .. $((end_idx - 1))"
    (
        # Iterate over route XML files for each GPU based on the splitting
        for (( j=start_idx; j<end_idx; j++ )); do
            # Get variables for each route XML file
            ROUTES="${ROUTE_FILES[$j]}"  # Get the route XML file path
            TOWN="$(echo "$ROUTES" | grep -oEim1 'town[^_/]*' || true)" # Get the town name from the route XML file path (started from "town" and ended before "_" or "/")
            if [ -z "$TOWN" ]; then
                echo "Failed to detect town from path: $ROUTES" >&2
                continue
            fi
            SCENARIO_TYPE="$(basename "$(dirname "$ROUTES")")" # Get the scenario type from the route XML file path (Folder name of the parent of the route XML file)
            ROUTEFILE_NUMBER="$(basename "$ROUTES" .xml)" # Get the route file number from the route XML file name (if file name is "22_0.xml", use "22_0")
            SAVE_PATH=${DATA_SAVE_DIR}/data/${SCENARIO_TYPE}
            CHECKPOINT_ENDPOINT=${DATA_SAVE_DIR}/results/${SCENARIO_TYPE}/${ROUTEFILE_NUMBER}_result.json
            mkdir -p "$SAVE_PATH" "$(dirname "$CHECKPOINT_ENDPOINT")"
            echo "[GPU ${GPU_RANK} $(( j - start_idx + 1 ))/$((end_idx - start_idx))] ROUTES=${ROUTES}"

            TEAM_CONFIG=${ROUTES}  # Set TEAM_CONFIG to the current route XML file for PDM-Lite agent (PDM-Lite uses the route XML file as its config)

            # Run collect_dataset.sh with retry/watchdog logic (sequential; one CARLA server per GPU)
            run_route "${GPU_RANK}" "${PORT}" "${TM_PORT}" "${ROUTES}" "${SAVE_PATH}" "${CHECKPOINT_ENDPOINT}" "${CHALLENGE_TRACK_CODENAME}" "${TOWN}"

        done
    ) >> "${DATA_SAVE_DIR}/logs/log_gpu${i}.log" 2>&1 &
done

wait
echo "All dataset collection jobs finished."
