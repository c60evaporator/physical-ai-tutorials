#!/usr/bin/env python3
"""
Batch video generation from Bench2Drive closed-loop evaluation results.

Iterates over all scenario folders inside a given results directory and
calls generate_video_with_plan.py's create_video() for each one.  Videos are written
to <scenario_folder>/output.mp4 by default, or to a separate output
directory if --output-dir is specified.

Usage:
    # Basic — generate videos for all scenarios in the results directory
    python generate_videos_batch.py \
        -d ../../Bench2DriveZoo/work_dirs/closedloop/uniad_traj/eval_multi_uniad_traj

    # With detection overlays
    python generate_videos_batch.py \
        -d ../../Bench2DriveZoo/work_dirs/closedloop/uniad_traj/eval_multi_uniad_traj \
        --show-detections --show-motion --show-map

    # Output to a dedicated directory
    python generate_videos_batch.py \
        -d ../../Bench2DriveZoo/work_dirs/closedloop/uniad_traj/eval_multi_uniad_traj \
        --output-dir ./videos

    # Process only scenarios matching a pattern
    python generate_videos_batch.py \
        -d ../../Bench2DriveZoo/work_dirs/closedloop/uniad_traj/eval_multi_uniad_traj \
        --filter Town12

    # Skip already-generated videos (useful for resuming)
    python generate_videos_batch.py \
        -d ../../Bench2DriveZoo/work_dirs/closedloop/uniad_traj/eval_multi_uniad_traj \
        --skip-existing
"""

import argparse
import os
import sys
import time
import traceback

# ── Add generate_video_with_plan.py's directory to sys.path ──
# generate_video_with_plan.py lives at: Bench2Drive/tools/generate_video_with_plan.py
# This script lives at:       analysis/closed_loop_eval/generate_videos_batch.py
_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
_TOOLS_DIR = os.path.normpath(os.path.join(
    _SCRIPT_DIR, os.pardir, os.pardir, "Bench2Drive", "tools"
))
if _TOOLS_DIR not in sys.path:
    sys.path.insert(0, _TOOLS_DIR)

from generate_video_with_plan import create_video  # type: ignore


def is_scenario_folder(path: str) -> bool:
    """Check if a directory looks like a Bench2Drive scenario result folder."""
    if not os.path.isdir(path):
        return False
    # A valid scenario folder must have at least rgb_front/ and meta/
    return (
        os.path.isdir(os.path.join(path, "rgb_front"))
        and os.path.isdir(os.path.join(path, "meta"))
    )


def collect_scenarios(root: str, pattern: str | None = None) -> list[str]:
    """Return sorted list of scenario folder paths under *root*."""
    scenarios = []
    for name in sorted(os.listdir(root)):
        folder = os.path.join(root, name)
        if not is_scenario_folder(folder):
            continue
        if pattern and pattern not in name:
            continue
        scenarios.append(folder)
    return scenarios


def main():
    parser = argparse.ArgumentParser(
        description="Batch video generation for Bench2Drive closed-loop results",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "-d", "--dir", required=True,
        help="Root directory containing scenario result folders "
             "(e.g. eval_multi_uniad_traj/)",
    )
    parser.add_argument(
        "--output-dir", default=None,
        help="Write videos into this directory instead of each scenario folder. "
             "The video filename will be <scenario_name>.mp4",
    )
    parser.add_argument(
        "--filter", default=None,
        help="Only process scenarios whose folder name contains this substring "
             "(e.g. 'Town12', 'Pedestrian')",
    )
    parser.add_argument(
        "--skip-existing", action="store_true",
        help="Skip scenarios that already have an output video",
    )
    parser.add_argument("--fps", type=int, default=15, help="Video FPS (default: 15)")
    parser.add_argument("--no-plan-overlay", action="store_true",
                        help="Disable planning trajectory overlay on camera views")
    parser.add_argument("--show-detections", action="store_true",
                        help="Overlay 3D detection bounding boxes")
    parser.add_argument("--show-motion", action="store_true",
                        help="Overlay motion prediction trajectories")
    parser.add_argument("--show-map", action="store_true",
                        help="Overlay map segmentation on BEV view")
    parser.add_argument("--det-threshold", type=float, default=0.3,
                        help="Detection score threshold (default: 0.3)")
    args = parser.parse_args()

    root = os.path.abspath(args.dir)
    if not os.path.isdir(root):
        print(f"[ERROR] Directory not found: {root}", file=sys.stderr)
        sys.exit(1)

    scenarios = collect_scenarios(root, args.filter)
    if not scenarios:
        print(f"[WARN] No scenario folders found in: {root}")
        sys.exit(0)

    if args.output_dir:
        os.makedirs(args.output_dir, exist_ok=True)

    # Apply detection threshold globally (same mechanism as generate_video_with_plan.py)
    import generate_video_with_plan as _gv  # type: ignore
    if hasattr(_gv, "DET_SCORE_THRESHOLD"):
        _gv.DET_SCORE_THRESHOLD = args.det_threshold

    total = len(scenarios)
    succeeded = 0
    skipped = 0
    failed_list: list[tuple[str, str]] = []

    print(f"{'=' * 60}")
    print(f" Batch Video Generation")
    print(f" Root   : {root}")
    print(f" Scenes : {total}")
    print(f" FPS    : {args.fps}")
    if args.filter:
        print(f" Filter : {args.filter}")
    if args.output_dir:
        print(f" Output : {args.output_dir}")
    print(f"{'=' * 60}\n")

    t_start = time.time()

    for idx, folder in enumerate(scenarios, 1):
        name = os.path.basename(folder)

        # Determine output path
        if args.output_dir:
            output_video = os.path.join(args.output_dir, f"{name}.mp4")
        else:
            output_video = os.path.join(folder, "output.mp4")

        # Skip if already exists
        if args.skip_existing and os.path.isfile(output_video):
            skipped += 1
            print(f"[{idx}/{total}] SKIP (exists): {name}")
            continue

        print(f"[{idx}/{total}] Processing: {name} ...", end=" ", flush=True)
        t0 = time.time()

        try:
            create_video(
                folder,
                output_video,
                args.fps,
                show_plan_on_cams=(not args.no_plan_overlay),
                show_detections=args.show_detections,
                show_motion=args.show_motion,
                show_map=args.show_map,
            )
            elapsed = time.time() - t0
            succeeded += 1
            print(f"OK ({elapsed:.1f}s)")
        except Exception as e:
            elapsed = time.time() - t0
            failed_list.append((name, str(e)))
            print(f"FAILED ({elapsed:.1f}s): {e}")
            traceback.print_exc()

    total_time = time.time() - t_start

    # ── Summary ──
    print(f"\n{'=' * 60}")
    print(f" Summary")
    print(f"{'=' * 60}")
    print(f" Total     : {total}")
    print(f" Succeeded : {succeeded}")
    print(f" Skipped   : {skipped}")
    print(f" Failed    : {len(failed_list)}")
    print(f" Time      : {total_time:.1f}s ({total_time / 60:.1f}min)")

    if failed_list:
        print(f"\n Failed scenarios:")
        for name, err in failed_list:
            print(f"   - {name}: {err}")

    print()


if __name__ == "__main__":
    main()
