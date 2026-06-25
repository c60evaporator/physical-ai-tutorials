"""
Generates BEV map .h5 files for specified CARLA maps using an already-running CARLA server.
Unlike birdview_map_opencv.py, this script does NOT launch CARLA itself.

Usage:
    # Generate for a custom map (both 2ppm and 4ppm):
    python tools/generate_bev_map.py --map_names <map_name>

    # Generate for multiple maps:
    python tools/generate_bev_map.py --map_names <map_name1> <map_name2> ...

    # Specify CARLA port and garage root:
    python tools/generate_bev_map.py --port 2000 --carla_garage_root /workspace/carla_garage --map_names UE4_FIELD_TOWN
"""

import argparse
import os
import sys
import carla
import h5py
import numpy as np
from pathlib import Path

# birdview_map_opencv.py is located in team_code/birds_eye_view/
_SCRIPT_DIR = Path(__file__).resolve().parent
_CARLA_GARAGE_ROOT = Path(os.environ.get('CARLA_GARAGE_ROOT', _SCRIPT_DIR.parent / 'carla_garage'))
sys.path.insert(0, str(_CARLA_GARAGE_ROOT / 'team_code' / 'birds_eye_view'))
sys.path.insert(0, str(_CARLA_GARAGE_ROOT / 'team_code'))

from birdview_map_opencv import MapImage  # noqa: E402

# (pixels_per_meter, folder_name) pairs to generate by default
DEFAULT_PPM_FOLDERS = [
    (2.0, 'maps_2ppm_cv'),  # used by data_agent.py (data collection)
    (4.0, 'maps_4ppm_cv'),  # used by autopilot.py (inference)
]

def generate_h5(client, carla_map_name, save_dir, pixels_per_meter):
    save_dir = Path(save_dir)
    save_dir.mkdir(parents=True, exist_ok=True)
    hf_file_path = save_dir / (carla_map_name + '.h5')

    # Skip if already exists with matching pixels_per_meter
    if hf_file_path.exists():
        with h5py.File(hf_file_path, 'r') as map_hf:
            hf_pixels_per_meter = float(map_hf.attrs['pixels_per_meter'])
        if np.isclose(hf_pixels_per_meter, pixels_per_meter):
            print(f'{carla_map_name}.h5 with pixels_per_meter={pixels_per_meter:.2f} already exists. Skipping.')
            return

    print(f'Generating {carla_map_name}.h5 with pixels_per_meter={pixels_per_meter:.2f} ...')
    world = client.load_world(carla_map_name, reset_settings=False)

    settings = carla.WorldSettings(
        synchronous_mode=True,
        fixed_delta_seconds=0.1,
        deterministic_ragdolls=True,
        no_rendering_mode=False,
        spectator_as_ego=False,
    )
    world.apply_settings(settings)

    dict_masks = MapImage.draw_map_image(world.get_map(), pixels_per_meter)

    with h5py.File(hf_file_path, 'w') as hf:
        hf.attrs['pixels_per_meter'] = pixels_per_meter
        hf.attrs['world_offset_in_meters'] = dict_masks['world_offset']
        hf.attrs['width_in_meters'] = dict_masks['width_in_meters']
        hf.attrs['width_in_pixels'] = dict_masks['width_in_pixels']
        hf.create_dataset('road', data=dict_masks['road'], compression='gzip', compression_opts=9)
        hf.create_dataset('shoulder', data=dict_masks['shoulder'], compression='gzip', compression_opts=9)
        hf.create_dataset('parking', data=dict_masks['parking'], compression='gzip', compression_opts=9)
        hf.create_dataset('sidewalk', data=dict_masks['sidewalk'], compression='gzip', compression_opts=9)
        hf.create_dataset('stopline', data=dict_masks['stopline'], compression='gzip', compression_opts=9)
        hf.create_dataset('lane_marking_all', data=dict_masks['lane_marking_all'], compression='gzip', compression_opts=9)
        hf.create_dataset('lane_marking_yellow_broken',
                          data=dict_masks['lane_marking_yellow_broken'], compression='gzip', compression_opts=9)
        hf.create_dataset('lane_marking_yellow_solid',
                          data=dict_masks['lane_marking_yellow_solid'], compression='gzip', compression_opts=9)
        hf.create_dataset('lane_marking_white_broken',
                          data=dict_masks['lane_marking_white_broken'], compression='gzip', compression_opts=9)
        hf.create_dataset('lane_marking_white_solid',
                          data=dict_masks['lane_marking_white_solid'], compression='gzip', compression_opts=9)

    print(f'Saved {hf_file_path}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(
        description='Generate BEV map .h5 files using an already-running CARLA server.')
    parser.add_argument('--map_name', nargs='*', required=True,
                        help='CARLA map names to generate. If omitted, generates all standard towns.')
    parser.add_argument('--host', type=str, default='localhost',
                        help='CARLA server host (default: localhost)')
    parser.add_argument('--port', type=int, default=int(os.environ.get('CARLA_PORT', 2000)),
                        help='CARLA server port (default: $CARLA_PORT or 2000)')
    parser.add_argument('--carla_garage_root', type=str,
                        default=str(_CARLA_GARAGE_ROOT),
                        help='Path to carla_garage root (default: $CARLA_GARAGE_ROOT)')
    parser.add_argument('--pixels_per_meter', type=float, default=None,
                        help='If specified, generate only this resolution. '
                             'Otherwise generates both 2.0 (maps_2ppm_cv) and 4.0 (maps_4ppm_cv).')
    args = parser.parse_args()

    carla_garage_root = Path(args.carla_garage_root)

    # Determine which (ppm, folder) pairs to generate
    if args.pixels_per_meter is not None:
        # Single resolution: derive folder name automatically
        ppm = args.pixels_per_meter
        folder = f'maps_{ppm:.0f}ppm_cv' if ppm >= 1.0 else f'maps_{ppm}ppm_cv'
        ppm_folders = [(ppm, folder)]
    else:
        ppm_folders = DEFAULT_PPM_FOLDERS

    client = carla.Client(args.host, args.port)
    client.set_timeout(120)
    print(f'Connected to CARLA at {args.host}:{args.port}')
    print(f'Maps to generate: {args.map_name}')

    for ppm, folder in ppm_folders:
        save_dir = carla_garage_root / 'team_code' / 'birds_eye_view' / folder
        print(f'\n--- pixels_per_meter={ppm:.1f} -> {save_dir} ---')
        for map_name in args.map_name:
            generate_h5(client, map_name, save_dir, ppm)

    print('\nDone.')
