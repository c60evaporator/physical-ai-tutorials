"""PDM-Lite (Bench2Drive team_code) compatibility patches.

This module applies NumPy >= 1.24 compatibility fixes specific to the PDM-Lite
agent (``autopilot.py`` and the ``KinematicBicycleModel`` it relies on).

Usage pattern (inside ``leaderboard_evaluator_b2d_ext.py``)::

    # At module level — runs the NumPy shim before any team_code import:
    from pdm_lite_patches import apply_pdm_lite_patches

    # After LeaderboardEvaluator.__init__ has loaded the agent module:
    apply_pdm_lite_patches()

Two distinct fixes are provided:

1. **NumPy compat shim** (module-level, applied at import time):
   Bench2Drive ``team_code`` uses deprecated NumPy type aliases
   (``np.float``, ``np.bool``, ``np.int``, etc.) that were removed in NumPy
   1.24.  The shim restores them to their built-in equivalents so that
   ``team_code`` imports do not raise ``AttributeError``.

2. **KinematicBicycleModel.forecast_ego_vehicle replacement** (applied by
   :func:`apply_pdm_lite_patches` at runtime):
   The original implementation builds ``np.array([shape-(1,), ..., scalar, ...])``
   which is a heterogeneous array — rejected by NumPy >= 1.24.  The replacement
   squeezes all inputs to plain Python floats, rebuilds the polynomial feature
   vectors from homogeneous scalars, and restores the ``(3,) / (1,) / (1,)``
   output shapes expected by the caller.
"""

# ── NumPy compatibility shim ──────────────────────────────────────────────────
# Applied at module-import time so all subsequent Bench2Drive / team_code
# imports see the restored aliases.
import numpy as np

_NP_COMPAT = {
    "float":   float,
    "int":     int,
    "bool":    bool,
    "complex": complex,
    "object":  object,
    "str":     str,
}
for _alias, _builtin in _NP_COMPAT.items():
    if not hasattr(np, _alias):
        setattr(np, _alias, _builtin)
# ─────────────────────────────────────────────────────────────────────────────


def apply_pdm_lite_patches():
    """Patch PDM-Lite team_code for NumPy >= 1.24 compatibility.

    Must be called *after* the agent module has been imported (i.e. after
    ``LeaderboardEvaluator.__init__`` has run) so that
    ``kinematic_bicycle_model`` is importable from ``sys.path``.

    The function is idempotent: calling it multiple times is safe.
    """
    try:
        from kinematic_bicycle_model import KinematicBicycleModel  # noqa: PLC0415

        if getattr(KinematicBicycleModel.forecast_ego_vehicle, '_ext_patched', False):
            return  # already patched

        def _fixed(self, location, heading, speed, action):
            # --- Squeeze all array inputs to plain Python floats ---
            speed_s    = float(np.asarray(speed).flat[0])
            heading_s  = float(np.asarray(heading).flat[0])
            steer_s    = float(np.asarray(action[0]).flat[0])
            throttle_s = float(np.asarray(action[1]).flat[0])
            brake_s    = float(np.asarray(action[2]).flat[0])

            # --- Bicycle model kinematics ----------------------------------
            wheel_angle = self.steering_gain * steer_s
            slip_angle  = float(np.arctan(
                self.rear_wheel_base
                / (self.front_wheel_base + self.rear_wheel_base)
                * np.tan(wheel_angle)
            ))

            next_x       = float(location[0]) + speed_s * np.cos(heading_s + slip_angle) * self.time_step
            next_y       = float(location[1]) + speed_s * np.sin(heading_s + slip_angle) * self.time_step
            next_heading = heading_s + speed_s / self.rear_wheel_base * np.sin(slip_angle) * self.time_step

            # --- Speed polynomial model ------------------------------------
            if brake_s:
                speed_kph  = speed_s * 3.6
                features   = speed_kph ** np.arange(1, 8)     # shape (7,) — homogeneous
                next_speed = float(features @ self.brake_values) / 3.6
            else:
                throttle_c = float(np.clip(throttle_s, 0.0, 1.0))
                if throttle_c < self.throttle_threshold_during_forecasting:
                    next_speed = speed_s
                else:
                    speed_kph  = speed_s * 3.6
                    features   = np.array([                    # shape (8,) — all plain scalars
                        speed_kph,
                        speed_kph ** 2,
                        throttle_c,
                        throttle_c ** 2,
                        speed_kph * throttle_c,
                        speed_kph * throttle_c ** 2,
                        speed_kph ** 2 * throttle_c,
                        speed_kph ** 2 * throttle_c ** 2,
                    ])
                    next_speed = float(features @ self.throttle_values) / 3.6

            next_speed    = max(0.0, next_speed)
            next_location = np.array([float(next_x), float(next_y), float(location[2])])

            # Return (1,) shapes for heading/speed so that the caller's
            # ``heading_angle.item()`` and downstream array operations keep
            # working unchanged.
            return next_location, np.array([next_heading]), np.array([next_speed])

        _fixed._ext_patched = True
        KinematicBicycleModel.forecast_ego_vehicle = _fixed
        print("[pdm_lite_patches] KinematicBicycleModel.forecast_ego_vehicle patched.", flush=True)

    except ImportError:
        pass  # team_code not yet on sys.path — skip silently
