#!/usr/bin/env python3
"""Convert a PDM-Lite nuScenes-rig collection run to a nuScenes v1.0 dataset.

Input: a run directory produced by `collect_dataset_multi.sh <routes> pdmlite_nuscenes`
(DataAgentNuScenes with COORDINATE_SYSTEM='nuscenes' / LIDAR_FORMAT='pcd_bin'):

    <run_dir>/data/<scenario>/<Town>_Rep<r>_<route>_route<i>_<MM_DD_HH_MM_SS>/
        CAM_FRONT/0000.jpg ... LIDAR_TOP/0000.pcd.bin
        boxes/0000.json.gz            (right-handed, global 'matrix', num_points)
        sensor_calibration.json       (nuScenes-convention translation/quaternion)
        results.json.gz               (route status / scores)

Output: nuScenes folder layout (metadata JSONs under <output>/<version>/, sensor
files hard-linked or copied into samples/<CH>/ and sweeps/<CH>/ with nuScenes
naming `<scene>__<CH>__<timestamp>`).

Conversion decisions (agreed design):
  * 1 route folder = 1 scene; duplicated attempt folders of the same route are
    reduced to one via --attempt-policy (prefer-complete | complete-only).
  * log = run x Town (location = Town name); map.json entries are placeholders
    to be filled by the future OpenDRIVE -> map expansion conversion.
  * Keyframes (samples) every --sample-interval frames (default 2 = 2 Hz for the
    4 Hz collection); the remaining frames become sweeps. Annotations are
    created for keyframes only.
  * Timestamps: base epoch from the route folder date (year taken from the run
    dir name) + frame_index * FRAME_PERIOD_US.
  * Global coordinates keep the (right-handed) CARLA world origin unless a
    per-town offset is supplied via --origin-offset (must match the offset used
    when generating the nuScenes map for that town).
  * visibility is a heuristic binning of the LiDAR hit count; the exact count
    is stored in sample_annotation.num_lidar_pts (the field UniAD-style
    pipelines actually filter on).
  * annotation translation is the actor origin shifted by +extent_z along the
    actor's up axis: CARLA actor origins sit at ground level while nuScenes
    boxes are centered; the exact bounding-box center offset is not recorded
    during collection, so this is a documented approximation.

Usage:
    python tools/convert_to_nuscenes.py <run_dir> <output_dir> \
        [--version v1.0-trainval] [--sample-interval 2] \
        [--link-mode hardlink|copy] [--origin-offset Town13=X,Y ...] \
        [--attempt-policy prefer-complete|complete-only]
"""

import argparse
import gzip
import hashlib
import json
import os
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path

import numpy as np

# Collection runs at 20 Hz simulation with data_save_freq=5 -> 4 Hz frames.
FRAME_PERIOD_US = 250_000

CAMERA_WIDTH = 1600
CAMERA_HEIGHT = 900

# CARLA blueprint substring -> nuScenes category. Checked in order; the first
# match wins. Plain cars fall through to the default 'vehicle.car'.
VEHICLE_CATEGORY_RULES = [
    ('crossbike', 'vehicle.bicycle'),
    ('diamondback', 'vehicle.bicycle'),
    ('omafiets', 'vehicle.bicycle'),
    ('harley-davidson', 'vehicle.motorcycle'),
    ('kawasaki', 'vehicle.motorcycle'),
    ('vespa', 'vehicle.motorcycle'),
    ('yamaha', 'vehicle.motorcycle'),
    ('firetruck', 'vehicle.truck'),
    ('carlacola', 'vehicle.truck'),
    ('european_hgv', 'vehicle.truck'),
    ('cybertruck', 'vehicle.truck'),
    ('sprinter', 'vehicle.truck'),
    ('t2', 'vehicle.truck'),
    ('fusorosa', 'vehicle.bus.rigid'),
    ('ambulance', 'vehicle.emergency.ambulance'),
    ('police', 'vehicle.emergency.police'),
]
DEFAULT_VEHICLE_CATEGORY = 'vehicle.car'

CATEGORIES = [
    ('vehicle.car', 'Vehicle designed primarily for personal use.'),
    ('vehicle.truck', 'Vehicle primarily designed to haul cargo.'),
    ('vehicle.bus.rigid', 'Rigid bus.'),
    ('vehicle.bicycle', 'Human or electric powered 2-wheeled vehicle.'),
    ('vehicle.motorcycle', 'Gasoline or electric powered 2-wheeled vehicle.'),
    ('vehicle.emergency.ambulance', 'Ambulance vehicle.'),
    ('vehicle.emergency.police', 'Police vehicle.'),
    ('human.pedestrian.adult', 'Adult pedestrian.'),
]

ATTRIBUTES = [
    ('vehicle.moving', 'Vehicle is moving.'),
    ('vehicle.stopped', 'Vehicle, with a driver/rider in/on it, is currently stationary.'),
    ('vehicle.parked', 'Vehicle is stationary (usually for longer duration) with no immediate intent to move.'),
    ('cycle.with_rider', 'There is a rider on the bicycle or motorcycle.'),
    ('pedestrian.moving', 'The human is moving.'),
    ('pedestrian.standing', 'The human is standing.'),
]

VISIBILITIES = [
    ('1', 'v0-40', 'visibility of whole object is between 0 and 40%'),
    ('2', 'v40-60', 'visibility of whole object is between 40 and 60%'),
    ('3', 'v60-80', 'visibility of whole object is between 60 and 80%'),
    ('4', 'v80-100', 'visibility of whole object is between 80 and 100%'),
]


def token(*parts):
    """Deterministic 32-hex-digit nuScenes token from string parts."""
    return hashlib.md5('|'.join(str(p) for p in parts).encode('utf-8')).hexdigest()


def matrix_to_quaternion(m):
    """Rotation matrix -> quaternion [w, x, y, z] (same algorithm as
    GeneralizedDataAgent._matrix_to_quaternion in team_code/data_agents)."""
    trace = m[0][0] + m[1][1] + m[2][2]
    if trace > 0.0:
        s = np.sqrt(trace + 1.0) * 2.0
        w, x, y, z = 0.25 * s, (m[2][1] - m[1][2]) / s, (m[0][2] - m[2][0]) / s, (m[1][0] - m[0][1]) / s
    elif m[0][0] > m[1][1] and m[0][0] > m[2][2]:
        s = np.sqrt(1.0 + m[0][0] - m[1][1] - m[2][2]) * 2.0
        w, x, y, z = (m[2][1] - m[1][2]) / s, 0.25 * s, (m[0][1] + m[1][0]) / s, (m[0][2] + m[2][0]) / s
    elif m[1][1] > m[2][2]:
        s = np.sqrt(1.0 + m[1][1] - m[0][0] - m[2][2]) * 2.0
        w, x, y, z = (m[0][2] - m[2][0]) / s, (m[0][1] + m[1][0]) / s, 0.25 * s, (m[1][2] + m[2][1]) / s
    else:
        s = np.sqrt(1.0 + m[2][2] - m[0][0] - m[1][1]) * 2.0
        w, x, y, z = (m[1][0] - m[0][1]) / s, (m[0][2] + m[2][0]) / s, (m[1][2] + m[2][1]) / s, 0.25 * s
    return [float(w), float(x), float(y), float(z)]


def load_json_gz(path):
    with gzip.open(path, 'rt', encoding='utf-8') as f:
        return json.load(f)


def category_for_box(box):
    """Return (category_name, is_parked) for an annotation box, or None to skip."""
    cls = box['class']
    if cls == 'car':
        type_id = box.get('type_id', '')
        for needle, category in VEHICLE_CATEGORY_RULES:
            if needle in type_id:
                return category, False
        return DEFAULT_VEHICLE_CATEGORY, False
    if cls == 'walker':
        return 'human.pedestrian.adult', False
    if cls == 'static':
        # Parked vehicles are spawned as static props; other static props
        # (and traffic lights / stop signs) are not annotated.
        mesh_path = box.get('mesh_path') or ''
        if 'Car' in mesh_path:
            return DEFAULT_VEHICLE_CATEGORY, True
        return None
    return None  # ego_car, traffic_light, stop_sign, ...


def attribute_for_box(category, is_parked, speed):
    if category.startswith('vehicle.bicycle') or category.startswith('vehicle.motorcycle'):
        return 'cycle.with_rider'
    if category.startswith('vehicle'):
        if is_parked:
            return 'vehicle.parked'
        return 'vehicle.moving' if abs(speed) > 0.5 else 'vehicle.stopped'
    if category.startswith('human'):
        return 'pedestrian.moving' if abs(speed) > 0.2 else 'pedestrian.standing'
    return None


def visibility_for_points(num_points):
    if num_points <= 10:
        return '1'
    if num_points <= 30:
        return '2'
    if num_points <= 80:
        return '3'
    return '4'


def parse_origin_offsets(items):
    """['Town13=100.0,200.0', ...] -> {'Town13': (100.0, 200.0)}"""
    offsets = {}
    for item in items or []:
        try:
            town, values = item.split('=')
            x, y = (float(v) for v in values.split(','))
        except ValueError:
            sys.exit(f"Invalid --origin-offset '{item}' (expected TownXX=X,Y)")
        offsets[town] = (x, y)
    return offsets


def discover_scenes(run_dir, attempt_policy):
    """Group route folders by route identity and pick one folder per route.

    Folder name: <Town>_Rep<r>_<route>_<sub>_route<i>_<MM>_<DD>_<HH>_<MM>_<SS>
    The last 5 underscore-separated fields are the date; the rest identifies
    the route (retries of the same route only differ in the date).
    """
    scenes = []
    skipped_incomplete = 0
    for scenario_dir in sorted((run_dir / 'data').iterdir()):
        if not scenario_dir.is_dir():
            continue
        routes = {}
        for folder in sorted(scenario_dir.iterdir()):
            if not folder.is_dir():
                continue
            parts = folder.name.split('_')
            if len(parts) < 6:
                print(f'[warn] Unrecognized folder name, skipping: {folder}')
                continue
            route_key = '_'.join(parts[:-5])
            routes.setdefault(route_key, []).append(folder)

        for route_key, folders in sorted(routes.items()):
            completed, partial = [], []
            for folder in folders:
                status = None
                results_file = folder / 'results.json.gz'
                if results_file.exists():
                    try:
                        status = load_json_gz(results_file).get('status')
                    except Exception:
                        pass
                (completed if status == 'Completed' else partial).append(folder)

            if completed:
                # Multiple completed attempts should not happen; take the latest.
                chosen = completed[-1]
            elif attempt_policy == 'complete-only':
                skipped_incomplete += 1
                continue
            else:  # prefer-complete: fall back to the attempt with the most frames
                chosen = max(partial, key=lambda f: len(list((f / 'boxes').glob('*.json.gz'))))

            town = chosen.name.split('_')[0]  # NOTE: truncates towns with '_' (e.g. Town10HD_Opt)
            scenes.append({
                'scenario': scenario_dir.name,
                'route_key': route_key,
                'name': f'{scenario_dir.name}_{route_key}',
                'path': chosen,
                'town': town,
                'date_parts': chosen.name.split('_')[-5:],
            })
    return scenes, skipped_incomplete


def common_frames(scene_path, channels):
    """Sorted frame indices present in boxes/ and every sensor channel."""
    frames = {int(p.name.split('.')[0]) for p in (scene_path / 'boxes').glob('*.json.gz')}
    for channel, ext in channels:
        frames &= {int(p.name.split('.')[0]) for p in (scene_path / channel).glob(f'*{ext}')}
    return sorted(frames)


def base_timestamp_us(run_dir_name, date_parts):
    """Route folder date (MM_DD_HH_MM_SS) + year from the run dir name -> epoch µs."""
    digits = ''.join(c for c in run_dir_name if c.isdigit())
    year = int(digits[:4]) if len(digits) >= 4 else datetime.now().year
    month, day, hour, minute, second = (int(p) for p in date_parts)
    dt = datetime(year, month, day, hour, minute, second, tzinfo=timezone.utc)
    return int(dt.timestamp() * 1_000_000)


def place_file(src, dst, link_mode):
    dst.parent.mkdir(parents=True, exist_ok=True)
    if dst.exists():
        dst.unlink()
    if link_mode == 'hardlink':
        try:
            os.link(src, dst)
            return
        except OSError:
            pass  # cross-device etc. -> fall back to copy
    shutil.copy2(src, dst)


def convert(args):
    run_dir = Path(args.run_dir).resolve()
    out_dir = Path(args.output_dir).resolve()
    origin_offsets = parse_origin_offsets(args.origin_offset)

    scenes, skipped_incomplete = discover_scenes(run_dir, args.attempt_policy)
    if not scenes:
        sys.exit(f'No route folders found under {run_dir}/data')

    # Sensor channels from the first scene's calibration; the rig is identical
    # across scenes of a run (same agent class).
    reference_calibration = json.loads((scenes[0]['path'] / 'sensor_calibration.json').read_text())
    if reference_calibration.get('coordinate_system') != 'nuscenes':
        sys.exit("sensor_calibration.json coordinate_system is not 'nuscenes'. "
                 "Collect with DataAgentNuScenes (COORDINATE_SYSTEM='nuscenes') first.")
    camera_channels = sorted(reference_calibration['cameras'])
    lidar_channels = sorted(reference_calibration.get('lidars', {}))
    channels = [(c, '.jpg') for c in camera_channels] + [(c, '.pcd.bin') for c in lidar_channels]

    tables = {name: [] for name in (
        'log', 'map', 'scene', 'sample', 'sample_data', 'sample_annotation',
        'instance', 'ego_pose', 'calibrated_sensor', 'sensor')}
    tables['category'] = [{'token': token('category', n), 'name': n, 'description': d} for n, d in CATEGORIES]
    tables['attribute'] = [{'token': token('attribute', n), 'name': n, 'description': d} for n, d in ATTRIBUTES]
    tables['visibility'] = [{'token': t, 'level': lv, 'description': d} for t, lv, d in VISIBILITIES]
    category_tokens = {row['name']: row['token'] for row in tables['category']}
    attribute_tokens = {row['name']: row['token'] for row in tables['attribute']}

    for channel, _ in channels:
        tables['sensor'].append({
            'token': token('sensor', channel),
            'channel': channel,
            'modality': 'lidar' if channel in lidar_channels else 'camera',
        })

    run_name = run_dir.name
    log_tokens = {}   # town -> token
    map_logs = {}     # town -> [log tokens]
    date_captured = None

    for scene in scenes:
        scene_name = scene['name']
        scene_path = scene['path']
        town = scene['town']
        offset = np.array([*origin_offsets.get(town, (0.0, 0.0)), 0.0])
        base_us = base_timestamp_us(run_name, scene['date_parts'])
        if date_captured is None:
            date_captured = datetime.fromtimestamp(base_us / 1e6, tz=timezone.utc).strftime('%Y-%m-%d')

        # ── log / map (one per town) ─────────────────────────────────────────
        if town not in log_tokens:
            log_tokens[town] = token(run_name, 'log', town)
            tables['log'].append({
                'token': log_tokens[town],
                'logfile': f'{run_name}_{town}',
                'vehicle': 'lincoln',
                'date_captured': date_captured,
                'location': town,
            })
            map_logs[town] = []
        map_logs[town].append(log_tokens[town])

        # ── calibrated_sensor (one set per scene) ────────────────────────────
        calibration = json.loads((scene_path / 'sensor_calibration.json').read_text())
        calibrated_tokens = {}
        for channel, _ in channels:
            entry = calibration['cameras'].get(channel) or calibration['lidars'][channel]
            calibrated_tokens[channel] = token(run_name, scene_name, 'calibrated_sensor', channel)
            tables['calibrated_sensor'].append({
                'token': calibrated_tokens[channel],
                'sensor_token': token('sensor', channel),
                'translation': entry['translation'],
                'rotation': entry['rotation'],
                'camera_intrinsic': entry.get('intrinsic', []),
            })

        frames = common_frames(scene_path, channels)
        if not frames:
            print(f'[warn] No complete frames in {scene_path}, skipping scene')
            continue
        keyframes = set(frames[::args.sample_interval])
        sample_frames = [f for f in frames if f in keyframes]
        sample_tokens = {f: token(run_name, scene_name, 'sample', f) for f in sample_frames}

        # ── ego_pose per frame (+ boxes cache) ───────────────────────────────
        boxes_by_frame = {}
        ego_pose_tokens = {}
        for frame in frames:
            boxes = load_json_gz(scene_path / 'boxes' / f'{frame:04}.json.gz')
            boxes_by_frame[frame] = boxes
            ego = next(b for b in boxes if b['class'] == 'ego_car')
            matrix = np.array(ego['matrix'])
            ego_pose_tokens[frame] = token(run_name, scene_name, 'ego_pose', frame)
            tables['ego_pose'].append({
                'token': ego_pose_tokens[frame],
                'timestamp': base_us + frame * FRAME_PERIOD_US,
                'translation': (matrix[:3, 3] + offset).tolist(),
                'rotation': matrix_to_quaternion(matrix[:3, :3]),
            })

        # ── sample (keyframes) + scene ───────────────────────────────────────
        for i, frame in enumerate(sample_frames):
            tables['sample'].append({
                'token': sample_tokens[frame],
                'timestamp': base_us + frame * FRAME_PERIOD_US,
                'prev': sample_tokens[sample_frames[i - 1]] if i > 0 else '',
                'next': sample_tokens[sample_frames[i + 1]] if i + 1 < len(sample_frames) else '',
                'scene_token': token(run_name, scene_name, 'scene'),
            })

        tables['scene'].append({
            'token': token(run_name, scene_name, 'scene'),
            'log_token': log_tokens[town],
            'nbr_samples': len(sample_frames),
            'first_sample_token': sample_tokens[sample_frames[0]],
            'last_sample_token': sample_tokens[sample_frames[-1]],
            'name': scene_name,
            'description': f"{scene['scenario']} scenario on {town} (PDM-Lite)",
        })

        # ── sample_data (all frames x all channels) + file placement ────────
        for channel, ext in channels:
            is_camera = channel in camera_channels
            prev_token = ''
            for i, frame in enumerate(frames):
                is_key = frame in keyframes
                timestamp = base_us + frame * FRAME_PERIOD_US
                subdir = 'samples' if is_key else 'sweeps'
                filename = f'{subdir}/{channel}/{scene_name}__{channel}__{timestamp}{ext}'
                sd_token = token(run_name, scene_name, 'sample_data', channel, frame)
                next_frame = frames[i + 1] if i + 1 < len(frames) else None
                # Sweeps still reference the sample they belong to: the closest
                # keyframe at or before them (nuScenes convention).
                owning = max((f for f in sample_frames if f <= frame), default=sample_frames[0])
                tables['sample_data'].append({
                    'token': sd_token,
                    'sample_token': sample_tokens[owning],
                    'ego_pose_token': ego_pose_tokens[frame],
                    'calibrated_sensor_token': calibrated_tokens[channel],
                    'timestamp': timestamp,
                    'fileformat': 'jpg' if is_camera else 'pcd',
                    'is_key_frame': is_key,
                    'height': CAMERA_HEIGHT if is_camera else 0,
                    'width': CAMERA_WIDTH if is_camera else 0,
                    'filename': filename,
                    'prev': prev_token,
                    'next': (token(run_name, scene_name, 'sample_data', channel, next_frame)
                             if next_frame is not None else ''),
                })
                prev_token = sd_token
                place_file(scene_path / channel / f'{frame:04}{ext}', out_dir / filename, args.link_mode)

        # ── sample_annotation + instance (keyframes only) ────────────────────
        instance_annotations = {}  # actor id -> [(frame, annotation token, category)]
        for frame in sample_frames:
            for box in boxes_by_frame[frame]:
                mapped = category_for_box(box)
                if mapped is None:
                    continue
                category, is_parked = mapped
                matrix = np.array(box['matrix'])
                # Actor origin -> box center: shift by extent_z along the
                # actor's up axis (see module docstring for the approximation).
                center = matrix[:3, 3] + matrix[:3, :3] @ np.array([0.0, 0.0, box['extent'][2]]) + offset
                num_points = max(0, int(box.get('num_points', 0)))
                attribute = attribute_for_box(category, is_parked, box.get('speed', 0.0))
                ann_token = token(run_name, scene_name, 'annotation', box['id'], frame)
                tables['sample_annotation'].append({
                    'token': ann_token,
                    'sample_token': sample_tokens[frame],
                    'instance_token': token(run_name, scene_name, 'instance', box['id']),
                    'visibility_token': visibility_for_points(num_points),
                    'attribute_tokens': [attribute_tokens[attribute]] if attribute else [],
                    'translation': center.tolist(),
                    'size': [2 * box['extent'][1], 2 * box['extent'][0], 2 * box['extent'][2]],  # w, l, h
                    'rotation': matrix_to_quaternion(matrix[:3, :3]),
                    'prev': '',
                    'next': '',
                    'num_lidar_pts': num_points,
                    'num_radar_pts': 0,
                })
                instance_annotations.setdefault(box['id'], []).append((frame, ann_token, category))

        annotation_rows = {row['token']: row for row in tables['sample_annotation']}
        for actor_id, annotations in instance_annotations.items():
            annotations.sort(key=lambda item: item[0])
            for i, (_, ann_token, _) in enumerate(annotations):
                annotation_rows[ann_token]['prev'] = annotations[i - 1][1] if i > 0 else ''
                annotation_rows[ann_token]['next'] = annotations[i + 1][1] if i + 1 < len(annotations) else ''
            tables['instance'].append({
                'token': token(run_name, scene_name, 'instance', actor_id),
                'category_token': category_tokens[annotations[0][2]],
                'nbr_annotations': len(annotations),
                'first_annotation_token': annotations[0][1],
                'last_annotation_token': annotations[-1][1],
            })

        print(f"[scene] {scene_name}: {len(frames)} frames "
              f"({len(sample_frames)} samples), town={town}, folder={scene_path.name}")

    # ── map (placeholder filenames; replaced by the future map conversion) ──
    for town, logs in sorted(map_logs.items()):
        tables['map'].append({
            'token': token(run_name, 'map', town),
            'category': 'semantic_prior',
            'filename': f'maps/{town}.png',
            'log_tokens': logs,
        })
    (out_dir / 'maps').mkdir(parents=True, exist_ok=True)

    version_dir = out_dir / args.version
    version_dir.mkdir(parents=True, exist_ok=True)
    for name, rows in tables.items():
        with open(version_dir / f'{name}.json', 'w', encoding='utf-8') as f:
            json.dump(rows, f, indent=1)

    print(f'\nWrote {len(tables["scene"])} scene(s), {len(tables["sample"])} sample(s), '
          f'{len(tables["sample_data"])} sample_data, {len(tables["sample_annotation"])} annotation(s), '
          f'{len(tables["instance"])} instance(s) to {out_dir}')
    if skipped_incomplete:
        print(f'Skipped {skipped_incomplete} route(s) without a completed attempt (--attempt-policy complete-only)')

    validate(out_dir, tables)


def validate(out_dir, tables):
    """Referential-integrity checks over the generated tables."""
    errors = []

    def tokens_of(name):
        return {row['token'] for row in tables[name]}

    references = [
        ('scene', 'log_token', 'log'), ('scene', 'first_sample_token', 'sample'),
        ('scene', 'last_sample_token', 'sample'), ('sample', 'scene_token', 'scene'),
        ('sample_data', 'sample_token', 'sample'), ('sample_data', 'ego_pose_token', 'ego_pose'),
        ('sample_data', 'calibrated_sensor_token', 'calibrated_sensor'),
        ('calibrated_sensor', 'sensor_token', 'sensor'),
        ('sample_annotation', 'sample_token', 'sample'),
        ('sample_annotation', 'instance_token', 'instance'),
        ('sample_annotation', 'visibility_token', 'visibility'),
        ('instance', 'category_token', 'category'),
        ('instance', 'first_annotation_token', 'sample_annotation'),
        ('instance', 'last_annotation_token', 'sample_annotation'),
        ('map', 'log_tokens', 'log'),
    ]
    for table, field, target in references:
        targets = tokens_of(target)
        missing = 0
        for row in tables[table]:
            refs = row[field] if isinstance(row[field], list) else [row[field]]
            missing += sum(1 for ref in refs if ref and ref not in targets)
        if missing:
            errors.append(f'{table}.{field}: {missing} dangling reference(s) to {target}')

    for table in ('sample', 'sample_data', 'sample_annotation'):
        rows = {row['token']: row for row in tables[table]}
        bad_chain = sum(1 for row in rows.values()
                        for ref in (row['prev'], row['next']) if ref and ref not in rows)
        if bad_chain:
            errors.append(f'{table}: {bad_chain} broken prev/next link(s)')

    missing_files = sum(1 for row in tables['sample_data'] if not (out_dir / row['filename']).exists())
    if missing_files:
        errors.append(f'sample_data: {missing_files} filename(s) missing on disk')

    for scene in tables['scene']:
        n = sum(1 for s in tables['sample'] if s['scene_token'] == scene['token'])
        if n != scene['nbr_samples']:
            errors.append(f"scene {scene['name']}: nbr_samples={scene['nbr_samples']} but {n} samples")

    if errors:
        print('\nVALIDATION FAILED:')
        for error in errors:
            print(f'  - {error}')
        sys.exit(1)
    print('Validation OK (referential integrity, prev/next chains, files on disk)')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('run_dir', help='collection run directory (contains data/<scenario>/<route folders>)')
    parser.add_argument('output_dir', help='output nuScenes dataset root')
    parser.add_argument('--version', default='v1.0-trainval', help='metadata folder name (default: v1.0-trainval)')
    parser.add_argument('--sample-interval', type=int, default=2,
                        help='every N-th frame becomes a keyframe/sample (default 2 = 2 Hz)')
    parser.add_argument('--link-mode', choices=['hardlink', 'copy'], default='copy',
                        help='how to place sensor files (hardlink falls back to copy across filesystems)')
    parser.add_argument('--origin-offset', action='append', metavar='TOWN=X,Y',
                        help='per-town global origin offset added to all global coordinates '
                             '(must match the nuScenes map conversion); repeatable')
    parser.add_argument('--attempt-policy', choices=['prefer-complete', 'complete-only'],
                        default='prefer-complete',
                        help='route folders with multiple attempts: prefer-complete falls back to the '
                             'longest partial attempt; complete-only skips routes without a completed attempt')
    convert(parser.parse_args())


if __name__ == '__main__':
    main()
