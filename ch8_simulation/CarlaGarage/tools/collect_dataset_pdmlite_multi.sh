#!/bin/bash
# This script is used to collect dataset for PDM-Lite in CarlaGarage.
ROUTES_DIR="${1:?Please specify the routes directory. Usage: $0 <routes_dir>}" # Directory containing route XML files for dataset collection
COLLECTION_ROUTES="$(basename "$(realpath "$ROUTES_DIR")")"  # Use folder name of ROUTES_DIR as route definition name

# Create DATA_SAVE_DIR based on COLLECTION_ROUTES and timestamp
DATA_SAVE_ROOT=${PROJECT_DATA_ROOT:-/workspace/data}/data_collection/carla_garage
CREATE_NEW=${CREATE_NEW:-1}  # If set to 1, create a new timestamped directory; if set to 0, use the latest existing directory.
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
    "${DATA_SAVE_DIR}/results"

# ── Port settings (match launch_carla_servers.sh) ──
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
    
    (
        echo "[GPU ${GPU_RANK}] Processing files index range: ${start_idx} .. $((end_idx - 1))"

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
            echo "[GPU ${GPU_RANK} $(( j - start_idx ))/$((end_idx - start_idx - 1))] ROUTES=${ROUTES}"

            # Launch collect_dataset_pdmlite.sh with `PORT`, `TM_PORT`, `ROUTES`, `TOWN`, `SAVE_PATH`, `CHECKPOINT_ENDPOINT` environment variables
            CUDA_VISIBLE_DEVICES="${GPU_RANK}" \
            HOST=localhost \
            PORT="${PORT}" \
            TM_PORT="${TM_PORT}" \
            ROUTES="${ROUTES}" \
            TOWN="${TOWN}" \
            SAVE_PATH="${SAVE_PATH}" \
            CHECKPOINT_ENDPOINT="${CHECKPOINT_ENDPOINT}" \
            RESUME=1 \
            bash ${CARLA_GARAGE_ROOT}/../tools/collect_dataset_pdmlite.sh

        done
    ) &
done

wait
echo "All dataset collection jobs finished."
