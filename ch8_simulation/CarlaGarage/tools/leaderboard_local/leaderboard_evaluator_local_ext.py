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

Usage (set in leaderboard_local/collect_dataset.sh and leaderboard_local/evaluate_leaderboard.sh)
--------------------------------------------------------------------------------------------------
    python tools/leaderboard_local/leaderboard_evaluator_local_ext.py \\
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
    """Drop-in replacement that fixes the find_free_port TOCTOU race and
    re-applies the synchronous world settings after every world load."""

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

    def _load_and_wait_for_world(self, args, town):
        """Override: re-apply the synchronous world settings after load_world.

        The original only applies synchronous_mode / fixed_delta_seconds once in
        ``_setup_simulation``, but CARLA (sometimes) resets world settings when
        loading a Large Map (Town12/13) even with ``reset_settings=False`` — the
        original itself re-applies the tile streaming distances for this reason.
        When the synchronous settings are lost, sensor setup later crashes with
        ``TypeError: 1 / fixed_delta_seconds`` (None) in agent_wrapper_local.py.
        Re-applying the full settings after every world load (as the official
        leaderboard does) makes this deterministic. The rest of the body is
        copied unchanged from leaderboard_evaluator_local.py.
        """
        import random  # noqa: PLC0415 — imported here to mirror original structure
        import numpy as np  # noqa: PLC0415
        import torch  # noqa: PLC0415
        from srunner.scenariomanager.carla_data_provider import CarlaDataProvider  # noqa: PLC0415

        self.world = self.client.load_world(town, reset_settings=False)

        # Large Map loads can reset the world settings; re-apply all of them,
        # not just the tile streaming distances.
        settings = self.world.get_settings()
        settings.synchronous_mode = True
        settings.fixed_delta_seconds = 1.0 / self.frame_rate
        settings.deterministic_ragdolls = True
        settings.spectator_as_ego = False
        settings.tile_stream_distance = 650
        settings.actor_active_distance = 650
        self.world.apply_settings(settings)

        self.world.reset_all_traffic_lights()
        CarlaDataProvider.set_client(self.client)
        CarlaDataProvider.set_traffic_manager_port(self.traffic_manager_port)
        CarlaDataProvider.set_world(self.world)
        CarlaDataProvider.set_random_seed(args.traffic_manager_seed)

        # This must be here so that all route repetitions use the same 'unmodified' seed
        self.traffic_manager.set_random_device_seed(args.traffic_manager_seed)
        np.random.seed(args.traffic_manager_seed)
        random.seed(args.traffic_manager_seed)
        torch.manual_seed(args.traffic_manager_seed)

        # Wait for the world to be ready
        self.world.tick()

        map_name = CarlaDataProvider.get_map().name.split("/")[-1]
        if map_name != town:
            raise Exception("The CARLA server uses the wrong map!"
                            " This scenario requires the use of map {}".format(town))


def main():
    """Entry point: patch the class then delegate to the original main()."""
    # Monkey-patch the module-level class so that all code inside
    # leaderboard_evaluator_local.py (including main()) uses the fixed class.
    _orig_module.LeaderboardEvaluator = _PatchedLeaderboardEvaluator
    _orig_module.main()


if __name__ == "__main__":
    main()
