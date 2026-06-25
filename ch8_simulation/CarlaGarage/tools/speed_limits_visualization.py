#%%
import numpy as np
import matplotlib.pyplot as plt

# ---- 読み込み ----
array = np.load('../carla_garage/team_code/speed_limits/Town01_speed_limits.npy', allow_pickle=True)
data = array.item()  # shape=() の object 配列から dict を取り出す

speed_limits: np.ndarray = data['speed_limits']  # shape: (N,)       各ウェイポイントの制限速度 [km/h]
locations:    np.ndarray = data['locations']      # shape: (N, 3)     各ウェイポイントの位置 [UE4座標系: x, y, z(=0)]

N = len(speed_limits)
assert N == len(locations), "speed_limits と locations の長さが不一致"

# ---- 基本統計 ----
print(f"ウェイポイント数 : {N:,}")
print("\n[speed_limits]")
print(f"  dtype   : {speed_limits.dtype}")
print(f"  unique  : {np.unique(speed_limits)}")
print(f"  mean/std: {speed_limits.mean():.1f} / {speed_limits.std():.1f} km/h")

print("\n[locations]  (x, y, z)")
for i, col in enumerate(['x', 'y', 'z']):
    print(f"  {col}: min={locations[:, i].min():.2f}  max={locations[:, i].max():.2f}")

# ---- 可視化: 2D マップ上に制限速度をカラーマップ表示 ----
x, y = locations[:, 0], locations[:, 1]
unique_speeds = np.unique(speed_limits)

if len(unique_speeds) == 1:
    # 速度値が1種類のみ → 単色でウェイポイント分布を表示
    fig, ax = plt.subplots(figsize=(8, 8))
    ax.scatter(x, y, s=0.5, c='steelblue', alpha=0.5)
    ax.set_title(f"Waypoint distribution\n(speed limit: {unique_speeds[0]:.0f} km/h, N={N:,})")
else:
    # 複数の速度値 → カラーマップ表示
    fig, ax = plt.subplots(figsize=(8, 8))
    sc = ax.scatter(x, y, s=0.5, c=speed_limits, cmap='RdYlGn', alpha=0.7)
    plt.colorbar(sc, ax=ax, label='Speed limit [km/h]')
    ax.set_title(f"Speed limit map (N={N:,})")

ax.set_xlabel("UE4 X [cm]")
ax.set_ylabel("UE4 Y [cm]")
ax.set_aspect('equal')
plt.tight_layout()
plt.show()

# %%
