#!/bin/bash
# Create DATA_SAVE_DIR based on EVAL_ROUTES and timestamp if not set by environment variable
TIMESTAMP=$(date +%Y%m%d%H%M)
DATA_SAVE_ROOT=${PROJECT_DATA_ROOT:-/workspace/data}/evaluation/leaderboard
DATA_SAVE_DIR=${DATA_SAVE_DIR}

export HOST=$1
export PORT=$2
export TM_PORT=$3
export ROUTES_FILE=$4 # Route definition XML file
export TEAM_AGENT=$5
export TEAM_CONFIG=$6
export CHECKPOINT_ENDPOINT=$7
export SAVE_PATH=$8
export RESUME=$9
export CHALLENGE_TRACK_CODENAME=${10}
export LEADERBOARD_ROOT=${11}
export SCENARIO_RUNNER_ROOT=${12}

export TM_SEED=${TM_SEED:-0}
# Rebuild PYTHONPATH explicitly so imports resolve to autopilot variants.
export PYTHONPATH=${CARLA_ROOT:-/workspace/carla}/PythonAPI/carla:${LEADERBOARD_ROOT}:${SCENARIO_RUNNER_ROOT}:${PYTHONPATH}

mkdir -p "$(dirname "$TEAM_CONFIG")"  # Ensure the directory exists
export REPETITIONS=${REPETITIONS:-1} # multiple evaluation runs (1 means no repetition, 2 means each route is run twice, etc.)

export DEBUG_CHALLENGE=0
# Use a script-local override variable to avoid inheriting container default CHALLENGE_TRACK_CODENAME=SENSORS.
export EVALUATION_TIMEOUT=${EVALUATION_TIMEOUT:-600} # seconds

export DATAGEN=0
export TOWN=eval
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
python ${CARLA_GARAGE_ROOT}/../tools/leaderboard_local/leaderboard_evaluator_local_ext.py \
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
