"""
Child of the autopilot (PDM-Lite) that collects data with a nuScenes-style sensor rig:
the 6 RGB cameras of the nuScenes vehicle (CAM_FRONT, CAM_FRONT_LEFT, CAM_FRONT_RIGHT,
CAM_BACK, CAM_BACK_LEFT, CAM_BACK_RIGHT) at 1600x900 plus a roof LiDAR at the LIDAR_TOP
mounting position. Data is stored in nuScenes conventions (COORDINATE_SYSTEM =
'nuscenes', LiDAR as .pcd.bin); see generalized_data_agent.py for the folder layout.
"""

from generalized_data_agent import GeneralizedDataAgent

# Offset used to convert nuScenes sensor mounting positions (v1.0 calibrated_sensor) to
# CARLA coordinates.
# nuScenes ego frame: x forward, y left, right-handed, origin at the rear axle center (ground level).
# CARLA sensor frame: x forward, y right, left-handed, origin at the vehicle bounding box center.
# Conversion: y_carla = -y_nuscenes, yaw_carla = -yaw_nuscenes, x_carla = x_nuscenes - REAR_AXLE_TO_CENTER.
# z is measured from the ground in both frames.
REAR_AXLE_TO_CENTER = 1.42  # Lincoln MKZ wheelbase (2.85 m) / 2


def get_entry_point():
    return 'DataAgentNuScenes'


class DataAgentNuScenes(GeneralizedDataAgent):
    """
    Child of GeneralizedDataAgent with a nuScenes-style 6 camera + LiDAR rig.
    """

    COORDINATE_SYSTEM = 'nuscenes'
    LIDAR_FORMAT = 'pcd_bin'

    def _sensors(self):
        # Camera positions/orientations are the nuScenes rig converted to CARLA
        # coordinates (see REAR_AXLE_TO_CENTER above); resolution is the nuScenes
        # 1600x900.
        return [{
            'type': 'sensor.camera.rgb',
            'x': 0.28, 'y': 0.0, 'z': 1.51,
            'roll': 0.0, 'pitch': 0.0, 'yaw': 0.0,
            'width': 1600, 'height': 900, 'fov': 70,
            'id': 'CAM_FRONT'
        }, {
            'type': 'sensor.camera.rgb',
            'x': 0.15, 'y': -0.50, 'z': 1.52,
            'roll': 0.0, 'pitch': 0.0, 'yaw': -55.0,
            'width': 1600, 'height': 900, 'fov': 70,
            'id': 'CAM_FRONT_LEFT'
        }, {
            'type': 'sensor.camera.rgb',
            'x': 0.16, 'y': 0.50, 'z': 1.52,
            'roll': 0.0, 'pitch': 0.0, 'yaw': 55.0,
            'width': 1600, 'height': 900, 'fov': 70,
            'id': 'CAM_FRONT_RIGHT'
        }, {
            'type': 'sensor.camera.rgb',
            'x': -1.37, 'y': 0.0, 'z': 1.57,
            'roll': 0.0, 'pitch': 0.0, 'yaw': 180.0,
            'width': 1600, 'height': 900, 'fov': 110,
            'id': 'CAM_BACK'
        }, {
            'type': 'sensor.camera.rgb',
            'x': -0.38, 'y': -0.48, 'z': 1.56,
            'roll': 0.0, 'pitch': 0.0, 'yaw': -110.0,
            'width': 1600, 'height': 900, 'fov': 70,
            'id': 'CAM_BACK_LEFT'
        }, {
            'type': 'sensor.camera.rgb',
            'x': -0.36, 'y': 0.47, 'z': 1.61,
            'roll': 0.0, 'pitch': 0.0, 'yaw': 110.0,
            'width': 1600, 'height': 900, 'fov': 70,
            'id': 'CAM_BACK_RIGHT'
        }, {
            # nuScenes LIDAR_TOP mounting position (translation [0.94, 0.0, 1.84] in the
            # nuScenes ego frame). The real LIDAR_TOP is additionally rotated ~90 degrees
            # about z; yaw=0 is used instead, which stays consistent because the stored
            # point clouds and calibration share the same sensor frame.
            # agent_wrapper_local.py requires rotation_frequency and points_per_second in
            # the spec when DATAGEN=1; rotation_frequency must stay at 10 (half a sweep
            # per 20 Hz tick) because GeneralizedDataAgent.tick merges 2 sweeps. The
            # remaining beam parameters (channels=64, range=85, fov, ...) are hardcoded
            # by the wrapper and cannot be set here.
            'type': 'sensor.lidar.ray_cast',
            'x': 0.94 - REAR_AXLE_TO_CENTER, 'y': 0.0, 'z': 1.84,
            'roll': 0.0, 'pitch': 0.0, 'yaw': 0.0,
            'rotation_frequency': 10,
            'points_per_second': 600000,
            'id': 'LIDAR_TOP'
        }]
