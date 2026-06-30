#!/bin/bash
export HOST=${CARLA_HOST:-localhost}
export PORT=${CARLA_PORT:-2000}
export TM_PORT=${TM_PORT:-8000}
export TM_SEED=${TM_SEED:-0}

export LEADERBOARD_ROOT=${CARLA_GARAGE_ROOT}/leaderboard_autopilot
export SCENARIO_RUNNER_ROOT=${CARLA_GARAGE_ROOT}/scenario_runner_autopilot
# Rebuild PYTHONPATH explicitly so imports resolve to autopilot variants.
export PYTHONPATH=${CARLA_ROOT:-/workspace/carla}/PythonAPI/carla:${LEADERBOARD_ROOT}:${SCENARIO_RUNNER_ROOT}:${PYTHONPATH}

export ROUTES=${ROUTES:-$CARLA_GARAGE_ROOT/data/lb1_split/ControlLoss/Town01_Scenario1_0.xml}  # Route definition XML file
export TEAM_AGENT=${CARLA_GARAGE_ROOT}/team_code/data_agent.py  # PDM-Lite agent
export TEAM_CONFIG=${ROUTES}
export REPETITIONS=${REPETITIONS:-1} # multiple evaluation runs (1 means no repetition, 2 means each route is run twice, etc.)

export DEBUG_CHALLENGE=0
# Use a script-local override variable to avoid inheriting container default CHALLENGE_TRACK_CODENAME=SENSORS.
export CHALLENGE_TRACK_CODENAME=${DATASET_TRACK_CODENAME:-MAP} # SENSORS, MAP, SENSORS_QUALIFIER, MAP_QUALIFIER
export CHECKPOINT_ENDPOINT=${CHECKPOINT_ENDPOINT:-${PROJECT_DATA_ROOT:-/workspace/data}/data_collection/carla_garage/tmp/result.json}
export RESUME=${RESUME:-0}
export EVALUATION_TIMEOUT=${EVALUATION_TIMEOUT:-600} # seconds

export DATAGEN=1
export TOWN=${TOWN:-Town01}
export SAVE_PATH=${SAVE_PATH:-${PROJECT_DATA_ROOT:-/workspace/data}/data_collection/carla_garage/tmp/dataset_pdmlite}
export REPETITION=${REPETITION:-0} # Repetition count (Smaller than REPETITIONS, used for saving dataset in different folders)

cd "${CARLA_GARAGE_ROOT}" # Move to ${CARLA_GARAGE_ROOT} to ensure relative paths for leaderboard_evaluator_local.py
python ${LEADERBOARD_ROOT}/leaderboard/leaderboard_evaluator_local.py \
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
