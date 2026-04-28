## Bench2Drive シナリオ実行フロー

全体は大きく **5つのフェーズ** に分かれています。

---

### Phase 1: CARLAサーバー起動（別プロセス）

別プロセスで事前にCARLAを起動しておきます（launch_carla_servers.sh等を使用）。後ほど起動するBench2Driveとポート番号（PORTとTM_PORT）を合わせておく必要があります

### Phase 2: ルート分割 & マルチGPUディスパッチ

`run_evaluation_multi_*.sh`がBench2Driveのエントリポイントです。このスクリプトでは以下を実行します。

1. **XMLルート分割**: `split_xml.py`が`bench2drive220.xml`(220ルート定義)をGPU 数(例: 8)に分割
   - 例: `bench2drive220_0_vad_traj.xml`, `bench2drive220_1_vad_traj.xml`, ...
2. **並列起動**: GPU ごとにポートをずらして run_evaluation.sh をバックグラウンド実行
   - `PORT = BASE_PORT + i * 150`
   - `TM_PORT = BASE_TM_PORT + i * 150`

### Phase 3: 評価ループ (leaderboard_evaluator.py)

`run_evaluation.sh` → `leaderboard_evaluator.py`が各GPUで実行されます。

`leaderboard_evaluator.py`

```
main()
 └─ LeaderboardEvaluator.__init__()
     ├── self.client, _, self.traffic_manager = _setup_simulation()  ← carla.Client/client.get_trafficmanager接続 (外部CARLAなしの場合はCARLA起動も)
     ├── importlib.import_module(module_name)  ← uniad_b2d_agent.py等のエージェントモジュール読み込み
     └── self.manager = ScenarioManager  ← ScenarioManager 生成
 └─ LeaderboardEvaluator.run()
     ├── RouteIndexer(routes_file) ← XMLからルート一覧を構築
     ├── resume チェック (途中再開)
     └── while ルートが残っている間:
           └── _load_and_run_scenario(config)  ← 1ルート分の実行
```

**自動リトライ**: run_evaluation.sh に `MAX_RETRIES` ループがあり、CARLA クラッシュ(Signal 11等)時にチェックポイントから再開します。

### Phase 4: 1ルートの実行 (`_load_and_run_scenario`)

これがシナリオ実行の核心部分です。

```
_load_and_run_scenario(config)
 │
 ├── ① ワールドロード
 │    └── _load_and_wait_for_world(town)
 │         ├── client.load_world(town)       ← CARLAマップ切り替え
 │         ├── 同期モード設定 (20Hz固定)
 │         └── CarlaDataProvider 初期化
 │
 ├── ② RouteScenario 構築
 │    └── RouteScenario.__init__()
 │         ├── ルート補間 (interpolate_trajectory)
 │         ├── シナリオフィルタリング (_filter_scenarios)
 │         ├── Ego車両スポーン (vehicle.lincoln.mkz_2020)
 │         ├── 駐車車両スロット取得
 │         ├── Behavior Tree 構築:
 │         │    ├── ScenarioTriggerer (トリガー距離管理)
 │         │    ├── BackgroundBehavior (背景交通)
 │         │    └── 個別シナリオ行動ノード
 │         └── Criteria Tree 構築:
 │              ├── RouteCompletionTest (終了条件)
 │              ├── CollisionTest
 │              ├── RunningRedLightTest
 │              ├── RunningStopTest
 │              ├── OutsideRouteLanesTest
 │              ├── MinimumSpeedRouteTest
 │              ├── InRouteTest
 │              └── ActorBlockedTest (60秒停止で終了)
 │
 ├── ③ エージェントセットアップ
 │    ├── Watchdog 起動 (タイムアウト監視)
 │    ├── agent.setup(config) ← AIモデルのロード
 │    ├── agent.sensors() ← センサー構成取得・検証
 │    └── AgentWrapper.setup_sensors() ← CARLA上にセンサーアタッチ
 │
 ├── ④ シナリオ実行 (ScenarioManager.run_scenario)
 │    ├── build_scenarios_loop スレッド起動
 │    │    └── 1秒ごとに ego 近傍のシナリオを動的初期化
 │    │
 │    └── メインループ (_tick_scenario):
 │         ├── world.tick()                    ← CARLAシミュレーション1ステップ進行
 │         ├── GameTime / CarlaDataProvider 更新
 │         ├── agent_wrapper()                 ← AIに sensor data → control 推論
 │         ├── ego.apply_control(action)       ← 車両制御適用
 │         ├── scenario_tree.tick_once()       ← Behavior Tree 1ステップ
 │         │    ├── ScenarioTriggerer: ego接近でシナリオ発火
 │         │    ├── BackgroundBehavior: 背景車両・歩行者制御
 │         │    └── 各シナリオの個別行動
 │         ├── Criteria 評価
 │         └── ツリーが RUNNING 以外なら終了
 │              (完走 or 違反で早期終了)
 │
 │    ※ tick_count > 4000 でタイムアウト強制終了
 │
 └── ⑤ 後処理
      ├── manager.stop_scenario()
      ├── 統計記録 (_register_statistics)
      └── _cleanup() ← アクター・センサー全削除
```

---

### Phase 5: 結果集計

- 各ルート完了後に `statistics_manager` がチェックポイント JSON (`eval_bench2drive220_*.json`) に記録
- 全ルート完了後に `compute_global_statistics()` でグローバル統計を算出
- 最終的に `merge_statistics.py` 等で複数GPUの結果を統合可能

---

### XMLルートファイルの構造

bench2drive220.xml には **220のルート** が定義されており、各ルートは以下を含みます:

| 要素 | 内容 |
|---|---|
| `<route id="..." town="Town12">` | ルートIDとマップ名 |
| `<waypoints>` | 走行経路のキーポイント (x, y, z) |
| `<scenarios>` | そのルート上で発生するシナリオ (型・トリガー位置・他アクター情報) |
| `<weathers>` | 天候条件 |

---

### シナリオの動的ロードの仕組み

特に重要なのは、シナリオが **一括ロードではなく動的にロード** される点です:

1. `RouteScenario.__init__` で初期近傍シナリオのみ構築
2. `build_scenarios_loop` スレッド (1秒間隔) が ego 車両から **500m 以内** のシナリオを随時初期化
3. `ScenarioTriggerer` が ego が **2m 以内** に接近した時点でシナリオの行動を発火
4. 発火されたシナリオの Behavior Tree ノードが `scenario_tree.tick_once()` で毎フレーム更新

これにより、長いルートでも効率的にシナリオが管理されます。

## 新マップ・シナリオ追加時に必要な対応一覧

CARLAマップ本体（`.umap` / UE4アセット）以外に、以下の **5箇所** を追加・変更する必要があります。

---

### ① ルートXML（必須）

**ファイル**: bench2drive220.xml（または新規XMLファイル）

新しいマップ上のルート定義を追加します：

```xml
<route id="99001" town="YourNewTown">
  <waypoints>
    <position x="..." y="..." z="..." />
    ...
  </waypoints>
  <scenarios>
    <scenario name="ParkingCutIn_99" type="ParkingCutIn">
      <trigger_point x="..." y="..." z="..." yaw="..." />
      <direction value="left" />
    </scenario>
  </scenarios>
  <weathers>
    <weather route_percentage="0" cloudiness="..." ... />
    <weather route_percentage="100" cloudiness="..." ... />
  </weathers>
</route>
```

- ルート作成には **route_creator.py** を使えます（CARLAに接続してGUIでウェイポイントを打つ）
- シナリオ追加には **scenario_creator.py** を使えます（44種のシナリオタイプから選択し、トリガーポイント等を設定）
- `town` 属性は **CARLAの `client.load_world(town)` に渡される名前** と完全一致が必要

#### 座標系について

XMLの `x`, `y`, `z` は **CARLAワールド座標系（Unreal Engine座標系）** です。

| 軸 | 方向 | 単位 |
|---|---|---|
| **x** | 前方（East方向） | メートル (m) |
| **y** | 右方向（South方向） | メートル (m) |
| **z** | 上方向（高度） | メートル (m) |

- **左手座標系**（Unreal Engine準拠）
- 原点はマップの原点（マップ作成時に設定された位置）
- 値の範囲はマップにより異なる（例：Town12 では x, y が数千メートル規模）
- route_parser.py で `carla.Location(x=, y=, z=)` に直接変換されるため、**CARLAのAPIが返す座標そのもの**です

`trigger_point` には追加で `yaw`（度数法、北=0°、時計回り）もあります。

### ② 駐車車両データ（推奨）

**ファイル**: `leaderboard/leaderboard/utils/parked_vehicles.py`

ルート沿いにリアルな駐車車両を配置するため、マップ名と同名の **Python変数** を追加します。

```python
YourNewTown = [
  {
    'tilex': 0, 'tiley': 0,
    'location': (x, y, z),
    'rotation': (pitch, yaw, roll),
    'mesh': '/Game/Carla/Static/Car/4Wheeled/ParkedVehicles/...'
  },
  ...
]
```

- 現在は **Town12** と **Town13** のみ定義済み（合計13,643行）
- 未定義のマップでは `getattr(parked_vehicles, map_name, [])` で **空リスト** が返されるため、エラーにはなりませんが駐車車両がスポーンしません

---

### ③ 背景交通の複雑交差点ハードコード（条件付き）

**ファイル**: background_activity.py の `_get_complex_junctions()` メソッド（L502付近）

新マップに **ラウンドアバウトやガソリンスタンドなど複雑な交差点** がある場合、そのトポロジーをハードコードする必要があります。

```python
elif 'YourNewTown' in self._map.name:
    complex_junctions.append([
        self._map.get_waypoint_xodr(road_id, lane_id, s).get_junction(),
        ...
    ])
```

- 現在は **Town03**（ラウンドアバウト＋ガソリンスタンド）と **Town04**（ガソリンスタンド）のみ定義
- **単純な交差点のみのマップなら対応不要**（BackgroundBehavior はCARLAのOpenDRIVE APIから自動でトポロジーを取得するため）

---

### ④ 天候定義（条件付き）

**ファイル**: weather.xml

- 現在 **24種類** の天候パターン（`weather_id` 0〜26、一部欠番）が定義済み
- leaderboard_evaluator.py の `get_weather_id()` がルートXMLの天候パラメータをこのファイルとマッチングして **天候ID** を取得し、結果の保存名に使用
- **既存の天候パターンを使うなら追加不要**
- 新しい天候パターンを使う場合は `<case weather_id="XX">` を追加。マッチしない場合は ID が `None` になりますが、動作自体は止まりません

---

### ⑤ シナリオクラス（新シナリオタイプの場合のみ）

**ファイル**: `scenario_runner/srunner/scenarios/` 内に新しいPythonファイル

既存の44種のシナリオタイプ（`ParkingCutIn`, `DynamicObjectCrossing` 等）で足りない場合のみ、新しいシナリオクラスを作成します。

- `BasicScenario` を継承
- route_scenario.py の `build_scenarios()` が `srunner/scenarios/*.py` 内のクラスを **自動スキャン** するため、ファイルを置くだけで認識されます
- ルートXMLの `<scenario type="YourNewType">` と一致するクラス名が必要

---

### まとめ表

| 対応箇所 | ファイル | 必須度 | 条件 |
|---|---|:---:|---|
| **ルートXML** | `leaderboard/data/*.xml` | **必須** | 常に |
| **駐車車両データ** | `leaderboard/leaderboard/utils/parked_vehicles.py` | 推奨 | 路上駐車を表現したい場合 |
| **複雑交差点定義** | background_activity.py | 条件付き | ラウンドアバウト等がある場合 |
| **天候パターン** | weather.xml | 条件付き | 新しい天候を使う場合 |
| **シナリオクラス** | `scenario_runner/srunner/scenarios/*.py` | 条件付き | 新しいシナリオタイプを作る場合 |

**最小限の作業** は「①ルートXMLに新マップのルートを追加する」だけで、CARLAマップさえ正しくロードできれば動作します。ただしリアリティのためには②③の対応も推奨されます。

## ルートの作成方法

### 方法① **route_creator.py（公式ツール・最もお薦め）**

Bench2Driveに同梱されている **対話式のルート作成ツール** です。

```bash
# CARLAサーバーを起動した状態で実行
python leaderboard/scripts/route_creator.py -f your_routes.xml <route_id>
```

**使い方：**
1. CARLAサーバーを起動し、対象マップをロード
2. CARLAのSpectator（観察カメラ）を移動して、ウェイポイントにしたい地点に移す
3. ターミナルで `Add` と入力 → **Spectatorの現在位置から最寄りの道路ウェイポイントが自動取得**される
4. これを繰り返して経路を構築
5. `Save` で XMLに保存

**核心コード（`route_creator.py:89-95`）：**
```python
waypoint = tmap.get_waypoint(spectator.get_location())  # 最寄りの道路中心に自動スナップ
draw_keypoint(world, waypoint.transform.location)
points.append(waypoint.transform.location)
```

つまり、**手作業で正確な座標を打つ必要はなく**、カメラをだいたいの位置に持っていくだけで `get_waypoint()` が道路中心線にスナップしてくれます。

### 方法② **scenario_creator.py（シナリオ追加用）**

ルートのウェイポイントと同様に、**Spectatorの位置からtrigger_pointを取得**します。

```bash
python leaderboard/scripts/scenario_creator.py -f your_routes.xml <route_id>
```

シナリオタイプを入力 → Spectatorを移動 → trigger_point と各パラメータが自動取得・保存されます。

### 方法③ **route_displayer.py（確認用）**

作成したルートをCARLA上に可視化して確認できます。

```bash
# 全ルート表示
python leaderboard/scripts/route_displayer.py -f your_routes.xml -sa

# 特定ルートをキーポイント＋シナリオ付きで表示
python leaderboard/scripts/route_displayer.py -f your_routes.xml -sr <route_id> -sk -ss
```

### 方法④ **PythonAPIで座標をプログラム的に取得**

スクリプトでまとめて座標を生成したい場合：

```python
import carla

client = carla.Client('localhost', 2000)
world = client.get_world()
tmap = world.get_map()

# 全スポーンポイント（交差点付近の代表的な位置）を取得
spawn_points = tmap.get_spawn_points()
for sp in spawn_points:
    print(f"x={sp.location.x:.1f}, y={sp.location.y:.1f}, z={sp.location.z:.1f}")

# 任意の座標から最寄りの道路ウェイポイントを取得
wp = tmap.get_waypoint(carla.Location(x=-497.6, y=3672.9, z=364.9))
print(wp.transform.location)  # 道路中心線にスナップされた正確な座標

# A*で2点間の経路を自動生成
from agents.navigation.global_route_planner import GlobalRoutePlanner
grp = GlobalRoutePlanner(tmap, 2.0)
route = grp.trace_route(spawn_points[0].location, spawn_points[10].location)
for wp, road_option in route:
    print(f"x={wp.transform.location.x:.1f}, y={wp.transform.location.y:.1f}")
```

---

### まとめ：推奨ワークフロー

| ステップ | ツール | 操作 |
|---|---|---|
| 1. 空のXMLを作成 | 手作業 | `<routes><route id="1" town="Town12"><waypoints/><scenarios/><weathers>...</weathers></route></routes>` |
| 2. ルートのウェイポイント追加 | **route_creator.py** | Spectatorでカメラ移動 → `Add` → `Save` |
| 3. ルートの可視化確認 | **route_displayer.py** | `-sr <id> -sk -ss` で確認 |
| 4. シナリオのtrigger_point追加 | **scenario_creator.py** | Spectatorでカメラ移動 → シナリオタイプ入力 → 保存 |
| 5. 天候の追加 | **`weather_creator.py`** or 手作業 | XMLに weather エントリを追加 |

**重要なポイント：** すべてのツールが内部で `tmap.get_waypoint(spectator.get_location())` を使って**道路中心線への自動スナップ**を行うため、座標を手入力する必要はありません。CARLAサーバーを起動してSpectatorカメラを動かすだけで正確な座標が得られます。
