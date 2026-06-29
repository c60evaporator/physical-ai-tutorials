#!/usr/bin/env python3
"""Merge Leaderboard 2.0 eval_*.json files into a single CSV (one row per route).

Usage:
    python merge_route_csv.py <json_dir> [-o OUTPUT_CSV] [--penalty-yaml YAML]

Example:
    python merge_route_csv.py \
        Bench2DriveZoo/work_dirs/closedloop/uniad_traj/tmp \
        -o results.csv
"""

from typing import Any, Dict, List, Tuple
import argparse
import csv
import json
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    yaml = None  # Only needed when --penalty-yaml is used

# ── Default penalty ratios ──────────────────────────────────
DEFAULT_PENALTY = {
    "collisions_layout": 0.65,
    "collisions_pedestrian": 0.50,
    "collisions_vehicle": 0.60,
    "red_light": 0.70,
    "stop_infraction": 0.80,
    "min_speed_infractions": 1.0,
    "yield_emergency_vehicle_infractions": 0.65,
    "scenario_timeouts": 0.70,
}

# Infractions columns in output order
INFRACTION_KEYS = [
    "collisions_layout",
    "collisions_vehicle",
    "red_light",
    "stop_infraction",
    "outside_route_lanes",
    "yield_emergency_vehicle_infractions",
    "scenario_timeouts",
    "route_dev",
    "vehicle_blocked",
    "route_timeout",
    "min_speed_infractions",
]

CSV_COLUMNS = [
    "gpu_index",
    "index",
    "town_name",
    "route_id",
    "scenario_name",
    "weather_id",
    "status",
    "success",
    "score_composed",
    "score_route",
    "score_penalty",
    "score_composed_custom",
    "score_penalty_custom",
    "num_infractions",
    "num_infractions_except_minspeed",
    "route_length",
    "duration_game",
    "duration_system",
    "save_name",
    "outside_route_percentage",
] + [f"infractions_{k}" for k in INFRACTION_KEYS]


def _parse_outside_route_percentage(messages: List[str]) -> float:
    """Extract the deviation percentage from outside_route_lanes messages."""
    total_pct = 0.0
    for msg in messages:
        m = re.search(r"([\d.]+)%", msg)
        if m:
            total_pct += float(m.group(1))
    return total_pct


def compute_custom_penalty(infractions: Dict[str, List[str]], penalty_cfg: Dict[str, float]) -> float:
    """Compute score_penalty_custom from infraction lists and penalty config."""
    score = 1.0
    for key, ratio in penalty_cfg.items():
        n = len(infractions.get(key, []))
        score *= ratio ** n

    # outside_route_lanes: (1 - pct/100) per occurrence
    for msg in infractions.get("outside_route_lanes", []):
        m = re.search(r"([\d.]+)%", msg)
        if m:
            pct = float(m.group(1))
            score *= 1.0 - pct / 100.0

    return score


def process_eval_json(json_path: Path, penalty_cfg: Dict[str, float]) -> List[Dict[str, Any]]:
    """Read one eval_*.json and return a list of row dicts."""
    # Derive gpu_index from filename like eval_0.json -> 0
    stem = json_path.stem  # e.g. "eval_0"
    m = re.search(r"(\d+)$", stem)
    gpu_index = int(m.group(1)) if m else 0

    with open(json_path, "r") as f:
        data = json.load(f)

    records = data.get("_checkpoint", {}).get("records", [])
    rows = []

    for rec in records:
        infractions = rec.get("infractions", {})
        scores = rec.get("scores", {})
        meta = rec.get("meta", {})

        # success: Completed/Perfect AND no infractions except min_speed
        status = rec.get("status", "")
        is_completed = status in ("Completed", "Perfect")
        num_infractions_except_minspeed = sum(
            len(infractions.get(k, []))
            for k in infractions
            if k != "min_speed_infractions"
        )
        success = is_completed and num_infractions_except_minspeed == 0

        # custom penalty
        score_penalty_custom = compute_custom_penalty(infractions, penalty_cfg)
        score_route = scores.get("score_route", 0.0)
        score_composed_custom = score_route * score_penalty_custom

        row = {
            "gpu_index": gpu_index,
            "index": rec.get("index", ""),
            "town_name": rec.get("town_name", ""),
            "route_id": rec.get("route_id", ""),
            "scenario_name": rec.get("scenario_name", ""),
            "weather_id": rec.get("weather_id", ""),
            "status": status,
            "success": success,
            "score_composed": scores.get("score_composed", ""),
            "score_route": score_route,
            "score_penalty": scores.get("score_penalty", ""),
            "score_composed_custom": round(score_composed_custom, 6),
            "score_penalty_custom": round(score_penalty_custom, 6),
            "num_infractions": rec.get("num_infractions", ""),
            "num_infractions_except_minspeed": num_infractions_except_minspeed,
            "route_length": meta.get("route_length", ""),
            "duration_game": meta.get("duration_game", ""),
            "duration_system": meta.get("duration_system", ""),
            "save_name": rec.get("save_name", ""),
            "outside_route_percentage": round(_parse_outside_route_percentage(infractions.get("outside_route_lanes", [])), 2),
            "infractions": infractions,
        }
        rows.append(row)

    return rows

def merge_eval_json(json_dir: str, penalty_cfg: Dict[str, float]) -> Tuple[List[Dict[str, Any]], int]:
    """Merge all eval_*.json files and return (rows, total_planned_routes)."""
    json_dir = Path(json_dir)
    if not json_dir.is_dir():
        print(f"Error: {json_dir} is not a directory", file=sys.stderr)
        sys.exit(1)

    # Collect all eval_*.json
    json_files = sorted(json_dir.glob("eval_*.json"))
    if not json_files:
        print(f"Error: No eval_*.json files found in {json_dir}", file=sys.stderr)
        sys.exit(1)

    all_rows = []
    total_planned = 0
    for jf in json_files:
        with open(jf, "r") as f:
            data = json.load(f)
        progress = data.get("_checkpoint", {}).get("progress", [0, 0])
        total_planned += progress[1] if len(progress) >= 2 else 0
        all_rows.extend(process_eval_json(jf, penalty_cfg))

    # Sort by gpu_index, then index
    all_rows.sort(key=lambda r: (r["gpu_index"], r["index"]))

    return all_rows, total_planned


def calc_global_stats(rows: List[Dict[str, Any]], total_planned: int) -> Dict[str, Any]:
    """Compute global statistics across all routes.

    Args:
        rows: List of row dicts from merge_eval_json (must still contain 'infractions' key).
        total_planned: Total number of planned routes across all GPUs.

    Returns:
        dict with keys: infractions, scores_mean, scores_mean_planned,
                        success_rate, success_rate_planned, meta
    """
    n_completed = len(rows)
    if n_completed == 0:
        return {}

    # ── meta ──
    total_length = 0.0
    duration_game = 0.0
    duration_system = 0.0
    exceptions = []

    for r in rows:
        rl = r.get("route_length", 0) or 0
        total_length += float(rl)
        dg = r.get("duration_game", 0) or 0
        duration_game += float(dg)
        ds = r.get("duration_system", 0) or 0
        duration_system += float(ds)
        status = r.get("status", "")
        if status not in ("Completed", "Perfect"):
            exceptions.append({
                "gpu_index": r.get("gpu_index", ""),
                "index": r.get("index", ""),
                "route_id": r.get("route_id", ""),
                "status": status,
            })

    # ── infractions per km ──
    km_driven = total_length / 1000.0 if total_length > 0 else 1.0
    all_infraction_keys = [
        "collisions_layout", "collisions_pedestrian", "collisions_vehicle",
        "red_light", "stop_infraction", "outside_route_lanes",
        "min_speed_infractions", "yield_emergency_vehicle_infractions",
        "scenario_timeouts", "route_dev", "vehicle_blocked", "route_timeout",
    ]
    infractions_per_km = {}
    for key in all_infraction_keys:
        count = sum(len(r.get("infractions", {}).get(key, [])) for r in rows)
        infractions_per_km[key] = round(count / km_driven, 3)

    # ── scores_mean (denominator = completed routes) ──
    score_keys = ["score_composed", "score_route", "score_penalty",
                  "score_composed_custom", "score_penalty_custom"]
    scores_mean = {}
    for sk in score_keys:
        vals = [float(r[sk]) for r in rows if r.get(sk, "") != ""]
        scores_mean[sk] = round(sum(vals) / len(vals), 6) if vals else 0.0

    # ── scores_mean_planned (denominator = total_planned) ──
    scores_mean_planned = {}
    denom = max(total_planned, 1)
    for sk in score_keys:
        vals = [float(r[sk]) for r in rows if r.get(sk, "") != ""]
        scores_mean_planned[sk] = round(sum(vals) / denom, 6)

    # ── success_rate ──
    n_success = sum(1 for r in rows if r.get("success"))
    success_rate = round(n_success / n_completed, 6) if n_completed > 0 else 0.0
    success_rate_planned = round(n_success / denom, 6)

    return {
        "infractions": infractions_per_km,
        "scores_mean": scores_mean,
        "scores_mean_planned": scores_mean_planned,
        "success_rate": success_rate,
        "success_rate_planned": success_rate_planned,
        "meta": {
            "total_length": round(total_length, 2),
            "duration_game": round(duration_game, 2),
            "duration_system": round(duration_system, 2),
            "n_completed": n_completed,
            "n_planned": total_planned,
            "exceptions": exceptions,
        },
    }

def main():
    parser = argparse.ArgumentParser(description="Merge eval_*.json into CSV")
    parser.add_argument("json_dir", help="Directory containing eval_*.json files")
    parser.add_argument("-o", "--output", default=None, help="Output CSV path (default: <json_dir>/results.csv)")
    parser.add_argument("--penalty-yaml", default=None, help="YAML file with custom penalty_ratio")
    args = parser.parse_args()

    # Load penalty config
    penalty_cfg = dict(DEFAULT_PENALTY)
    if args.penalty_yaml:
        with open(args.penalty_yaml) as f:
            yml = yaml.safe_load(f)
        if "penalty_ratio" in yml:
            for item in yml["penalty_ratio"]:
                if isinstance(item, dict):
                    penalty_cfg.update(item)

    all_rows, total_planned = merge_eval_json(args.json_dir, penalty_cfg)

    # Compute and print global stats
    global_stats = calc_global_stats(all_rows, total_planned)
    print(json.dumps({k: v for k, v in global_stats.items() if k != "meta"}, 
                     indent=2, ensure_ascii=False))

    # Format infraction lists: join multiple messages with ";"
    for row in all_rows:
        for k in INFRACTION_KEYS:
            msgs = row["infractions"].get(k, [])
            row[f"infractions_{k}"] = ";".join(msgs) if msgs else ""
        row.pop("infractions", None)  # Remove original dict

    # Output
    output_path = Path(args.output) if args.output else Path(args.json_dir) / "results.csv"
    with open(output_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=CSV_COLUMNS)
        writer.writeheader()
        writer.writerows(all_rows)

    print(f"Wrote {len(all_rows)} rows to {output_path}")


if __name__ == "__main__":
    main()
