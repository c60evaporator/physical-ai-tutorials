#!/bin/bash
# This script is used to evaluate the leaderboard with multiple GPUs in CarlaGarage. It splits the route XML files into multiple parts and launches parallel evaluations on different GPUs
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

ROUTES_FILE="${1:?Please specify the routes file (.xml). Usage: $0 <routes_file>}" # Route definition XML file
EVAL_ROUTES="$(basename "$ROUTES_FILE" .xml)"  # Use file name of ROUTES_FILE as eval_route name
AGENT_NAME=$2

SAVE_AGENT_DATA=${SAVE_AGENT_DATA:-0}  # If set to 1, save agent data (metric_info.json, etc.) during evaluation; if set to 0, do not save agent data
DEBUG_CHALLENGE=${DEBUG_CHALLENGE:-0}  # If set to 1, run in debug mode (prints agent debug information); if set to 0, run in normal mode

PRIVILEGED_MODE=${PRIVILEGED_MODE:-0}  # If set to 1, run in privileged mode (using autopilot agent); if set to 0, run in non-privileged mode (using PDM-Lite agent)

if [ "$AGENT_NAME" = "pdmlite" ]; then
    PRIVILEGED_MODE=1
    TEAM_AGENT=${TEAM_AGENT:-${CARLA_GARAGE_ROOT}/Bench2Drive/leaderboard/team_code/autopilot.py}  # PDM-Lite evaluation agent
    TEAM_CONFIG=${TEAM_CONFIG:-${CARLA_GARAGE_ROOT}/team_code/model_ckpt/pdmlite_dummy}  # Dummy config for PDM-Lite agent (PDM-Lite doesn't use pretrained weight, but required by leaderboard_evaluator_local.py)
    PLANNER_TYPE=traj
elif [ "$AGENT_NAME" = "tfpp" ]; then
    PRIVILEGED_MODE=0
    TEAM_AGENT=${TEAM_AGENT:-${CARLA_GARAGE_ROOT}/team_code/sensor_agent.py}  # Sensor-based agent for evaluation
    TEAM_CONFIG=${TEAM_CONFIG:-${CARLA_GARAGE_ROOT}/team_code/model_ckpt/tfpp/all_towns}  # Pretrained weight folder that include `config.json` and `model_0030_*.pth` for ensemble inference
    PLANNER_TYPE=traj
elif [ "$AGENT_NAME" = "uniad-base" ]; then
    PRIVILEGED_MODE=0
    TEAM_AGENT=${TEAM_AGENT:-${CARLA_GARAGE_ROOT}/../Bench2DriveZoo/team_code/uniad_b2d_agent.py}  # Sensor-based agent for evaluation
    TEAM_CONFIG=${TEAM_CONFIG:-${CARLA_GARAGE_ROOT}/../Bench2DriveZoo/adzoo/uniad/configs/stage2_e2e/base_e2e_b2d.py+${CARLA_GARAGE_ROOT}/../Bench2DriveZoo/ckpts/uniad_base_b2d.pth}
    PLANNER_TYPE=traj
    # Bench2DriveZoo agents import "from Bench2DriveZoo.team_code... import ..."
    # (needs the parent dir of Bench2DriveZoo) and "import adzoo..." (needs
    # Bench2DriveZoo itself). Appended to PYTHONPATH after the reset below.
    EXTRA_PYTHONPATH=${CARLA_GARAGE_ROOT}/..:${CARLA_GARAGE_ROOT}/../Bench2DriveZoo
elif [ "$AGENT_NAME" = "uniad-tiny" ]; then
    PRIVILEGED_MODE=0
    TEAM_AGENT=${TEAM_AGENT:-${CARLA_GARAGE_ROOT}/../Bench2DriveZoo/team_code/uniad_b2d_agent.py}  # Sensor-based agent for evaluation
    TEAM_CONFIG=${TEAM_CONFIG:-${CARLA_GARAGE_ROOT}/../Bench2DriveZoo/adzoo/uniad/configs/stage2_e2e/tiny_e2e_b2d.py+${CARLA_GARAGE_ROOT}/../Bench2DriveZoo/ckpts/uniad_tiny_b2d.pth}
    PLANNER_TYPE=traj
    # Bench2DriveZoo agents import "from Bench2DriveZoo.team_code... import ..."
    # (needs the parent dir of Bench2DriveZoo) and "import adzoo..." (needs
    # Bench2DriveZoo itself). Appended to PYTHONPATH after the reset below.
    EXTRA_PYTHONPATH=${CARLA_GARAGE_ROOT}/..:${CARLA_GARAGE_ROOT}/../Bench2DriveZoo
else
    TEAM_AGENT=${TEAM_AGENT:?Please set TEAM_AGENT environment variable for agent '${AGENT_NAME}'.}
    TEAM_CONFIG=${TEAM_CONFIG:?Please set TEAM_CONFIG environment variable for agent '${AGENT_NAME}'.}
    PLANNER_TYPE=${PLANNER_TYPE:?Please set PLANNER_TYPE environment variable for agent '${AGENT_NAME}'.}
fi

# Get the evaluation script based on PRIVILEGED_MODE
if [ "$PRIVILEGED_MODE" -eq 1 ]; then
    CHALLENGE_TRACK_CODENAME=SENSORS # MAP track for privileged evaluation
else
    CHALLENGE_TRACK_CODENAME=SENSORS # SENSORS track for non-privileged evaluation
fi

# Create DATA_SAVE_DIR based on EVAL_ROUTES and timestamp
DATA_SAVE_ROOT=${PROJECT_DATA_ROOT:-/workspace/data}/evaluation/b2d/
# --resume flag implies reusing the latest existing directory
if [ "${RESUME}" -eq 1 ]; then
    CREATE_NEW=${CREATE_NEW:-0}
else
    CREATE_NEW=${CREATE_NEW:-1}
fi
# If set to 1, create a new timestamped directory; if set to 0, use the latest existing directory.
if [ "${CREATE_NEW}" = "1" ]; then
    TIMESTAMP=$(date +%Y%m%d%H%M)
    DATA_SAVE_DIR=${DATA_SAVE_ROOT}/${EVAL_ROUTES}_${AGENT_NAME}_${PLANNER_TYPE}_${TIMESTAMP}
else
    # Find the newest existing directory starting with ${EVAL_ROUTES}_${AGENT_NAME}_${PLANNER_TYPE}
    DATA_SAVE_DIR=$(find "${DATA_SAVE_ROOT}" -maxdepth 1 -type d -name "${EVAL_ROUTES}_${AGENT_NAME}_${PLANNER_TYPE}_*" | sort | tail -n 1)
    if [ -z "${DATA_SAVE_DIR}" ]; then
        echo "Error: No existing directory matching '${EVAL_ROUTES}_${AGENT_NAME}_${PLANNER_TYPE}_*' found under ${DATA_SAVE_ROOT}" >&2
        exit 1
    fi
    echo "Resuming with existing DATA_SAVE_DIR: ${DATA_SAVE_DIR}"
fi
mkdir -p \
    "${DATA_SAVE_DIR}/logs" \
    "${DATA_SAVE_DIR}/results"

# Enable saving agent data if SAVE_AGENT_DATA is set to 1
if [ "${SAVE_AGENT_DATA}" -eq 1 ]; then
    mkdir -p "${DATA_SAVE_DIR}/data"
    export SAVE_PATH="${DATA_SAVE_DIR}/data"
fi    

# ── CARLA Port settings (match launch_carla_servers.sh) ──
CARLA_HOST=${CARLA_HOST:-localhost}
BASE_PORT=${CARLA_BASE_PORT:-30000}
BASE_TM_PORT=${CARLA_BASE_TM_PORT:-50000}
PORT_STEP=${CARLA_PORT_STEP:-150}

# ── GPU list from EVAL_GPUS ──
EVAL_GPUS="${EVAL_GPUS:-0,1,2,3,4,5,6,7}"
IFS=',' read -ra GPU_ARRAY <<< "${EVAL_GPUS}"
NUM_GPUS=${#GPU_ARRAY[@]}

# ── Fixed parameters ──
RECORD_PATH=${RECORD_PATH:-}  # Optional: path prefix for CARLA recording files; empty disables recording
export RECORD_PATH
# Reset PYTHONPATH to Bench2Drive paths only, to prevent CarlaGarage leaderboard from shadowing Bench2Drive's leaderboard.
# EXTRA_PYTHONPATH (agent-specific additions, e.g. for uniad) is appended if set.
export PYTHONPATH=${CARLA_ROOT:-/workspace/carla}/PythonAPI/carla:${CARLA_GARAGE_ROOT}/Bench2Drive/leaderboard:${CARLA_GARAGE_ROOT}/Bench2Drive/scenario_runner${EXTRA_PYTHONPATH:+:${EXTRA_PYTHONPATH}}


# Split the route XML file for multi-GPU (split equally into NUM_GPUS parts)
SPLIT_BASE="${DATA_SAVE_DIR}/split_routes/${EVAL_ROUTES}"
mkdir -p "${DATA_SAVE_DIR}/split_routes"
cp "${ROUTES_FILE}" "${SPLIT_BASE}.xml"
python3 "${CARLA_GARAGE_ROOT}/../tools/b2d_leaderboard_common/split_route_xml.py" "${SPLIT_BASE}" "${NUM_GPUS}"

# ── Retry / stuck-route parameters ───────────────────────────────────────────
MAX_RETRIES=${MAX_RETRIES:-10}  # max evaluator restart attempts per GPU before giving up
RETRY_WAIT=${RETRY_WAIT:-30}  # seconds to wait before retrying after a crash
CARLA_WAIT_TIMEOUT=${CARLA_WAIT_TIMEOUT:-1800}  # seconds to wait for CARLA to come back (watchdog restart)
MAX_STUCK=${MAX_STUCK:-3}  # consecutive same-progress failures before force-skipping
MAX_TOTAL_SKIPS=${MAX_TOTAL_SKIPS:-10}  # per-GPU cap on total force-skips (prevents infinite loops)

# skip_route.py: force-inserts a "Failed - Simulation crashed" record for the stuck route and advances progress[0] so evaluation can resume.
SKIP_ROUTE_PY="${CARLA_GARAGE_ROOT}/../tools/b2d_leaderboard_common/skip_route.py"

# request_carla_restart(): asks the host-side watchdog for a fresh CARLA
# instance via a sentinel file in tools/carla_launch/ (shared ./tools mount).
TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TOOLS_DIR}/carla_launch/_restart_request.sh"

# Convert RESUME flag (0/1) to the evaluator's --resume argument.
RESUME_ARG=""
if [[ "${RESUME}" -eq 1 ]]; then
    RESUME_ARG="--resume=True"
fi

# ── Per-GPU evaluation function ───────────────────────────────────────────────
# Runs the leaderboard evaluator with automatic retry on CARLA crash.
#
# Stuck-route detection:
#   After each non-zero exit, _checkpoint.progress[0] is read from the JSON
#   checkpoint and compared to the previous value.  If the same index appears
#   MAX_STUCK times in a row (meaning CARLA crashed before Python could advance
#   progress, e.g. C++ abort from spawn_parked_vehicles), skip_route.py is
#   called to force-insert a "Failed - Simulation crashed" record and advance
#   progress[0] by 1.  The retry counter is reset so the next route gets a
#   full set of MAX_RETRIES attempts.  MAX_TOTAL_SKIPS caps total skips per GPU.
#
# CARLA recovery:
#   After a crash, the script requests a fresh CARLA instance via
#   request_carla_restart() (see carla_launch/_restart_request.sh): a crashed
#   evaluator can leave actors/TM inside a still-running server, silently
#   distorting the scores of the remaining routes. It then waits up to
#   CARLA_WAIT_TIMEOUT seconds for the port before retrying; without a running
#   host-side watchdog it falls back to reusing the existing instance.
run_gpu() {
    local i="$1"
    local PORT=$((BASE_PORT + i * PORT_STEP))
    local TM_PORT=$((BASE_TM_PORT + i * PORT_STEP))
    local GPU_RANK=${GPU_ARRAY[$i]}
    local ROUTES="${SPLIT_BASE}_${i}.xml"
    local CHECKPOINT_ENDPOINT="${DATA_SAVE_DIR}/results/result_gpu${i}.json"
    local LOG_FILE="${DATA_SAVE_DIR}/logs/log_gpu${i}.log"

    local stuck_count=0
    local last_failed_progress=-1
    local total_skips=0
    # After the first failure, all subsequent attempts must pass --resume=True
    # to prevent leaderboard_evaluator.run() from calling clear_records() and
    # wiping the checkpoint that was accumulated in previous attempts.
    local always_resume=0

    set +e
    for (( attempt=1; attempt<=MAX_RETRIES; attempt++ )); do
        echo "[gpu${i}] Attempt ${attempt}/${MAX_RETRIES} — GPU ${GPU_RANK} port ${PORT}" | tee -a "${LOG_FILE}"

        # Determine resume flag:
        #   always_resume=1 means a previous attempt already wrote to the checkpoint;
        #   passing --resume=True prevents leaderboard_evaluator from calling
        #   clear_records() which would wipe all accumulated results from disk.
        local actual_resume_arg="${RESUME_ARG}"
        if [[ ${always_resume} -eq 1 ]]; then
            actual_resume_arg="--resume=True"
        fi

        # - WORK_DIR: required by get_weather_id() to locate leaderboard/data/weather.xml
        # - IS_BENCH2DRIVE: autopilot.py uses path_to_conf_file for save_name
        # - ROUTES env var: read by autopilot.py for the save path stem
        # - SAVE_PATH: not listed here; when SAVE_AGENT_DATA=1 it is exported above
        #   (data dir) and inherited by this python call, otherwise it stays unset
        WORK_DIR=${CARLA_GARAGE_ROOT}/Bench2Drive \
        IS_BENCH2DRIVE=True \
        ROUTES="${ROUTES}" \
        CUDA_VISIBLE_DEVICES="${GPU_RANK}" \
        python "${CARLA_GARAGE_ROOT}/../tools/b2d/leaderboard_evaluator_b2d_ext.py" \
            --host="${CARLA_HOST}" \
            --port="${PORT}" \
            --traffic-manager-port="${TM_PORT}" \
            --routes="${ROUTES}" \
            --repetitions=1 \
            --track="${CHALLENGE_TRACK_CODENAME}" \
            --checkpoint="${CHECKPOINT_ENDPOINT}" \
            --agent="${TEAM_AGENT}" \
            --agent-config="${TEAM_CONFIG}" \
            --debug="${DEBUG_CHALLENGE}" \
            --record="${RECORD_PATH}" \
            --gpu-rank="${GPU_RANK}" \
            ${actual_resume_arg} \
            >> "${LOG_FILE}" 2>&1

        local exit_code=$?

        if [[ ${exit_code} -eq 0 ]]; then
            # Agent setup/runtime failures do not affect the exit code and their
            # routes stay recorded as 'Failed - Agent ...' with score 0 (progress
            # has already advanced, so a retry would not re-run them). Surface
            # them so a silently degraded evaluation is not mistaken for a clean one.
            local agent_failures
            agent_failures=$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        records = json.load(f)['_checkpoint']['records']
    print(sum(1 for r in records if str(r.get('status', '')).startswith('Failed - Agent')))
except Exception:
    print(0)
" "${CHECKPOINT_ENDPOINT}" 2>/dev/null || echo 0)
            if [[ "${agent_failures}" != "0" ]]; then
                echo "[gpu${i}] WARNING: ${agent_failures} route(s) recorded as 'Failed - Agent ...' (score 0) in ${CHECKPOINT_ENDPOINT}. Check the log for agent errors." | tee -a "${LOG_FILE}"
            fi
            echo "[gpu${i}] All routes completed successfully." | tee -a "${LOG_FILE}"
            set -e
            return 0
        fi

        echo "[gpu${i}] Evaluator exited with code ${exit_code} (attempt ${attempt}/${MAX_RETRIES})." | tee -a "${LOG_FILE}"

        # From this point onwards, the checkpoint file on disk has been touched
        # (even if the evaluator crashed early).  All subsequent retries must
        # pass --resume=True so leaderboard_evaluator does NOT call clear_records().
        always_resume=1

        # ── Stuck-route detection ─────────────────────────────────────────
        # Read _checkpoint.progress[0] from the JSON checkpoint file.
        # If the value matches the previous failure, CARLA crashed before
        # Python could advance the checkpoint (e.g. C++ abort in UE4).
        # After MAX_STUCK consecutive identical values, force-skip the route.
        # ─────────────────────────────────────────────────────────────────
        local current_progress
        current_progress=$(python3 -c "
import json, sys
try:
    with open('${CHECKPOINT_ENDPOINT}') as f:
        d = json.load(f)
    print(d['_checkpoint']['progress'][0])
except Exception:
    print(-1)
" 2>/dev/null || echo -1)

        if [[ "${current_progress}" != "-1" ]]; then
            if [[ "${current_progress}" = "${last_failed_progress}" ]]; then
                stuck_count=$((stuck_count + 1))
            else
                stuck_count=1
                last_failed_progress="${current_progress}"
            fi
            echo "[gpu${i}] Same-route failure count=${stuck_count}/${MAX_STUCK} (progress=${current_progress})." | tee -a "${LOG_FILE}"

            if [[ ${stuck_count} -ge ${MAX_STUCK} ]]; then
                if [[ ${total_skips} -ge ${MAX_TOTAL_SKIPS} ]]; then
                    echo "[gpu${i}] ERROR: MAX_TOTAL_SKIPS=${MAX_TOTAL_SKIPS} reached. Aborting GPU ${GPU_RANK}." | tee -a "${LOG_FILE}"
                    set -e
                    return 1
                fi
                echo "[gpu${i}] Force-skipping stuck route at progress=${current_progress}..." | tee -a "${LOG_FILE}"
                if python3 "${SKIP_ROUTE_PY}" "${CHECKPOINT_ENDPOINT}" "${ROUTES}" >> "${LOG_FILE}" 2>&1; then
                    stuck_count=0
                    last_failed_progress="-1"
                    total_skips=$((total_skips + 1))
                    attempt=0  # for-loop increments to 1: gives next route full MAX_RETRIES
                    echo "[gpu${i}] Skip ${total_skips}/${MAX_TOTAL_SKIPS} done. Continuing..." | tee -a "${LOG_FILE}"
                    continue
                else
                    echo "[gpu${i}] skip_route.py failed — falling back to normal retry." | tee -a "${LOG_FILE}"
                fi
            fi
        fi

        # ── CARLA restart before retrying ────────────────────────────────────────
        # Request a fresh instance from the host-side watchdog, then wait for
        # the port to accept connections.
        # ─────────────────────────────────────────────────────────────────
        if [[ ${attempt} -lt ${MAX_RETRIES} ]]; then
            request_carla_restart "${PORT}" "[gpu${i}]" 2>&1 | tee -a "${LOG_FILE}"

            local wait_loops=$(( CARLA_WAIT_TIMEOUT / 5 ))
            local carla_back=false
            echo "[gpu${i}] Waiting for CARLA on port ${PORT} (up to ${CARLA_WAIT_TIMEOUT}s)..." | tee -a "${LOG_FILE}"
            for (( w=0; w<wait_loops; w++ )); do
                if timeout 2 bash -c "echo > /dev/tcp/localhost/${PORT}" 2>/dev/null; then
                    carla_back=true
                    break
                fi
                sleep 5
            done
            if [[ "${carla_back}" = true ]]; then
                echo "[gpu${i}] CARLA on port ${PORT} is back. Resuming in ${RETRY_WAIT}s..." | tee -a "${LOG_FILE}"
            else
                echo "[gpu${i}] CARLA on port ${PORT} not reachable after ${CARLA_WAIT_TIMEOUT}s. Retrying anyway..." | tee -a "${LOG_FILE}"
            fi
            sleep "${RETRY_WAIT}"
        fi
    done

    echo "[gpu${i}] Max retries (${MAX_RETRIES}) reached. GPU ${GPU_RANK} gave up." | tee -a "${LOG_FILE}"
    set -e
    return 1
}

# ── Iterate over GPUs and launch evaluations in parallel ──────────────────────
mkdir -p "${DATA_SAVE_DIR}/results" "${DATA_SAVE_DIR}/data"
for (( i=0; i<NUM_GPUS; i++ )); do
    run_gpu "${i}" &
done

wait
echo "All evaluation jobs finished."
