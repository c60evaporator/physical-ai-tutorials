#!/usr/bin/env python
"""External-CARLA evaluator for Bench2Drive.

This thin wrapper subclasses the upstream Bench2Drive ``LeaderboardEvaluator`` and
overrides :meth:`_setup_simulation` so that it connects to an EXTERNALLY-launched
CARLA server (e.g. one started on the host) instead of self-launching
``CarlaUE4.sh``.

The upstream ``carla_garage/Bench2Drive`` repository is left untouched; everything
here is additive and simply imports the upstream class.

Requirements (normally set by ``evaluate_b2d_multi.sh``):
  * ``PYTHONPATH`` must contain Bench2Drive's ``leaderboard`` and ``scenario_runner``
    (NOT the CarlaGarage ones) plus CARLA's PythonAPI.
  * A CARLA server must already be running and reachable at ``--host:--port``.
"""
from __future__ import print_function

# PDM-Lite agent compatibility patches (NumPy compat shim + KinematicBicycleModel fix).
# Importing this module applies the NumPy shim immediately at load time, before any
# Bench2Drive / team_code module can be imported and fail on deprecated aliases.
from pdm_lite_patches import apply_pdm_lite_patches

import argparse
import functools
import inspect
import os
import sys
import time
from argparse import RawTextHelpFormatter

import carla

from leaderboard.leaderboard_evaluator import LeaderboardEvaluator
from leaderboard.utils.statistics_manager import StatisticsManager
from leaderboard.autoagents import agent_wrapper

# Bench2DriveZoo agents (uniad, vad, ...) attach a top-down 'bev' camera at
# z=50m whenever IS_BENCH2DRIVE is set, and their tick() requires it. Upstream
# relaxes the 3m sensor-placement limit only when SAVE_PATH is set
# (visualization mode with per-frame image dumps, which we deliberately keep
# off during evaluation), so relax the limit here instead.
agent_wrapper.MAX_ALLOWED_RADIUS_SENSOR = 100.0


def _install_route_index_setup_patch(module_agent):
    """Feed the per-route ``save_name`` into the agent's ``setup(route_index=...)``.

    The upstream ``LeaderboardEvaluator`` appends ``'+' + save_name`` to
    ``args.agent_config`` and then calls ``agent.setup(agent_config)`` with a
    single positional argument, so ``route_index`` always defaults to ``None``.

    CARLA-garage's ``sensor_agent`` (tfpp) gates *all* of its ``SAVE_PATH``
    output (metric_info.json, target_speeds.json.gz, tp_attention.json.gz and
    the DEBUG_CHALLENGE visualizations) on ``route_index is not None``, so with
    the upstream call it silently writes nothing. We wrap ``setup`` to recover
    ``save_name`` from the ``'+'`` suffix and pass it through as ``route_index``.

    Scope of the patch is kept minimal:
      * only agents whose ``setup`` actually accepts ``route_index`` are touched
        (uniad reads ``SAVE_PATH`` directly and has no such parameter);
      * it is a no-op unless ``SAVE_PATH`` is set, i.e. normal evaluation runs
        are completely unaffected.
    """
    agent_class_name = getattr(module_agent, 'get_entry_point')()
    agent_class = getattr(module_agent, agent_class_name)
    orig_setup = agent_class.setup

    if 'route_index' not in inspect.signature(orig_setup).parameters:
        return  # e.g. uniad: no route_index, saving works via SAVE_PATH already
    if getattr(orig_setup, '_route_index_patched', False):
        return

    @functools.wraps(orig_setup)
    def setup_with_route_index(self, path_to_conf_file, route_index=None, *args, **kwargs):
        if route_index is None and os.environ.get('SAVE_PATH') and '+' in path_to_conf_file:
            route_index = path_to_conf_file.split('+')[-1]
        return orig_setup(self, path_to_conf_file, route_index, *args, **kwargs)

    setup_with_route_index._route_index_patched = True
    agent_class.setup = setup_with_route_index


class ExternalCarlaLeaderboardEvaluator(LeaderboardEvaluator):
    """``LeaderboardEvaluator`` variant that connects to an external CARLA server."""

    def __init__(self, args, statistics_manager):
        """Initialise, then apply team_code compatibility patches.

        ``super().__init__()`` inserts the agent directory onto ``sys.path`` and
        imports the agent module.  Once that is done, ``team_code`` packages
        (kinematic_bicycle_model etc.) become importable, so we apply any patches
        that depend on them here.
        """
        super().__init__(args, statistics_manager)
        apply_pdm_lite_patches()
        # super().__init__ has imported the agent module; patch its setup so the
        # per-route save_name reaches route_index (see helper docstring).
        _install_route_index_setup_patch(self.module_agent)

    def _setup_simulation(self, args):
        """Connect to an already-running CARLA server instead of launching one.

        This mirrors the upstream connect / traffic-manager loops but removes:
          * the ``CarlaUE4.sh`` subprocess launch,
          * the ``find_free_port`` rewrite of ``args.port`` (kept deterministic so it
            matches the externally-launched server),
          * the 60s boot sleep.

        ``self.server`` is set to ``None`` so the upstream crash-cleanup path (which
        greps ``-graphicsadapter=`` and ``kill -9`` the PID) finds nothing to kill.
        """
        # We did NOT launch a server; keep this None for the crash-cleanup path.
        self.server = None

        # Class default (300.0); overridden by args.timeout inside the loop below.
        client_timeout = self.client_timeout

        # ── Connect to the external server and put the world in synchronous mode ──
        attempts = 0
        num_max_restarts = 20
        connected = False
        client = None
        while attempts < num_max_restarts:
            try:
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
                print(f"load_world success (external), attempts={attempts}", flush=True)
                connected = True
                break
            except Exception as e:  # noqa: BLE001 - mirror upstream broad catch
                print(f"load_world failed (external), attempts={attempts}", flush=True)
                print(e, flush=True)
                attempts += 1
                time.sleep(5)

        if not connected:
            raise RuntimeError(
                f"Could not connect to external CARLA server at {args.host}:{args.port}. "
                f"Make sure a CARLA server is running and reachable on that port."
            )

        # ── Traffic manager on the DETERMINISTIC port (no find_free_port) ──
        # Using the caller-provided TM port avoids cross-GPU collisions in parallel runs.
        traffic_manager = client.get_trafficmanager(args.traffic_manager_port)
        traffic_manager.set_synchronous_mode(True)
        traffic_manager.set_hybrid_physics_mode(True)
        print(f"traffic_manager init success on port {args.traffic_manager_port}", flush=True)

        return client, client_timeout, traffic_manager


def main():
    description = "Bench2Drive Leaderboard Evaluation against an EXTERNAL CARLA server.\n"
    parser = argparse.ArgumentParser(description=description, formatter_class=RawTextHelpFormatter)

    # general parameters
    parser.add_argument('--host', default='localhost',
                        help='IP of the running CARLA server (default: localhost)')
    parser.add_argument('--port', default=2000, type=int,
                        help='TCP port of the running CARLA server (default: 2000)')
    parser.add_argument('--traffic-manager-port', default=8000, type=int,
                        help='Port to use for the TrafficManager (default: 8000)')
    parser.add_argument('--traffic-manager-seed', default=0, type=int,
                        help='Seed used by the TrafficManager (default: 0)')
    parser.add_argument('--debug', type=int, default=0,
                        help='Run with debug output')
    parser.add_argument('--record', type=str, default='',
                        help='Use CARLA recording feature to create a recording of the scenario')
    parser.add_argument('--timeout', default=600.0, type=float,
                        help='Set the CARLA client timeout value in seconds')

    # simulation setup
    parser.add_argument('--routes', required=True,
                        help='Name of the routes file to be executed.')
    parser.add_argument('--routes-subset', default='', type=str,
                        help='Execute a specific set of routes')
    parser.add_argument('--repetitions', type=int, default=1,
                        help='Number of repetitions per route.')

    # agent-related options
    parser.add_argument("-a", "--agent", type=str, required=True,
                        help="Path to Agent's py file to evaluate")
    parser.add_argument("--agent-config", type=str, default="",
                        help="Path to Agent's configuration file")

    parser.add_argument("--track", type=str, default='SENSORS',
                        help="Participation track: SENSORS, MAP")
    parser.add_argument('--resume', type=bool, default=False,
                        help='Resume execution from last checkpoint?')
    parser.add_argument("--checkpoint", type=str, default='./simulation_results.json',
                        help="Path to checkpoint used for saving statistics and resuming")
    parser.add_argument("--debug-checkpoint", type=str, default='./live_results.txt',
                        help="Path to checkpoint used for saving live results")
    parser.add_argument("--gpu-rank", type=int, default=0,
                        help="GPU rank. Only used for CUDA_VISIBLE_DEVICES at the shell level; "
                             "the external server is selected via --host/--port.")

    arguments = parser.parse_args()

    statistics_manager = StatisticsManager(arguments.checkpoint, arguments.debug_checkpoint)
    evaluator = ExternalCarlaLeaderboardEvaluator(arguments, statistics_manager)
    crashed = evaluator.run(arguments)

    del evaluator

    sys.exit(-1 if crashed else 0)


if __name__ == '__main__':
    main()
