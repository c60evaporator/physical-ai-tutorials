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
    TEAM_AGENT=${TEAM_AGENT:-${CARLA_GARAGE_ROOT}/team_code/autopilot.py}  # PDM-Lite evaluation agent
    TEAM_CONFIG=${TEAM_CONFIG:-${CARLA_GARAGE_ROOT}/team_code/model_ckpt/pdmlite_dummy}  # Dummy config for PDM-Lite agent (PDM-Lite doesn't use pretrained weight, but required by leaderboard_evaluator_local.py)
elif [ "$AGENT_NAME" = "tfpp" ]; then
    PRIVILEGED_MODE=0
    TEAM_AGENT=${TEAM_AGENT:-${CARLA_GARAGE_ROOT}/team_code/sensor_agent.py}  # Sensor-based agent for evaluation
    TEAM_CONFIG=${TEAM_CONFIG:-${CARLA_GARAGE_ROOT}/team_code/model_ckpt/tfpp/all_towns}  # Pretrained weight folder that include `config.json` and `model_0030_*.pth` for ensemble inference
else
    TEAM_AGENT=${TEAM_AGENT:?Please set TEAM_AGENT environment variable for agent '${AGENT_NAME}'.}
    TEAM_CONFIG=${TEAM_CONFIG:?Please set TEAM_CONFIG environment variable for agent '${AGENT_NAME}'.}
fi

# Get the evaluation script based on PRIVILEGED_MODE
if [ "$PRIVILEGED_MODE" -eq 1 ]; then
    CHALLENGE_TRACK_CODENAME=MAP # MAP track for privileged evaluation
    LEADERBOARD_ROOT=${CARLA_GARAGE_ROOT}/leaderboard_autopilot
    SCENARIO_RUNNER_ROOT=${CARLA_GARAGE_ROOT}/scenario_runner_autopilot
else
    CHALLENGE_TRACK_CODENAME=SENSORS # SENSORS track for non-privileged evaluation
    LEADERBOARD_ROOT=${CARLA_GARAGE_ROOT}/leaderboard
    SCENARIO_RUNNER_ROOT=${CARLA_GARAGE_ROOT}/scenario_runner
fi

# Create DATA_SAVE_DIR based on EVAL_ROUTES and timestamp
DATA_SAVE_ROOT=${PROJECT_DATA_ROOT:-/workspace/data}/evaluation/leaderboard/
# --resume flag implies reusing the latest existing directory
if [ "${RESUME}" -eq 1 ]; then
    CREATE_NEW=${CREATE_NEW:-0}
else
    CREATE_NEW=${CREATE_NEW:-1}
fi
# If set to 1, create a new timestamped directory; if set to 0, use the latest existing directory.
if [ "${CREATE_NEW}" = "1" ]; then
    TIMESTAMP=$(date +%Y%m%d%H%M)
    DATA_SAVE_DIR=${DATA_SAVE_ROOT}/${EVAL_ROUTES}_${AGENT_NAME}_${TIMESTAMP}
else
    # Find the newest existing directory starting with ${EVAL_ROUTES}_${AGENT_NAME}
    DATA_SAVE_DIR=$(find "${DATA_SAVE_ROOT}" -maxdepth 1 -type d -name "${EVAL_ROUTES}_${AGENT_NAME}_*" | sort | tail -n 1)
    if [ -z "${DATA_SAVE_DIR}" ]; then
        echo "Error: No existing directory matching '${EVAL_ROUTES}_${AGENT_NAME}_*' found under ${DATA_SAVE_ROOT}" >&2
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
    SAVE_PATH=${DATA_SAVE_DIR}/logs
    CHECKPOINT_ENDPOINT=${DATA_SAVE_DIR}/results/result_gpu${i}.json
    mkdir -p "$SAVE_PATH" "$(dirname "$CHECKPOINT_ENDPOINT")"

    # Launch evaluate_leaderboard.sh with `PORT`, `TM_PORT`, `ROUTES`, `SAVE_PATH`, `CHECKPOINT_ENDPOINT` environment variables
    CUDA_VISIBLE_DEVICES="${GPU_RANK}" \
    bash -e ${CARLA_GARAGE_ROOT}/../tools/evaluate_leaderboard.sh $CARLA_HOST $PORT $TM_PORT $ROUTES $TEAM_AGENT $TEAM_CONFIG $CHECKPOINT_ENDPOINT $SAVE_PATH $RESUME $LEADERBOARD_ROOT $SCENARIO_RUNNER_ROOT $CHALLENGE_TRACK_CODENAME &
    sleep 5
done

wait
echo "All evaluation jobs finished."
