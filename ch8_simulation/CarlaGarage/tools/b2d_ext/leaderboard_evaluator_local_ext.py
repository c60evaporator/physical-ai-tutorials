#!/usr/bin/env python
"""CarlaGarage local-evaluator wrapper with TM-port race-condition fix.

This thin wrapper subclasses CarlaGarage's ``LeaderboardEvaluator`` (from
``leaderboard_evaluator_local.py``) and overrides ``_setup_simulation`` to fix
a TOCTOU race when multiple GPU processes call ``find_free_port()``
simultaneously.

Problem
-------
The original ``_setup_simulation`` calls ``self.find_free_port()`` with the
default ``start_port=2000``, ignoring ``--traffic-manager-port``.  When N GPU
processes start concurrently, all begin scanning from port 2000.
``find_free_port`` probes by *binding* a temporary socket, then *closing* it
before returning the number.  Between the close and CARLA's actual bind, another
process can claim the same port → ``RuntimeError: bind error``.

Fix
---
Pass ``args.traffic_manager_port`` as the scan start so each GPU process
searches a non-overlapping range (e.g. GPU0 starts at 8000, GPU1 at 8150, …).
``collect_dataset.sh`` already passes ``--traffic-manager-port=BASE+i*STEP``,
so no shell-side changes are needed beyond pointing at this entry point.

Usage (set in collect_dataset.sh)
----------------------------------
    python tools/b2d_ext/leaderboard_evaluator_local_ext.py \\
        --traffic-manager-port=<BASE+i*STEP> \\
        <other args>
"""
from __future__ import print_function

import sys
import os

# ── Ensure leaderboard_autopilot is importable ────────────────────────────────
# collect_dataset.sh sets LEADERBOARD_ROOT and PYTHONPATH before calling us,
# so all CarlaGarage leaderboard imports resolve normally.
# ─────────────────────────────────────────────────────────────────────────────
from leaderboard.leaderboard_evaluator_local import LeaderboardEvaluator
import leaderboard.leaderboard_evaluator_local as _orig_module


class _PatchedLeaderboardEvaluator(LeaderboardEvaluator):
    """Drop-in replacement that fixes the find_free_port TOCTOU race."""

    def _setup_simulation(self, args):
        """Override: start find_free_port scan at args.traffic_manager_port.

        All other behaviour (carla.Client connect, WorldSettings, TM sync mode)
        is preserved unchanged.  By starting the scan at the caller-supplied
        port, each GPU process searches a different range and cannot collide.
        """
        import carla  # noqa: PLC0415 — imported here to mirror original structure

        client = carla.Client(args.host, args.port)
        if args.timeout:
            client_timeout = args.timeout
        client.set_timeout(client_timeout)

        settings = carla.WorldSettings(
            synchronous_mode=True,
            fixed_delta_seconds=1.0 / self.frame_rate,
            deterministic_ragdolls=True,
            spectator_as_ego=False,
        )
        client.get_world().apply_settings(settings)

        # Fix: use args.traffic_manager_port as the scan start so each GPU
        # process searches in a non-overlapping range.
        # collect_dataset_multi.sh passes  BASE_TM_PORT + i * PORT_STEP so the
        # ranges are naturally separate (e.g. 8000, 8150, 8300, …).
        traffic_manager_port = self.find_free_port(
            start_port=args.traffic_manager_port
        )
        traffic_manager = client.get_trafficmanager(traffic_manager_port)
        traffic_manager.set_synchronous_mode(True)
        traffic_manager.set_hybrid_physics_mode(True)

        return client, client_timeout, traffic_manager, traffic_manager_port


def main():
    """Entry point: patch the class then delegate to the original main()."""
    # Monkey-patch the module-level class so that all code inside
    # leaderboard_evaluator_local.py (including main()) uses the fixed class.
    _orig_module.LeaderboardEvaluator = _PatchedLeaderboardEvaluator
    _orig_module.main()


if __name__ == "__main__":
    main()
