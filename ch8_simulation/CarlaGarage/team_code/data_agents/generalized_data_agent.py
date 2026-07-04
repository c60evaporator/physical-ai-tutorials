"""
Generalized PDM-Lite data collection agent.

Subclasses only implement `_sensors()`, which returns a list of CARLA sensor
specifications (same dict format as the leaderboard `sensors()` method). The base
class automatically creates one folder per sensor id, collects the data every
`data_save_freq` frames and stores it according to the sensor type:

  - sensor.camera.rgb                    -> <id>/<frame>.jpg
  - sensor.camera.semantic_segmentation  -> <id>/<frame>.png
  - sensor.camera.depth                  -> <id>/<frame>.png (8 bit normalized depth)
  - sensor.lidar.ray_cast                -> <id>/<frame>.laz or .pcd.bin
                                            (LIDAR_FORMAT; optional, any number)
  - sensor.other.radar                   -> <id>/<frame>.npy
  - sensor.other.gnss                    -> <id>/<frame>.json

In addition, ground-truth bounding boxes (boxes/) and the sensor calibration
(sensor_calibration.json) are always stored. Ground-truth BEV semantics
(bev_semantics/, originally for TransFuser++ training) are stored by default but can
be disabled with SAVE_BEV_SEMANTICS = False. LiDAR is optional: the BEV semantics
are rendered from the simulator world state, not from LiDAR points. When LiDAR
sensors are present, their mounting position/orientation is taken from the
`_sensors()` spec; the `self.config.lidar_*` settings are not used.

Storage settings (BEV raster size, LAZ compression, ...) are class attributes and
can be overridden by redefining them in the subclass:

    class MyDataAgent(GeneralizedDataAgent):
        SAVE_BEV_SEMANTICS = False
        LAZ_POINT_PRECISION = 0.001

The output coordinate system is selected with COORDINATE_SYSTEM ('carla' | 'nuscenes').
With 'nuscenes', sensor_calibration.json follows the nuScenes calibrated_sensor
convention (right-handed ego frame, quaternion rotations, optical camera frames),
LiDAR point clouds are stored in the right-handed LiDAR sensor frame and bounding
boxes are converted to right-handed frames (y -> -y, yaw -> -yaw). Global coordinates
(the 'matrix' fields in boxes/) keep CARLA's world origin: the shift to a per-town
nuScenes map origin is a property of the map conversion and is applied in the
post-processing that generates the nuScenes tables, not here. The measurements/
folder (written by AutoPilot) always stays in CARLA coordinates.

Inherits from DataAgent for its rig-independent helpers (get_bounding_boxes,
shuffle_weather, destroy, ...), while the rig-specific methods (setup, _init,
sensors, tick, run_step, save_sensors) are overridden here and call the AutoPilot
grandparent via `super(DataAgent, self)` to skip DataAgent's hardcoded TransFuser rig.
"""
import cv2
import torch
import numpy as np
import json
import os
import sys
import gzip
import laspy
from pathlib import Path
from abc import abstractmethod

# The leaderboard evaluator only puts the agent file's own directory (data_agents/) on
# sys.path; the upstream team_code modules (data_agent, autopilot, ...) live one level up.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from data_agent import DataAgent
import transfuser_utils as t_u

from leaderboard.autoagents import autonomous_agent

from birds_eye_view.chauffeurnet import ObsManager
from birds_eye_view.run_stop_sign import RunStopSign

from agents.navigation.local_planner import LocalPlanner

def get_entry_point():
    # This module only provides the abstract base class; point the leaderboard at a
    # subclass agent file instead.
    raise NotImplementedError('GeneralizedDataAgent is abstract; use a subclass agent file.')


class GeneralizedDataAgent(DataAgent):
    """
    Data agent that collects data with sensors that are specified by `_sensors()`.

    The class attributes below are storage settings; override them in the subclass
    to customize (they are read via `self`, so a class-level redefinition suffices).
    """
    # Whether to render and store ground-truth BEV semantics (originally for
    # TransFuser++ training). Disabling also removes the dependency on the
    # pre-generated birds_eye_view/maps_2ppm_cv rasters.
    SAVE_BEV_SEMANTICS = True
    # BEV ground-truth raster size in pixels. Must match the pre-generated rasters in birds_eye_view/maps_2ppm_cv
    BEV_RESOLUTION_WIDTH = 256
    BEV_RESOLUTION_HEIGHT = 256

    # Storage format for LiDAR point clouds.
    # 'laz': compressed, xyz only (1 cm quantization, see LAZ_POINT_PRECISION).
    # 'pcd_bin': nuScenes-style .pcd.bin, flat float32 records of (x, y, z, intensity,
    #   ring_index). intensity is CARLA's raw [0, 1] attenuation value; ring_index is
    #   always 0 because CARLA does not expose it.
    LIDAR_FORMAT = 'laz'
    # LAZ compression settings for stored LiDAR point clouds
    LAZ_POINT_FORMAT = 0
    LAZ_POINT_PRECISION = 0.01

    # Output coordinate system for sensor_calibration.json, LiDAR point clouds and boxes/.
    # 'carla': store everything in CARLA's left-handed convention as-is.
    # 'nuscenes': store nuScenes-convention data (right-handed; see the module docstring).
    #   Global coordinates keep CARLA's world origin; the shift to a per-town map origin
    #   belongs to the post-processing that generates the nuScenes map/tables.
    COORDINATE_SYSTEM = 'carla'

    @abstractmethod
    def _sensors(self):
        # OpenDriveMap, IMU, and Speedometer are always included by the parent class. This method should return a list of additional sensors.
        # Must return a static list: it is called during the base setup(), before the subclass setup() has finished.
        # Required spec keys (agent_wrapper_local.py raises KeyError otherwise):
        #   cameras: width, height, fov
        #   lidar:   rotation_frequency, points_per_second (when DATAGEN=1; keep
        #            rotation_frequency=10 so that tick()'s 2-sweep merge stays valid)
        #   radar:   horizontal_fov, vertical_fov
        raise NotImplementedError

    def setup(self, path_to_conf_file, route_index=None, traffic_manager=None):
        if self.COORDINATE_SYSTEM not in ('carla', 'nuscenes'):
            raise ValueError(f'Unsupported COORDINATE_SYSTEM: {self.COORDINATE_SYSTEM}')
        if self.LIDAR_FORMAT not in ('laz', 'pcd_bin'):
            raise ValueError(f'Unsupported LIDAR_FORMAT: {self.LIDAR_FORMAT}')
        # Skip DataAgent.setup, which creates the fixed TransFuser sensor folders;
        # AutoPilot.setup provides everything else (config, save_path, datagen, ...).
        super(DataAgent, self).setup(path_to_conf_file, route_index, traffic_manager=None)
        # leaderboard_autopilot applies the larger SENSORS_LIMITS (8 rgb cameras) only to the
        # *_QUALIFIER tracks; e.g. a 6 camera rig exceeds the 4 rgb camera cap of Track.MAP.
        # Requires running the evaluator with --track=MAP_QUALIFIER (DATASET_TRACK_CODENAME).
        self.track = autonomous_agent.Track.MAP_QUALIFIER
        self.weather_tmp = None
        self.step_tmp = 0

        self.tm = traffic_manager

        self.scenario_name = Path(path_to_conf_file).parent.name
        self.cutin_vehicle_starting_position = None

        # Group the sensor specs of the subclass rig by type
        self.custom_sensors = self._sensors()
        self.rgb_sensors = [s for s in self.custom_sensors if s['type'] == 'sensor.camera.rgb']
        self.semseg_sensors = [s for s in self.custom_sensors if s['type'] == 'sensor.camera.semantic_segmentation']
        self.depth_sensors = [s for s in self.custom_sensors if s['type'] == 'sensor.camera.depth']
        self.lidar_sensors = [s for s in self.custom_sensors if s['type'] == 'sensor.lidar.ray_cast']
        self.radar_sensors = [s for s in self.custom_sensors if s['type'] == 'sensor.other.radar']
        self.gnss_sensors = [s for s in self.custom_sensors if s['type'] == 'sensor.other.gnss']

        if self.save_path is not None and self.datagen:
            if self.SAVE_BEV_SEMANTICS:
                (self.save_path / 'bev_semantics').mkdir()
            (self.save_path / 'boxes').mkdir()
            for sensor in (self.rgb_sensors + self.semseg_sensors + self.depth_sensors + self.lidar_sensors +
                           self.radar_sensors + self.gnss_sensors):
                (self.save_path / sensor['id']).mkdir()

            self.save_calibration()

        self.tmp_visu = int(os.environ.get('TMP_VISU', 0))

        self._active_traffic_light = None
        self.last_lidar = {}
        self.last_ego_transform = None

    @staticmethod
    def _extrinsic_carla(sensor):
        # Mounting position relative to the vehicle in CARLA coordinates (x fwd, y right, z up)
        return {key: sensor.get(key, 0.0) for key in ('x', 'y', 'z', 'roll', 'pitch', 'yaw')}

    # Rotation from the camera optical frame (x right, y down, z forward = OpenCV) to the
    # x-forward sensor frame (x fwd, y left, z up). Part of the nuScenes calibrated_sensor
    # convention for cameras. Columns are the optical axes expressed in the forward frame.
    _OPTICAL_TO_FORWARD = np.array([[0.0, 0.0, 1.0], [-1.0, 0.0, 0.0], [0.0, -1.0, 0.0]])

    # Reflection that converts CARLA (left-handed, y right) 4x4 matrices/points to the
    # right-handed equivalent (y left). Its own inverse.
    _Y_FLIP = np.diag([1.0, -1.0, 1.0, 1.0])

    @staticmethod
    def _nuscenes_translation(sensor):
        # CARLA mounting position (left-handed, y right) -> right-handed ego frame (y left)
        return [sensor.get('x', 0.0), -sensor.get('y', 0.0), sensor.get('z', 0.0)]

    @staticmethod
    def _nuscenes_rotation_matrix(sensor):
        """
        Mounting rotation in the right-handed ego frame (x fwd, y left, z up).
        Left- to right-handed euler conversion is roll -> roll, pitch -> -pitch,
        yaw -> -yaw (same as the CARLA ros-bridge).
        """
        roll = np.deg2rad(sensor.get('roll', 0.0))
        pitch = -np.deg2rad(sensor.get('pitch', 0.0))
        yaw = -np.deg2rad(sensor.get('yaw', 0.0))

        rotation_x = np.array([[1.0, 0.0, 0.0],
                               [0.0, np.cos(roll), -np.sin(roll)],
                               [0.0, np.sin(roll), np.cos(roll)]])
        rotation_y = np.array([[np.cos(pitch), 0.0, np.sin(pitch)],
                               [0.0, 1.0, 0.0],
                               [-np.sin(pitch), 0.0, np.cos(pitch)]])
        rotation_z = np.array([[np.cos(yaw), -np.sin(yaw), 0.0],
                               [np.sin(yaw), np.cos(yaw), 0.0],
                               [0.0, 0.0, 1.0]])

        return rotation_z @ rotation_y @ rotation_x

    @staticmethod
    def _matrix_to_quaternion(matrix):
        """Rotation matrix -> quaternion [w, x, y, z] (nuScenes ordering)."""
        m = matrix
        trace = m[0, 0] + m[1, 1] + m[2, 2]
        if trace > 0.0:
            s = np.sqrt(trace + 1.0) * 2.0
            w, x, y, z = 0.25 * s, (m[2, 1] - m[1, 2]) / s, (m[0, 2] - m[2, 0]) / s, (m[1, 0] - m[0, 1]) / s
        elif m[0, 0] > m[1, 1] and m[0, 0] > m[2, 2]:
            s = np.sqrt(1.0 + m[0, 0] - m[1, 1] - m[2, 2]) * 2.0
            w, x, y, z = (m[2, 1] - m[1, 2]) / s, 0.25 * s, (m[0, 1] + m[1, 0]) / s, (m[0, 2] + m[2, 0]) / s
        elif m[1, 1] > m[2, 2]:
            s = np.sqrt(1.0 + m[1, 1] - m[0, 0] - m[2, 2]) * 2.0
            w, x, y, z = (m[0, 2] - m[2, 0]) / s, (m[0, 1] + m[1, 0]) / s, 0.25 * s, (m[1, 2] + m[2, 1]) / s
        else:
            s = np.sqrt(1.0 + m[2, 2] - m[0, 0] - m[1, 1]) * 2.0
            w, x, y, z = (m[1, 0] - m[0, 1]) / s, (m[0, 2] + m[2, 0]) / s, (m[1, 2] + m[2, 1]) / s, 0.25 * s
        return [float(w), float(x), float(y), float(z)]

    def _extrinsic_nuscenes(self, sensor):
        """
        Mounting extrinsics in the nuScenes calibrated_sensor convention: translation and
        quaternion mapping the sensor frame to the right-handed ego frame. Camera rotations
        refer to the optical frame (x right, y down, z forward), like nuScenes.
        """
        rotation = self._nuscenes_rotation_matrix(sensor)
        if sensor['type'].startswith('sensor.camera'):
            rotation = rotation @ self._OPTICAL_TO_FORWARD

        return {'translation': self._nuscenes_translation(sensor), 'rotation': self._matrix_to_quaternion(rotation)}

    def _extrinsic(self, sensor):
        if self.COORDINATE_SYSTEM == 'nuscenes':
            return self._extrinsic_nuscenes(sensor)
        return {'extrinsic_carla': self._extrinsic_carla(sensor)}

    def save_calibration(self):
        """Store intrinsics and mounting extrinsics of every sensor once per route."""
        calibration = {'coordinate_system': self.COORDINATE_SYSTEM, 'cameras': {}, 'lidars': {}, 'radars': {}}
        for camera in (self.rgb_sensors + self.semseg_sensors + self.depth_sensors):
            intrinsic = t_u.calculate_intrinsic_matrix(fov=camera['fov'],
                                                       height=camera['height'],
                                                       width=camera['width'])
            calibration['cameras'][camera['id']] = {
                'type': camera['type'],
                'intrinsic': intrinsic.tolist(),
                **self._extrinsic(camera),
                'width': camera['width'],
                'height': camera['height'],
                'fov': camera['fov']
            }
        for lidar in self.lidar_sensors:
            calibration['lidars'][lidar['id']] = self._extrinsic(lidar)
        for radar in self.radar_sensors:
            calibration['radars'][radar['id']] = self._extrinsic(radar)

        with open(self.save_path / 'sensor_calibration.json', 'w', encoding='utf-8') as f:
            json.dump(calibration, f, indent=4)

    def _init(self, hd_map):
        # Skip DataAgent._init, which additionally builds the augmented BEV manager of the TransFuser rig
        super(DataAgent, self)._init(hd_map)
        if self.datagen:
            self.shuffle_weather()

        if self.SAVE_BEV_SEMANTICS:
            obs_config = {
                'width_in_pixels': self.BEV_RESOLUTION_WIDTH,
                'pixels_ev_to_bottom': self.BEV_RESOLUTION_HEIGHT / 2.0,
                'pixels_per_meter': self.config.pixels_per_meter_collection,
                'history_idx': [-1],
                'scale_bbox': True,
                'scale_mask_col': 1.0,
                'map_folder': 'maps_2ppm_cv'
            }

            self.stop_sign_criteria = RunStopSign(self._world)
            self.ss_bev_manager = ObsManager(obs_config, self.config)
            self.ss_bev_manager.attach_ego_vehicle(self._vehicle, criteria_stop=self.stop_sign_criteria)

        self._local_planner = LocalPlanner(self._vehicle, opt_dict={}, map_inst=self.world_map)

    def sensors(self):
        # AutoPilot's driving sensors (hd_map, imu, speedometer) + the subclass rig
        result = super(DataAgent, self).sensors()

        result += self.custom_sensors

        return result

    @staticmethod
    def lidar_to_ego_coordinate(lidar, sensor_spec):
        """
        Converts the LiDAR points given by the simulator into the ego agent's coordinate
        system, using the mounting position/yaw from the `_sensors()` spec (unlike
        t_u.lidar_to_ego_coordinate, which reads config.lidar_pos / config.lidar_rot).
        :param lidar: the LiDAR point cloud as provided in the input of run_step
        :param sensor_spec: the sensor specification dict of this LiDAR
        :return: (N, 4) array (x, y, z, intensity) where the points are w.r.t. 0/0/0 of
        the car and the carla coordinate system. The intensity column is kept as-is.
        """
        yaw = np.deg2rad(sensor_spec.get('yaw', 0.0))
        rotation_matrix = np.array([[np.cos(yaw), -np.sin(yaw), 0.0], [np.sin(yaw), np.cos(yaw), 0.0],
                                    [0.0, 0.0, 1.0]])

        translation = np.array([sensor_spec.get('x', 0.0), sensor_spec.get('y', 0.0), sensor_spec.get('z', 0.0)])

        points = lidar[1]
        # The double transpose is a trick to compute all the points together.
        ego_xyz = (rotation_matrix @ points[:, :3].T).T + translation

        return np.concatenate((ego_xyz, points[:, 3:]), axis=1)

    def _lidar_to_nuscenes_sensor_frame(self, points, sensor):
        """
        CARLA-ego-frame points -> right-handed LiDAR sensor frame, i.e. the frame that the
        stored nuScenes calibration (translation/rotation of this sensor) maps back to ego.
        Columns beyond xyz (intensity, ...) are passed through unchanged.
        """
        xyz = points[:, :3] * np.array([1.0, -1.0, 1.0])  # left- to right-handed ego frame
        rotation = self._nuscenes_rotation_matrix(sensor)
        translation = np.array(self._nuscenes_translation(sensor))
        xyz = (rotation.T @ (xyz - translation).T).T

        return np.concatenate((xyz, points[:, 3:]), axis=1)

    @classmethod
    def _box_to_nuscenes(cls, box):
        """
        Convert a bounding box dict from CARLA's left-handed frames to right-handed ones
        (position/matrix: y -> -y, yaw -> -yaw). The world origin of 'matrix' stays
        CARLA's. Non-geometric fields (extent, speed, control values, ...) are unchanged.
        """
        box = dict(box)
        box['position'] = [box['position'][0], -box['position'][1], box['position'][2]]
        box['yaw'] = -box['yaw']
        if 'matrix' in box:
            box['matrix'] = (cls._Y_FLIP @ np.array(box['matrix']) @ cls._Y_FLIP).tolist()

        return box

    def tick(self, input_data):
        result = {}

        if self.save_path is not None and (self.datagen or self.tmp_visu):
            for camera in self.rgb_sensors:
                result[camera['id']] = input_data[camera['id']][1][:, :, :3]
            for camera in self.semseg_sensors:
                result[camera['id']] = input_data[camera['id']][1][:, :, 2]
            for camera in self.depth_sensors:
                # We store depth at 8 bit to reduce the filesize. 16 bit would be ideal, but we can't afford the extra storage.
                depth = input_data[camera['id']][1][:, :, :3]
                result[camera['id']] = (t_u.convert_depth(depth) * 255.0 + 0.5).astype(np.uint8)
            for radar in self.radar_sensors:
                result[radar['id']] = input_data[radar['id']][1]
            for gnss in self.gnss_sensors:
                result[gnss['id']] = input_data[gnss['id']][1]
        else:
            for sensor in (self.rgb_sensors + self.semseg_sensors + self.depth_sensors + self.radar_sensors +
                           self.gnss_sensors):
                result[sensor['id']] = None

        # The 10 Hz LiDAR only delivers half a sweep each time step at 20 Hz.
        # Here we combine the 2 sweeps into the same coordinate system
        if self.last_lidar:
            ego_transform = self._vehicle.get_transform()
            ego_location = ego_transform.location
            last_ego_location = self.last_ego_transform.location
            relative_translation = np.array([
                ego_location.x - last_ego_location.x, ego_location.y - last_ego_location.y,
                ego_location.z - last_ego_location.z
            ])

            ego_yaw = ego_transform.rotation.yaw
            last_ego_yaw = self.last_ego_transform.rotation.yaw
            relative_rotation = np.deg2rad(t_u.normalize_angle_degree(ego_yaw - last_ego_yaw))

            orientation_target = np.deg2rad(ego_yaw)
            # Rotate difference vector from global to local coordinate system.
            rotation_matrix = np.array([[np.cos(orientation_target), -np.sin(orientation_target), 0.0],
                                        [np.sin(orientation_target),
                                        np.cos(orientation_target), 0.0], [0.0, 0.0, 1.0]])
            relative_translation = rotation_matrix.T @ relative_translation

            for lidar in self.lidar_sensors:
                last = self.last_lidar[lidar['id']]
                # Align xyz only; the intensity column is carried over unchanged
                lidar_last_xyz = t_u.algin_lidar(last[:, :3], relative_translation, relative_rotation)
                lidar_last = np.concatenate((lidar_last_xyz, last[:, 3:]), axis=1)
                # Combine back and front half of LiDAR
                result[lidar['id']] = np.concatenate((input_data[lidar['id']], lidar_last), axis=0)
        else:
            for lidar in self.lidar_sensors:
                result[lidar['id']] = input_data[lidar['id']]  # The first frame only has 1 half

        # Bounding box visibility (num_points) is computed against all LiDARs combined
        # (xyz only); without LiDAR, num_points is -1 for every box.
        if self.lidar_sensors:
            lidar_360 = np.concatenate([result[lidar['id']] for lidar in self.lidar_sensors], axis=0)[:, :3]
        else:
            lidar_360 = None

        bounding_boxes = self.get_bounding_boxes(lidar=lidar_360)
        if self.COORDINATE_SYSTEM == 'nuscenes':
            bounding_boxes = [self._box_to_nuscenes(box) for box in bounding_boxes]
        result['bounding_boxes'] = bounding_boxes

        if self.SAVE_BEV_SEMANTICS:
            self.stop_sign_criteria.tick(self._vehicle)
            bev_semantics = self.ss_bev_manager.get_observation(self.close_traffic_lights)
            result['bev_semantics'] = bev_semantics['bev_semantic_classes']

            if self.tmp_visu and self.rgb_sensors:
                self.visualuize(bev_semantics['rendered'], result[self.rgb_sensors[0]['id']])

        return result

    @torch.inference_mode()
    def run_step(self, input_data, timestamp, sensors=None, plant=False):
        self.step_tmp += 1

        # Convert LiDAR into the coordinate frame of the ego vehicle
        for lidar in self.lidar_sensors:
            input_data[lidar['id']] = self.lidar_to_ego_coordinate(input_data[lidar['id']], lidar)

        # Skip DataAgent.run_step (TransFuser rig collection); AutoPilot.run_step drives
        control = super(DataAgent, self).run_step(input_data, timestamp, plant=plant)

        tick_data = self.tick(input_data)

        if self.step % self.config.data_save_freq == 0:
            if self.save_path is not None and self.datagen:
                self.save_sensors(tick_data)

        for lidar in self.lidar_sensors:
            self.last_lidar[lidar['id']] = input_data[lidar['id']]
        self.last_ego_transform = self._vehicle.get_transform()

        if plant:
            # Control contains data when run with plant
            return {**tick_data, **control}
        else:
            return control

    def save_sensors(self, tick_data):
        frame = self.step // self.config.data_save_freq

        # CARLA images are already in opencv's BGR format.
        for camera in self.rgb_sensors:
            cv2.imwrite(str(self.save_path / camera['id'] / (f'{frame:04}.jpg')), tick_data[camera['id']])

        for camera in (self.semseg_sensors + self.depth_sensors):
            cv2.imwrite(str(self.save_path / camera['id'] / (f'{frame:04}.png')), tick_data[camera['id']])

        if self.SAVE_BEV_SEMANTICS:
            cv2.imwrite(str(self.save_path / 'bev_semantics' / (f'{frame:04}.png')), tick_data['bev_semantics'])

        for radar in self.radar_sensors:
            np.save(self.save_path / radar['id'] / (f'{frame:04}.npy'), tick_data[radar['id']])

        for gnss in self.gnss_sensors:
            with open(self.save_path / gnss['id'] / (f'{frame:04}.json'), 'w', encoding='utf-8') as f:
                json.dump(np.asarray(tick_data[gnss['id']]).tolist(), f, indent=4)

        for lidar_sensor in self.lidar_sensors:
            lidar = tick_data[lidar_sensor['id']]
            if self.COORDINATE_SYSTEM == 'nuscenes':
                lidar = self._lidar_to_nuscenes_sensor_frame(lidar, lidar_sensor)

            if self.LIDAR_FORMAT == 'pcd_bin':
                self._save_lidar_pcd_bin(lidar, self.save_path / lidar_sensor['id'] / (f'{frame:04}.pcd.bin'))
            else:
                self._save_lidar_laz(lidar, self.save_path / lidar_sensor['id'] / (f'{frame:04}.laz'))

        with gzip.open(self.save_path / 'boxes' / (f'{frame:04}.json.gz'), 'wt', encoding='utf-8') as f:
            json.dump(tick_data['bounding_boxes'], f, indent=4)

    def _save_lidar_laz(self, lidar, path):
        """Specialized LiDAR compression format (xyz only)."""
        header = laspy.LasHeader(point_format=self.LAZ_POINT_FORMAT)
        header.offsets = np.min(lidar[:, :3], axis=0)
        header.scales = np.array([self.LAZ_POINT_PRECISION, self.LAZ_POINT_PRECISION, self.LAZ_POINT_PRECISION])

        with laspy.open(path, mode='w', header=header) as writer:
            point_record = laspy.ScaleAwarePointRecord.zeros(lidar.shape[0], header=header)
            point_record.x = lidar[:, 0]
            point_record.y = lidar[:, 1]
            point_record.z = lidar[:, 2]

            writer.write_points(point_record)

    @staticmethod
    def _save_lidar_pcd_bin(lidar, path):
        """
        nuScenes-style .pcd.bin: flat float32 records of (x, y, z, intensity, ring_index).
        intensity is CARLA's raw value; ring_index is 0 since CARLA does not expose it.
        """
        width = min(lidar.shape[1], 4)
        points = np.zeros((lidar.shape[0], 5), dtype=np.float32)
        points[:, :width] = lidar[:, :width]
        points.tofile(path)
