#!/bin/bash
ROUTES_FILE="${1:?Please specify the routes file (.xml). Usage: $0 <routes_file>}" # Route definition XML file
EVAL_ROUTES="$(basename "$ROUTES_FILE" .xml)"  # Use file name of ROUTES_FILE as eval_route name

# Create DATA_SAVE_DIR based on EVAL_ROUTES and timestamp if not set by environment variable
TIMESTAMP=$(date +%Y%m%d%H%M)
DATA_SAVE_ROOT=${PROJECT_DATA_ROOT:-/workspace/data}/evaluation/leaderboard
DATA_SAVE_DIR=${DATA_SAVE_DIR:-${DATA_SAVE_ROOT}/${EVAL_ROUTES}_tfpp_${TIMESTAMP}}

export HOST=${CARLA_HOST:-localhost}
export PORT=${CARLA_PORT:-2000}
export TM_PORT=${TM_PORT:-8000}
export TM_SEED=${TM_SEED:-0}

export LEADERBOARD_ROOT=${CARLA_GARAGE_ROOT}/leaderboard
export SCENARIO_RUNNER_ROOT=${CARLA_GARAGE_ROOT}/scenario_runner
# Rebuild PYTHONPATH explicitly so imports resolve to autopilot variants.
export PYTHONPATH=${CARLA_ROOT:-/workspace/carla}/PythonAPI/carla:${LEADERBOARD_ROOT}:${SCENARIO_RUNNER_ROOT}:${PYTHONPATH}

export ROUTES=${ROUTES_FILE}  # Route definition XML file
export TEAM_AGENT=${TEAM_AGENT:-${CARLA_GARAGE_ROOT}/team_code/sensor_agent.py}
export TEAM_CONFIG=${TEAM_CONFIG:-${CARLA_GARAGE_ROOT}/team_code/model_ckpt/tfpp/all_towns}
mkdir -p "$(dirname "$TEAM_CONFIG")"  # Ensure the directory exists
export REPETITIONS=${REPETITIONS:-1} # multiple evaluation runs (1 means no repetition, 2 means each route is run twice, etc.)

export DEBUG_CHALLENGE=0
# Use a script-local override variable to avoid inheriting container default CHALLENGE_TRACK_CODENAME=SENSORS.
export CHALLENGE_TRACK_CODENAME=SENSORS # MAP for privileged agent evaluation, SENSORS for non-privileged PDM-Lite evaluation
export CHECKPOINT_ENDPOINT=${CHECKPOINT_ENDPOINT:-${DATA_SAVE_DIR}/results/result.json}
export RESUME=${RESUME:-0}
export EVALUATION_TIMEOUT=${EVALUATION_TIMEOUT:-600} # seconds

export DATAGEN=0
export TOWN=eval
export SAVE_PATH=${SAVE_PATH:-${DATA_SAVE_DIR}/logs}
export REPETITION=${REPETITION:-0} # Repetition count (Smaller than REPETITIONS, used for saving dataset in different folders)

export DEBUG_ENV_AGENT=0
export RECORD=1
export DIRECT=1
export COMPILE=0
export TUNED_AIM_DISTANCE=0
export SLOWER=0
export UNCERTAINTY_WEIGHT=1
export STOP_AFTER_METER=-1

cd "${CARLA_GARAGE_ROOT}" # Move to ${CARLA_GARAGE_ROOT} to ensure relative paths for leaderboard_evaluator_local.py
python ${LEADERBOARD_ROOT}/leaderboard/leaderboard_evaluator_local.py \
--host=${HOST} \
--port=${PORT} \
--traffic-manager-port=${TM_PORT} \
--traffic-manager-seed=${TM_SEED} \
--routes=${ROUTES_FILE} \
--repetitions=${REPETITIONS} \
--track=${CHALLENGE_TRACK_CODENAME} \
--checkpoint=${CHECKPOINT_ENDPOINT} \
--agent=${TEAM_AGENT} \
--agent-config=${TEAM_CONFIG} \
--debug=${DEBUG_CHALLENGE} \
--resume=${RESUME} \
--timeout=${EVALUATION_TIMEOUT} \
--record=${RECORD_PATH}
