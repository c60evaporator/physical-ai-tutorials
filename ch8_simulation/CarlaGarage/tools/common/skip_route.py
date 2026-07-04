"""Force-skip a stuck route in the Bench2Drive leaderboard checkpoint file.

When a route causes repeated CARLA hard-crashes (e.g. a C++ ``std::terminate``
triggered by ``spawn_parked_vehicles``), the Python process is killed before it
can advance ``_checkpoint.progress[0]``.  This script:

1. Reads the checkpoint JSON.
2. Resolves the stuck route index from ``_checkpoint.progress[0]``.
3. Parses the routes XML to extract route metadata (id, town, scenario, weather).
4. Inserts a ``"Failed - Simulation crashed"`` record for that index.
5. Advances ``progress[0]`` by 1 so the evaluator resumes from the next route.

Called automatically from ``evaluate_b2d_multi.sh`` when stuck-route detection
fires (``MAX_STUCK`` consecutive non-advancing crashes on the same route index).

Usage::

    python skip_route.py <checkpoint_json> <routes_xml>
"""

from __future__ import annotations

import json
import sys
import xml.etree.ElementTree as ET
from datetime import datetime
from pathlib import Path


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

def _parse_route_info(routes_xml: str | Path, route_index: int) -> dict[str, str]:
    """Return metadata for the route at the given 0-based *route_index*.

    Returns a dict with keys ``route_id``, ``town``, ``scenario_name``,
    ``weather_id``.  Falls back to safe defaults on any parse error.
    """
    fallback = {
        "route_id": str(route_index),
        "town": "Unknown",
        "scenario_name": "Unknown",
        "weather_id": "0",
    }
    try:
        root = ET.parse(routes_xml).getroot()
        routes = list(root.iter("route"))
    except Exception as exc:  # noqa: BLE001
        print(f"[skip_route] Warning: cannot parse '{routes_xml}': {exc}")
        return fallback

    if route_index >= len(routes):
        print(
            f"[skip_route] Warning: route_index={route_index} is out of range "
            f"(routes in XML: {len(routes)})"
        )
        return fallback

    elem = routes[route_index]
    scenarios = list(elem.iter("scenario"))
    weathers = list(elem.iter("weather"))

    return {
        "route_id": elem.attrib.get("id", str(route_index)),
        "town": elem.attrib.get("town", "Unknown"),
        "scenario_name": (
            scenarios[0].attrib.get("name", "NoScenario") if scenarios else "NoScenario"
        ),
        "weather_id": str(weathers[0].attrib.get("id", "0")) if weathers else "0",
    }


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def skip_stuck_route(checkpoint_path: str | Path, routes_xml: str | Path) -> None:
    """Insert a dummy failure record for the stuck route and advance progress.

    Modifies *checkpoint_path* in-place.  Idempotent: an existing partial
    record for the stuck index is removed before inserting the dummy.
    """
    checkpoint_path = Path(checkpoint_path)

    with checkpoint_path.open() as f:
        checkpoint = json.load(f)

    cp = checkpoint["_checkpoint"]
    stuck_index: int = cp["progress"][0]
    total: int = cp["progress"][1]

    print(f"[skip_route] Stuck at route index {stuck_index}/{total}.")

    info = _parse_route_info(routes_xml, stuck_index)
    route_id_str = f"RouteScenario_{info['route_id']}_rep0"
    ts = datetime.now().strftime("%y_%m_%d_%H_%M_%S")
    save_name = (
        f"{route_id_str}_{info['town']}_{info['scenario_name']}"
        f"_{info['weather_id']}_{ts}"
    )

    dummy: dict = {
        "index": stuck_index,
        "route_id": route_id_str,
        "scenario_name": info["scenario_name"],
        "weather_id": info["weather_id"],
        "save_name": save_name,
        "status": "Failed - Simulation crashed",
        "num_infractions": 0,
        "infractions": {
            "collisions_layout": [],
            "collisions_pedestrian": [],
            "collisions_vehicle": [],
            "red_light": [],
            "stop_infraction": [],
            "outside_route_lanes": [],
            "min_speed_infractions": [],
            "yield_emergency_vehicle_infractions": [],
            "scenario_timeouts": [],
            "route_dev": [],
            "vehicle_blocked": ["Simulation crashed — route force-skipped"],
            "route_timeout": [],
        },
        "scores": {
            "score_route": 0.0,
            "score_penalty": 1.0,
            "score_composed": 0.0,
        },
        "meta": {
            "route_length": 0.0,
            "duration_game": 0.0,
            "duration_system": 0.0,
        },
        "town_name": info["town"],
    }

    # Remove any partial record for this index, then append the dummy.
    records: list = cp.get("records", [])
    records = [r for r in records if r.get("index") != stuck_index]
    records.append(dummy)
    records.sort(key=lambda r: r.get("index", 0))

    cp["records"] = records
    cp["progress"][0] = stuck_index + 1

    with checkpoint_path.open("w") as f:
        json.dump(checkpoint, f, indent=4)

    print(
        f"[skip_route] Done. Dummy record inserted for {route_id_str}. "
        f"Progress advanced to {stuck_index + 1}/{total}."
    )


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: skip_route.py <checkpoint_json> <routes_xml>", file=sys.stderr)
        sys.exit(1)
    skip_stuck_route(sys.argv[1], sys.argv[2])
