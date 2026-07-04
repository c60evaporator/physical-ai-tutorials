#!/bin/bash
export HOST=$1
export PORT=$2
export TM_PORT=$3
export ROUTES=$4  # Route definition XML file
export TEAM_AGENT=$5
export TEAM_CONFIG=$6
export CHECKPOINT_ENDPOINT=$7
export SAVE_PATH=$8
export RESUME=$9
export CHALLENGE_TRACK_CODENAME=${10} # SENSORS, MAP, SENSORS_QUALIFIER, MAP_QUALIFIER
export TOWN=${11}

export TM_SEED=${TM_SEED:-0}

export LEADERBOARD_ROOT=${CARLA_GARAGE_ROOT}/leaderboard_autopilot
export SCENARIO_RUNNER_ROOT=${CARLA_GARAGE_ROOT}/scenario_runner_autopilot
# Rebuild PYTHONPATH explicitly so imports resolve to autopilot variants.
export PYTHONPATH=${CARLA_ROOT:-/workspace/carla}/PythonAPI/carla:${LEADERBOARD_ROOT}:${SCENARIO_RUNNER_ROOT}:${PYTHONPATH}

export REPETITIONS=${REPETITIONS:-1} # multiple evaluation runs (1 means no repetition, 2 means each route is run twice, etc.)

export DEBUG_CHALLENGE=0
export EVALUATION_TIMEOUT=${EVALUATION_TIMEOUT:-600} # seconds

export DATAGEN=1


export REPETITION=${REPETITION:-0} # Repetition count (Smaller than REPETITIONS, used for saving dataset in different folders)

cd "${CARLA_GARAGE_ROOT}" # Move to ${CARLA_GARAGE_ROOT} to ensure relative paths for leaderboard_evaluator_local.py
python ${CARLA_GARAGE_ROOT}/../tools/leaderboard_local/leaderboard_evaluator_local_ext.py \
--host=${HOST} \
--port=${PORT} \
--traffic-manager-port=${TM_PORT} \
--traffic-manager-seed=${TM_SEED} \
--routes=${ROUTES} \
--repetitions=${REPETITIONS} \
--track=${CHALLENGE_TRACK_CODENAME} \
--checkpoint=${CHECKPOINT_ENDPOINT} \
--agent=${TEAM_AGENT} \
--agent-config=${TEAM_CONFIG} \
--debug=${DEBUG_CHALLENGE} \
--resume=${RESUME} \
--timeout=${EVALUATION_TIMEOUT}
