# Slice B — 门槛 B 纵向切片

一个独立的多系统 Godot 项目：三张地图、战斗、物品、任务、HUD、版本化存档与导出。
详细里程碑见 `docs/slice-b-plan.md`。

## 快速开始（全新检出，三步）

```powershell
# 1. 同步插件 + 准备素材（幂等：已有素材与存档都不会被动）
powershell -ExecutionPolicy Bypass -File slice_b/setup.ps1

# 2. 打开试玩（或用 Godot 4.7 直接打开 slice_b/project.godot）
& "你的Godot.exe" --path slice_b

# 3. 资源自检（CI 与导出前使用；缺产物时报错并列出清单）
python slice_b/prepare_assets.py --check
```

无需先跑任何测试。天空纹理（`art/sky_*.tres`）随仓库提供；
四个音频片段由 `prepare_assets.py` 幂等合成（参数与 MCP 内容流一致），
不入库以保持仓库无二进制。

## 存档行为

- 启动时自动读取 `user://slice_b_save.json`：有存档即恢复到上次的
  地图、位置、生命、背包、任务与已收集物品；无存档从 L1 新档开始。
- 写入前自动备份上一代（`.bak`）；损坏时回退备份，再不行从新档开始。
- v1 存档自动迁移到当前 schema（见 `scripts/world/game_save.gd`）。

## 导出

导出模板就绪时（`%APPDATA%/Godot/export_templates/<版本>/`）：
`test/integration/test_slice_b_exe_export_flow.py` 走真实 exe 导出；
无模板环境用 PCK 形态（`test_slice_b_export_flow.py`）验证同一条运行链。
