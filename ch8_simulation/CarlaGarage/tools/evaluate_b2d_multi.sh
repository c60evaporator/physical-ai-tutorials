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
elif [ "$AGENT_NAME" = "uniad" ]; then
    PRIVILEGED_MODE=0
    TEAM_AGENT=${TEAM_AGENT:-${CARLA_GARAGE_ROOT}/../Bench2DriveZoo/team_code/uniad_b2d_agent.py}  # Sensor-based agent for evaluation
    TEAM_CONFIG=${TEAM_CONFIG:-${CARLA_GARAGE_ROOT}/../Bench2DriveZoo/adzoo/uniad/configs/stage2_e2e/base_e2e_b2d.py+${CARLA_GARAGE_ROOT}/../Bench2DriveZoo/ckpts/uniad_base_b2d.pth}
    PLANNER_TYPE=traj
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
# Reset PYTHONPATH to Bench2Drive paths only, to prevent CarlaGarage leaderboard from shadowing Bench2Drive's leaderboard
export PYTHONPATH=${CARLA_ROOT:-/workspace/carla}/PythonAPI/carla:${CARLA_GARAGE_ROOT}/Bench2Drive/leaderboard:${CARLA_GARAGE_ROOT}/Bench2Drive/scenario_runner


# Split the route XML file for multi-GPU (split equally into NUM_GPUS parts)
SPLIT_BASE="${DATA_SAVE_DIR}/split_routes/${EVAL_ROUTES}"
mkdir -p "${DATA_SAVE_DIR}/split_routes"
cp "${ROUTES_FILE}" "${SPLIT_BASE}.xml"
python3 "${CARLA_GARAGE_ROOT}/../tools/split_route_xml.py" "${SPLIT_BASE}" "${NUM_GPUS}"

# Iterate over GPUs and launch evaluations in parallel
for (( i=0; i<NUM_GPUS; i++ )); do
    PORT=$((BASE_PORT + i * PORT_STEP))
    TM_PORT=$((BASE_TM_PORT + i * PORT_STEP))
    GPU_RANK=${GPU_ARRAY[$i]}
    
    # Get variables for each GPU
    ROUTES="${SPLIT_BASE}_${i}.xml"  # Use split route XML file for each GPU
    SAVE_PATH=${DATA_SAVE_DIR}/data
    CHECKPOINT_ENDPOINT=${DATA_SAVE_DIR}/results/result_gpu${i}.json
    mkdir -p "$SAVE_PATH" "$(dirname "$CHECKPOINT_ENDPOINT")"

    # Convert RESUME flag (0/1) to the evaluator's --resume argument (type=bool: empty => False).
    RESUME_ARG=""
    if [ "${RESUME}" -eq 1 ]; then
        RESUME_ARG="--resume=True"
    fi

    # Run the Bench2Drive evaluator against the EXTERNAL CARLA server (no self-launch).
    # - GPU is selected via CUDA_VISIBLE_DEVICES; the server instance is selected via --host/--port.
    # - WORK_DIR is required by the B2D evaluator's get_weather_id() to locate leaderboard/data/weather.xml.
    # - IS_BENCH2DRIVE must be "True" so autopilot.py uses path_to_conf_file for save_name (not undefined 'now').
    # - ROUTES env var is read by autopilot.py for the save path stem (only used when SAVE_PATH is also set).
    # - SAVE_PATH is intentionally NOT set here (evaluation mode does not write sensor data).
    WORK_DIR=${CARLA_GARAGE_ROOT}/Bench2Drive \
    IS_BENCH2DRIVE=True \
    ROUTES="${ROUTES}" \
    CUDA_VISIBLE_DEVICES="${GPU_RANK}" \
    python "${CARLA_GARAGE_ROOT}/../tools/b2d_ext/leaderboard_evaluator_ext.py" \
        --host="${CARLA_HOST}" \
        --port="${PORT}" \
        --traffic-manager-port="${TM_PORT}" \
        --routes="${ROUTES}" \
        --repetitions=1 \
        --track="${CHALLENGE_TRACK_CODENAME}" \
        --checkpoint="${CHECKPOINT_ENDPOINT}" \
        --agent="${TEAM_AGENT}" \
        --agent-config="${TEAM_CONFIG}" \
        --debug=0 \
        --record="${RECORD_PATH}" \
        --gpu-rank="${GPU_RANK}" \
        ${RESUME_ARG} \
        > "${DATA_SAVE_DIR}/logs/log_gpu${i}.log" 2>&1 &
    sleep 5
done

wait
echo "All evaluation jobs finished."
