# データ収集用ベースクラス

実用上は、**オリジナルのセンサ構成でデータ収集**したい場合が多いでしょう。

このようなケースに対応するため、データ収集エージェント作成用ベースクラス`GeneralizedDataAgent`を作成しました。

このクラスを継承した自作クラスを作成し、`_sensors`メソッド内にオリジナルのセンサ構成を記述することで、自動運転のプランニングにPDM-Liteを使用したオリジナルのデータ収集エージェントを作成できます。

## 使用方法

`GeneralizedDataAgent`を継承した自作クラスを`team_code/data_agents`フォルダ内に作成し、`COORDINATE_SYSTEM`等の各種クラス定数(詳細は後述)と`_sensors`メソッド内のセンサ構成を記述します。

例えばnuScenes形式でデータを出力するエージェント`data_agent_nuscenes.py`は以下のように作成できます。

```python
from generalized_data_agent import GeneralizedDataAgent

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
        # Camera positions/orientations are the nuScenes rig converted to CARLA coordinates.
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
            # nuScenes LIDAR_TOP mounting position (translation [0.94, 0.0, 1.84] in the nuScenes ego frame).
            'type': 'sensor.lidar.ray_cast',
            'x': 0.94 - REAR_AXLE_TO_CENTER, 'y': 0.0, 'z': 1.84,
            'roll': 0.0, 'pitch': 0.0, 'yaw': 0.0,
            'rotation_frequency': 10,
            'points_per_second': 600000,
            'id': 'LIDAR_TOP'
        }]
```

実行時は、Dockerコンテナ内から以下コマンドを打つことで作成したエージェントを用いたデータ収集が始まります。

```bash
TEAM_AGENT=team_code/data_agents/<作成したAgentのファイル名> \
bash tools/collect_dataset_multi.sh ${CARLA_GARAGE_ROOT}/data
```

例えば上のDataAgentNuScenesを使用する場合、以下を実行します。

```bash
TEAM_AGENT=team_code/data_agents/data_agent_nuscenes.py \
bash tools/collect_dataset_multi.sh ${CARLA_GARAGE_ROOT}/data
```

### クラス定数

自作クラス内で以下のクラス定数を定義することで、保存データの種類やフォーマットを変更することができます（重要な定数は太字で記載）。

|定数名|型|内容|
|---|---|---|
|**`SAVE_BEV_SEMANTICS`**|bool|自車中心BEV形式のセマンティックマップを保存するか選択（TransFuser++等で使用）。これを保存しない場合、UniAD等のマップ情報を使用するモデルではnuScenes map expansion形式のようなセマンティックマップを別途準備する必要がある|
|`BEV_RESOLUTION_WIDTH`|int|`SAVE_BEV_SEMANTICS`有効時のBEVラスタ幅 (pixels)。学習したいモデルと解像度を合わせる必要あり|
|`BEV_RESOLUTION_HEIGHT`|int|`SAVE_BEV_SEMANTICS`有効時のBEVラスタ高さ (pixels)。学習したいモデルと解像度を合わせる必要あり|
|**`LIDAR_FORMAT`**|str ("laz" | "pcd_bin")|LiDARデータの保存形式。`.laz `（CARLA Garage形式）と`.pcd.bin`（nuScenes形式）が選択可能|
|`LAZ_POINT_FORMAT`|int|`LIDAR_FORMAT='laz'`のときに使用するパラメータ|
|`LAZ_POINT_PRECISION`|float|`LIDAR_FORMAT='laz'`のときに使用するパラメータ|
|**`COORDINATE_SYSTEM`**|str ("carla" | "nuscenes")|保存するデータの座標系をCARLA形式かnuScenes形式かを選択する|

#### 保存データの座標系

クラス属性`COORDINATE_SYSTEM`の値を変えることで、以下のように出力される座標系を変更することができます。

- `COORDINATE_SYSTEM="carla"`: CALRAの座標系を使用
- `COORDINATE_SYSTEM="nuscenes"`: nuScenesの座標系を使用

※注意：後述する`measurements`**フォルダ内のメタデータは**`COORDINATE_SYSTEM="nuscenes"`**であってもCARLA座標系で保存されます**

両者は以下のような違いがあります。

||CARLA|nuScenes|
|---|---|---|
|グローバル座標の原点|マップ定義による|basemapの左下端|
|グローバル座標の方向|x:前方, y:右方, z:上方（右手系）|x:前方（basemapの右方）, y:左方（basemapの上方）, z:上方（左手系、一般的な数学でのxyz座標に近い）|
|ローカル座標の原点|後輪の車軸中心|後輪の車軸中心|
|ローカル座標の方向|x:前方, y:右方, z:上方（右手系）|x:前方, y:右方, z:上方（左手系）|

なお、`COORDINATE_SYSTEM="nuscenes"`を指定した場合、グローバル座標の原点はCARLAの原点をそのまま使用します（basemapの作り方によりnuScenesの原点が変わるため）。実際のnuScenes形式データを作成する場合は、**以下のグローバル座標**については**nuScenesの原点とCARLAの原点の差分をオフセットとして差し引く**必要があります。

|保存されるグローバル座標|保存されるファイル|nuScenesでの対応ファイル|
|---|---|---|
|自車位置|`measurements/****.json.gz`の"pos_global"|`ego_pose.json`|
|アノテーション位置|"matrix"||

## 保存データの形式

### センサデータ

各センサデータは以下の形式で保存されます。

|センサの種類|`_sensor()`メソッドに記載する`type`|保存形式|
|---|---|---|
|RGBカメラ|`sensor.camera.rgb`|`<id>/<frame>.jpg`|
|LiDAR|`sensor.lidar.ray_cast`|`<id>/<frame>.laz`または`<id>/<frame>.pcd.bin` (クラス定数`LIDAR_FORMAT`で選択可)|
|RADAR|`sensor.other.radar`|`<id>/<frame>.npy`|
|Depthカメラ|`sensor.camera.depth`|`<id>/<frame>.png` (8bit normalized depth)|
|GNSS|`sensor.other.gnss`|`<id>/<frame>.json`|

### その他の保存情報

`_sensors()`メソッドで指定したセンサデータ以外にも、以下の情報が記録されます

|センサの種類|保存フォルダと形式|内容|
|---|---|---|
|バウンディングボックス|`boxes/<frame>.json.gz`|周囲のアクターのアノテーション情報|
|メタデータ|`measurements/<frame>.json.gz`|自車の状態、ローカル座標系の経路、制御入力、ハザード判定|
|BEVセマンティックマップ|`boxes/<frame>.png`|自車中心BEV形式のセマンティックマップ（クラスIDをそのままモノクロ階調値で保存）。`SAVE_BEV_SEMANTICS=True`のときのみ保存される|

バウンディングボックスとメタデータについて詳細を記述します。

#### バウンディングボックス

1フレーム分のバウンディングボックス（アノテーション）情報が`boxes/<frame>.json.gz`に保存されます。
具体的には以下のフィールドが含まれています（これ以外にもclassに応じたフィールドが入ります）。

| キー | 型 | 意味 |
|---|---:|---|
| `class` | `string` | 物体種別。例: `ego_car`, `car`, `walker`, `static`, `traffic_light`, `stop_sign` |
| `extent` | `float[3]` | bounding box の半径サイズ `[x, y, z]`。CARLA の `bounding_box.extent` |
| `position` | `float[3]` | ego座標系での相対位置 `[x, y, z]` |
| `yaw` | `float` | ego基準の相対yaw角。ラジアン |
| `num_points` | `int` | LiDAR点群がそのbbox内に何点入っているか。egoは`-1` |
| `distance` | `number` | egoからの距離。ego自身は `-1` |
| `speed` | `number` | forward speed |
| `id` | `number` | CARLA actor ID |
| `matrix` | `number[4][4]` | actorのグローバル座標系での4x4 transform matrix |

#### メタデータ

1フレーム分のメタデータが`measurements/<frame>.json.gz`に保存され、自車の状態、ローカル座標系の経路、制御入力、ハザード判定が入っています。
具体的には以下のフィールドが含まれています。

| キー | 型 | このファイルの値/形 | 意味 |
|---|---:|---|---|
| `pos_global` | `number[2]` | `[6435.357..., 4245.204...]` | 自車のグローバル位置 `[x, y]` |
| `theta` | `number` | `-3.04887...` | 自車方位/compass |
| `speed` | `number` | `0.0910...` | 現在速度 |
| `target_speed` | `number` | `10` | 目標速度 |
| `speed_limit` | `number` | `13.888...` | 速度制限 |
| `target_point` | `number[2]` | `[183.704..., 74.183...]` | 自車ローカル座標系の目標点 |
| `target_point_next` | `number[2]` | `[187.413..., 75.897...]` | 次の目標点 |
| `command` | `number` | `4` | RoadOption系のコマンド。`4` は `LANEFOLLOW` |
| `next_command` | `number` | `4` | 次コマンド |
| `aim_wp` | `number[2]` | `[7.713..., 0.128...]` | expert/autopilotが狙う waypoint |
| `route` | `number[20][2]` | 20点 | 自車ローカル座標系の残り経路 |
| `route_original` | `number[20][2]` | 20点 | 元の経路。今回は `route` と同じ |
| `changed_route` | `boolean` | `false` | 経路が変更されたか |
| `steer` | `number` | `0.04` | ステアリング制御 |
| `throttle` | `number` | `1` | スロットル制御 |
| `brake` | `boolean` | `false` | ブレーキ判定 |
| `control_brake` | `boolean` | `false` | 制御上のブレーキ |
| `junction` | `boolean` | `false` | 交差点内/近傍判定 |
| `vehicle_hazard` | `boolean` | `false` | 車両ハザード |
| `light_hazard` | `boolean` | `false` | 赤信号などの信号ハザード |
| `walker_hazard` | `boolean` | `false` | 歩行者ハザード |
| `stop_sign_hazard` | `boolean` | `false` | 一時停止標識ハザード |
| `stop_sign_close` | `boolean` | `false` | 近くに一時停止標識があるか |
| `walker_close` | `boolean` | `false` | 近くに歩行者がいるか |
| `*_id` 系 | `number` or `null` | 今回は `null` | 影響している actor ID |
| `speed_reduced_by_obj_*` | `string/number` or `null` | 今回は全部 `null` | 速度低下要因オブジェクト |
| `angle` | `number` | `0.0106...` | aim point などから来る角度系の値 |
| `augmentation_translation` | `number` | `0` | データ拡張の平行移動量 |
| `augmentation_rotation` | `number` | `0` | データ拡張の回転量 |
| `ego_matrix` | `number[4][4]` | 4x4行列 | CARLAの自車transform行列 |

なお、**このメタデータは**`COORDINATE_SYSTEM="nuscenes"`**であってもCARLA座標系で保存されます**（PDM-Lite自身が走行制御に使う内部表現との整合性を取るため）

よって出力したデータをnuScese形式のjsonに変換したい場合、基本的には`measurements`ではなく`boxes`から情報を取ることが推奨されます（例：`ego_poses.json`は、`measurements`の`ego_matrix`ではなく`boxes`の1レコード目に記録された`ego_car`の`matrix`から変換する）
