import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
MCP_URL = os.environ.get("GODOT_MCP_URL", "http://127.0.0.1:9080/mcp")
REQUIRE_EXPORT = os.environ.get("P4_2D_GATE_REQUIRE_EXPORT", "0") == "1"
CALLED_TOOLS: list[str] = []
_request_id = 0


TWO_D_DOMAIN = {
    "create_tileset", "inspect_tileset_resource", "configure_tileset_layers",
    "set_tile_collision_polygon", "set_tile_terrain", "set_tilemap_layer_cells",
    "get_tilemap_layer_cells", "list_runtime_tilemap_layers", "set_runtime_tilemap_cell",
    "get_runtime_tilemap_cell", "slice_sprite_sheet", "create_drawable_texture",
    "create_gradient_texture", "draw_on_texture", "set_collision_one_way",
}


MAIN_SCRIPT = '''extends Node2D

var score := 0
var won := false
var dash_count := 0
var start_position := Vector2(120, 300)
@onready var player: CharacterBody2D = $Player
@onready var status: Label = $UI/HUD/Panel/Status

func _ready() -> void:
    player.position = start_position
    var library := AnimationLibrary.new()
    var pulse := load("res://animations/player_pulse.tres") as Animation
    if pulse:
        library.add_animation("pulse", pulse)
        $AnimationPlayer.add_animation_library("", library)
        $AnimationPlayer.play("pulse")
    $Audio.play()
    _refresh()

func _physics_process(_delta: float) -> void:
    var direction := Input.get_vector("move_left", "move_right", "move_up", "move_down")
    player.velocity = direction * 190.0
    player.move_and_slide()
    if Input.is_action_just_pressed("dash"):
        player.position += direction * 55.0
        dash_count += 1
    $Hazard.position.y = 300.0 + sin(Time.get_ticks_msec() / 350.0) * 90.0
    if Input.is_action_just_pressed("restart"):
        score = 0
        won = false
        player.position = start_position
        for pickup in get_tree().get_nodes_in_group("pickup"):
            pickup.visible = true
            pickup.set_deferred("monitoring", true)
    _refresh()

func _on_pickup_body_entered(body: Node) -> void:
    if body != player or won:
        return
    for pickup in get_tree().get_nodes_in_group("pickup"):
        if pickup.visible and pickup.global_position.distance_to(player.global_position) < 75.0:
            pickup.visible = false
            pickup.set_deferred("monitoring", false)
            score += 1
            break
    won = score >= 3
    _refresh()

func _on_hazard_body_entered(body: Node) -> void:
    if body == player:
        player.position = start_position
        player.velocity = Vector2.ZERO

func _on_pause_pressed() -> void:
    $UI/HUD/Panel/Hint.text = "Signal path verified"

func _refresh() -> void:
    status.text = "2D Gate Lab • Orbs %d/3 • Dash %d" % [score, dash_count]
'''


DATA_SCRIPT = '''class_name GateItemData
extends Resource
@export var id: String = ""
@export var display_name: String = ""
@export var value: int = 1
@export var tint: Color = Color.WHITE
'''


def next_id() -> int:
    global _request_id
    _request_id += 1
    return _request_id


def rpc_call(method: str, params: dict | None = None) -> dict:
    payload = {"jsonrpc": "2.0", "method": method, "params": params or {}, "id": next_id()}
    request = urllib.request.Request(
        MCP_URL,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.loads(response.read().decode("utf-8"))


def decode_result(result: dict) -> dict:
    if "structuredContent" in result:
        return result["structuredContent"]
    content = result.get("content", [])
    if not content:
        return {}
    text = content[0].get("text", "")
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return {"text": text}


def tool_call(name: str, arguments: dict | None = None, allow_error: bool = False) -> dict:
    CALLED_TOOLS.append(name)
    response = rpc_call("tools/call", {"name": name, "arguments": arguments or {}})
    if "error" in response:
        if allow_error:
            return {"rpc_error": response["error"]}
        raise AssertionError(f"RPC error calling {name}: {response['error']}")
    result = response["result"]
    decoded = decode_result(result)
    if result.get("isError") and not allow_error:
        raise AssertionError(f"Tool {name} failed: {decoded}")
    if result.get("isError"):
        decoded["_tool_error"] = True
    return decoded


def wait_for_server(timeout_seconds: float = 45.0) -> None:
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        try:
            rpc_call("tools/list")
            return
        except Exception:
            time.sleep(0.5)
    raise TimeoutError("Timed out waiting for MCP server")


def resolve_godot() -> str:
    if os.environ.get("GODOT_BIN"):
        return os.environ["GODOT_BIN"]
    if shutil.which("godot"):
        return shutil.which("godot") or "godot"
    for candidate in [
        r"C:\SourceCode\Godot_v4.7.2-stable_win64\Godot_v4.7.2-stable_win64.exe",
        r"C:\SourceCode\Godot_v4.7.2-stable_mono_win64\Godot_v4.7.2-stable_mono_win64_console.exe",
        r"C:\SourceCode\Godot_v4.6.2-stable_mono_win64\Godot_v4.6.2-stable_mono_win64_console.exe",
    ]:
        if Path(candidate).exists():
            return candidate
    raise FileNotFoundError("Set GODOT_BIN to Godot 4.7")


def prepare_project(project_dir: Path) -> None:
    shutil.copytree(REPO_ROOT / "addons" / "godot_mcp", project_dir / "addons" / "godot_mcp")
    (project_dir / "project.godot").write_text(
        '''[application]\nconfig/name="P4 2D Gate Lab"\nconfig/features=PackedStringArray("4.7", "GL Compatibility")\n\n[display]\nwindow/size/viewport_width=960\nwindow/size/viewport_height=540\nwindow/size/window_width_override=960\nwindow/size/window_height_override=540\n\n[editor_plugins]\nenabled=PackedStringArray("res://addons/godot_mcp/plugin.cfg")\n\n[rendering]\nrenderer/rendering_method="gl_compatibility"\nrenderer/rendering_method.mobile="gl_compatibility"\n''',
        encoding="utf-8",
    )


def build_game(report: dict) -> None:
    tool_call("enable_tools", {"preset": "all"})
    for name, args in [
        ("get_project_info", {}), ("get_project_structure", {"max_depth": 2}),
        ("list_project_scenes", {}), ("list_project_scripts", {}), ("list_project_resources", {"limit": 100}),
    ]:
        tool_call(name, args)

    for path, kind, prompt, pattern, colors, size in [
        ("res://art/tile.png", "texture", "checker floor tile", "checker", ["#26334fff", "#3a5a72ff"], 64),
        ("res://art/player.png", "sprite", "cyan player icon", "frame", ["#55e6ffff", "#15384aff"], 48),
        ("res://art/orb.png", "sprite", "gold orb", "circle", ["#ffd95cff", "#fff5bdff"], 32),
        ("res://art/hazard.png", "sprite", "red hazard", "frame", ["#ff5d6cff", "#5a1822ff"], 48),
    ]:
        tool_call("generate_asset", {"provider": "placeholder", "type": kind, "prompt": prompt, "resource_path": path,
                                     "width": size, "height": size, "pattern": pattern, "colors": colors, "reimport": True})
    tool_call("generate_asset", {"provider": "placeholder", "type": "tone", "prompt": "success beep",
                                 "resource_path": "res://audio/beep.wav", "duration": 0.12, "frequency": 660.0, "waveform": "sine"})
    tool_call("create_gradient_texture", {"resource_path": "res://art/background.tres", "width": 960, "height": 540,
                                          "colors": [{"offset": 0, "color": "#10182cff"}, {"offset": 1, "color": "#193d54ff"}]})
    tool_call("create_drawable_texture", {"resource_path": "res://art/composite.tres", "width": 128, "height": 64,
                                          "color": {"r": 0.04, "g": 0.07, "b": 0.12, "a": 1.0}})
    tool_call("draw_on_texture", {"resource_path": "res://art/composite.tres", "operations": [
        {"source_path": "res://art/player.png", "rect": {"x": 8, "y": 8, "w": 48, "h": 48}},
        {"source_path": "res://art/orb.png", "rect": {"x": 80, "y": 16, "w": 32, "h": 32}},
    ]})
    tool_call("slice_sprite_sheet", {"texture_path": "res://art/tile.png", "h_frames": 1, "v_frames": 1,
                                     "output_path": "res://art/tile_frames.tres", "create_scene": True,
                                     "scene_output_path": "res://scenes/tile_preview.tscn"})
    tool_call("reimport_resources", {"resource_paths": ["res://art/tile.png", "res://art/player.png"]})
    tool_call("get_import_metadata", {"resource_path": "res://art/player.png"})

    tileset = tool_call("create_tileset", {"tileset_path": "res://tiles/gate_tileset.tres", "texture_path": "res://art/tile.png",
                                           "tile_size": [64, 64], "texture_region_size": [64, 64]})
    source_id = int(tileset.get("source_id", 0))
    tool_call("configure_tileset_layers", {"tileset_path": "res://tiles/gate_tileset.tres",
        "physics_layers": [{"collision_layer": 1, "collision_mask": 1}], "navigation_layers": [{"layers": 1}],
        "custom_data_layers": [{"name": "surface", "type": 4}],
        "terrain_sets": [{"mode": "corners_and_sides", "terrains": [{"name": "floor", "color": "#4c7c8cff"}]}]})
    tool_call("set_tile_collision_polygon", {"tileset_path": "res://tiles/gate_tileset.tres", "source_id": source_id,
                                             "tile_coords": [0, 0], "physics_layer": 0})
    tool_call("set_tile_terrain", {"tileset_path": "res://tiles/gate_tileset.tres", "source_id": source_id,
                                   "tile_coords": [0, 0], "terrain_set": 0, "terrain": 0})
    tool_call("inspect_tileset_resource", {"resource_path": "res://tiles/gate_tileset.tres"})

    tool_call("create_resource", {"resource_path": "res://ui/panel_style.tres", "resource_type": "StyleBoxFlat",
        "properties": {"bg_color": "#18233cdd", "corner_radius_top_left": 14, "corner_radius_top_right": 14,
                       "corner_radius_bottom_left": 14, "corner_radius_bottom_right": 14}})
    tool_call("create_theme", {"theme_path": "res://ui/gate_theme.tres", "default_font_size": 18})
    for item in [
        {"item_type": "color", "theme_type": "Label", "item_name": "font_color", "value": "#e9fbffff"},
        {"item_type": "font_size", "theme_type": "Label", "item_name": "font_size", "value": 18},
        {"item_type": "stylebox", "theme_type": "Panel", "item_name": "panel", "value": "res://ui/panel_style.tres"},
    ]:
        tool_call("set_theme_item", {"theme_path": "res://ui/gate_theme.tres", **item})
    tool_call("set_default_theme", {"theme_path": "res://ui/gate_theme.tres"})

    tool_call("create_script", {"script_path": "res://data/gate_item_data.gd", "content": DATA_SCRIPT})
    tool_call("create_custom_resource", {"resource_path": "res://data/player_config.tres", "script_path": "res://data/gate_item_data.gd",
        "properties": {"id": "player", "display_name": "Gate Runner", "value": 3, "tint": "#55e6ffff"}})
    tool_call("batch_create_resources", {"base_path": "res://data/items/", "script_path": "res://data/gate_item_data.gd",
        "resources": [{"name": "orb_a", "properties": {"id": "a"}}, {"name": "orb_b", "properties": {"id": "b"}},
                      {"name": "orb_c", "properties": {"id": "c"}}]})
    tool_call("read_resource_properties", {"resource_path": "res://data/player_config.tres"})
    tool_call("update_resource_properties", {"resource_path": "res://data/player_config.tres", "properties": {"value": 4}})

    keymap = {"move_left": 65, "move_right": 68, "move_up": 87, "move_down": 83, "dash": 4194325, "restart": 82}
    for action, keycode in keymap.items():
        tool_call("upsert_project_input_action", {"action_name": action, "deadzone": 0.2, "erase_existing": True,
                                                  "events": [{"type": "key", "keycode": keycode, "pressed": True}]})
    tool_call("list_project_input_actions", {})

    tool_call("create_scene", {"scene_path": "res://scenes/Main.tscn", "root_node_type": "Node2D"})
    tool_call("open_scene", {"scene_path": "res://scenes/Main.tscn", "allow_ui_focus": True})
    tool_call("create_script", {"script_path": "res://scripts/main.gd", "content": MAIN_SCRIPT})
    tool_call("attach_script", {"node_path": "/root/Main", "script_path": "res://scripts/main.gd"})
    ops = [
        ("/root/Main", "Sprite2D", "Background"), ("/root/Main", "TileMapLayer", "Ground"),
        ("/root/Main", "TileMap", "LegacyTileMap"), ("/root/Main", "CharacterBody2D", "Player"),
        ("/root/Main/Player", "Sprite2D", "Sprite"), ("/root/Main/Player", "CollisionShape2D", "CollisionShape2D"),
        ("/root/Main", "Area2D", "PickupTemplate"), ("/root/Main/PickupTemplate", "Sprite2D", "Sprite"),
        ("/root/Main/PickupTemplate", "CollisionShape2D", "CollisionShape2D"), ("/root/Main", "Area2D", "Hazard"),
        ("/root/Main/Hazard", "Sprite2D", "Sprite"), ("/root/Main/Hazard", "CollisionShape2D", "CollisionShape2D"),
        ("/root/Main", "StaticBody2D", "OneWayPlatform"), ("/root/Main/OneWayPlatform", "CollisionShape2D", "CollisionShape2D"),
        ("/root/Main", "AnimationPlayer", "AnimationPlayer"), ("/root/Main", "AudioStreamPlayer", "Audio"),
        ("/root/Main", "CanvasLayer", "UI"), ("/root/Main/UI", "Control", "HUD"),
        ("/root/Main/UI/HUD", "Panel", "Panel"), ("/root/Main/UI/HUD/Panel", "Label", "Status"),
        ("/root/Main/UI/HUD/Panel", "Label", "Hint"), ("/root/Main/UI/HUD/Panel", "Button", "PauseButton"),
    ]
    tool_call("batch_scene_node_edits", {"label": "Build P4 2D Gate Lab", "operations": [
        {"type": "create", "parent_path": p, "node_type": t, "node_name": n} for p, t, n in ops
    ]})
    tool_call("create_node", {"parent_path": "/root/Main", "node_type": "Node2D", "node_name": "Marker"})
    tool_call("rename_node", {"node_path": "/root/Main/Marker", "new_name": "GateMarker"})
    tool_call("duplicate_node", {"node_path": "/root/Main/GateMarker", "new_name": "GateMarkerCopy"})
    tool_call("move_node", {"node_path": "/root/Main/GateMarkerCopy", "new_parent_path": "/root/Main/UI"})

    changes = [
        ("/root/Main/Background", "texture", "res://art/background.tres"), ("/root/Main/Background", "position", [480, 270]),
        ("/root/Main/Ground", "tile_set", "res://tiles/gate_tileset.tres"), ("/root/Main/LegacyTileMap", "tile_set", "res://tiles/gate_tileset.tres"),
        ("/root/Main/Player", "position", [120, 300]), ("/root/Main/Player/Sprite", "texture", "res://art/player.png"),
        ("/root/Main/PickupTemplate/Sprite", "texture", "res://art/orb.png"), ("/root/Main/Hazard", "position", [700, 300]),
        ("/root/Main/Hazard/Sprite", "texture", "res://art/hazard.png"), ("/root/Main/Audio", "stream", "res://audio/beep.wav"),
        ("/root/Main/UI/HUD/Panel/Status", "text", "2D Gate Lab"), ("/root/Main/UI/HUD/Panel/Hint", "text", "WASD move • Shift dash"),
        ("/root/Main/UI/HUD/Panel/PauseButton", "text", "Signal Test"),
    ]
    tool_call("batch_update_node_properties", {"changes": [
        {"node_path": p, "property_name": k, "property_value": v} for p, k, v in changes
    ]})
    for path, typ, props in [
        ("/root/Main/Player/CollisionShape2D", "CircleShape2D", {"radius": 22}),
        ("/root/Main/PickupTemplate/CollisionShape2D", "CircleShape2D", {"radius": 18}),
        ("/root/Main/Hazard/CollisionShape2D", "CircleShape2D", {"radius": 24}),
        ("/root/Main/OneWayPlatform/CollisionShape2D", "RectangleShape2D", {"size": [300, 24]}),
    ]:
        tool_call("set_node_subresource", {"node_path": path, "property_name": "shape", "resource_type": typ, "properties": props})
        tool_call("get_node_subresource", {"node_path": path, "property_name": "shape"})
    tool_call("set_collision_one_way", {"node_path": "/root/Main/OneWayPlatform/CollisionShape2D", "enabled": True, "margin": 4.0})
    tool_call("set_anchor_preset", {"node_path": "/root/Main/UI/HUD", "preset": 15})
    tool_call("set_control_offset_transform", {"node_path": "/root/Main/UI/HUD/Panel", "enabled": True,
                                               "position": {"x": 24, "y": 24}, "visual_only": False})

    cells = [{"coords": [x, 7], "source_id": source_id, "atlas_coords": [0, 0], "alternative": 0} for x in range(15)]
    tool_call("set_tilemap_layer_cells", {"node_path": "/root/Main/Ground", "cells": cells})
    painted = tool_call("get_tilemap_layer_cells", {"node_path": "/root/Main/Ground"})
    if painted.get("cell_count", 0) < 15:
        raise AssertionError(f"Ground paint incomplete: {painted}")

    tool_call("set_node_groups", {"node_path": "/root/Main/Player", "groups": ["player"], "persistent": True})
    tool_call("find_nodes_in_group", {"group": "player"})
    tool_call("get_node_groups", {"node_path": "/root/Main/Player"})
    tool_call("save_branch_as_scene", {"node_path": "/root/Main/PickupTemplate", "scene_path": "res://scenes/Pickup.tscn"})
    tool_call("delete_node", {"node_path": "/root/Main/PickupTemplate"})
    for name, x in [("PickupA", 250), ("PickupB", 380), ("PickupC", 510)]:
        tool_call("instantiate_scene", {"scene_path": "res://scenes/Pickup.tscn", "parent_path": "/root/Main", "instance_name": name})
        tool_call("update_node_property", {"node_path": f"/root/Main/{name}", "property_name": "position", "property_value": [x, 300]})
        tool_call("set_node_groups", {"node_path": f"/root/Main/{name}", "groups": ["pickup"], "persistent": True})
    tool_call("batch_connect_signals", {"connections": [
        {"emitter_path": f"/root/Main/{n}", "signal_name": "body_entered", "receiver_path": "/root/Main",
         "receiver_method": "_on_pickup_body_entered"} for n in ("PickupA", "PickupB", "PickupC")
    ]})
    tool_call("connect_signal", {"emitter_path": "/root/Main/Hazard", "signal_name": "body_entered",
                                 "receiver_path": "/root/Main", "receiver_method": "_on_hazard_body_entered"})
    tool_call("connect_signal", {"emitter_path": "/root/Main/UI/HUD/Panel/PauseButton", "signal_name": "pressed",
                                 "receiver_path": "/root/Main", "receiver_method": "_on_pause_pressed"})
    tool_call("get_signals", {"node_path": "/root/Main/Hazard"})
    tool_call("disconnect_signal", {"emitter_path": "/root/Main/UI/HUD/Panel/PauseButton", "signal_name": "pressed",
                                    "receiver_path": "/root/Main", "receiver_method": "_on_pause_pressed"})
    tool_call("connect_signal", {"emitter_path": "/root/Main/UI/HUD/Panel/PauseButton", "signal_name": "pressed",
                                 "receiver_path": "/root/Main", "receiver_method": "_on_pause_pressed"})

    tool_call("create_animation", {"animation_path": "res://animations/player_pulse.tres", "length": 0.8, "loop_mode": "pingpong"})
    tool_call("insert_animation_keys", {"animation_path": "res://animations/player_pulse.tres", "track_path": "Player:scale",
        "track_type": "value", "value_type": "vector2", "keys": [{"time": 0, "value": [1, 1]},
        {"time": 0.4, "value": [1.12, 1.12]}, {"time": 0.8, "value": [1, 1]}]})

    tool_call("save_scene", {})
    for name, args in [
        ("get_current_scene", {}), ("get_scene_structure", {"max_depth": -1}), ("get_scene_tree", {"max_depth": -1}),
        ("list_nodes", {"recursive": True}), ("audit_scene_node_persistence", {}), ("audit_scene_inheritance", {}),
        ("analyze_script", {"script_path": "res://scripts/main.gd"}),
        ("validate_script", {"script_path": "res://scripts/main.gd"}),
        ("verify_scripts", {"script_paths": ["res://scripts/main.gd", "res://data/gate_item_data.gd"]}),
    ]:
        result = tool_call(name, args)
        if name == "verify_scripts" and result.get("failed", 0):
            raise AssertionError(f"Script verification failed: {result}")

    tool_call("manage_localization", {"action": "extract", "scan_dir": "res://", "csv_path": "res://localization/translations.csv"})
    tool_call("manage_localization", {"action": "import", "csv_path": "res://localization/translations.csv", "out_dir": "res://localization"})
    tool_call("manage_localization", {"action": "list"})
    tool_call("set_project_setting", {"setting": "application/run/main_scene", "value": "res://scenes/Main.tscn", "value_type": "string"})
    tool_call("install_runtime_probe", {})
    tool_call("get_editor_screenshot", {"viewport_type": "2d", "format": "png", "save_path": "res://evidence/editor.png"})
    report["build_gate"] = "passed"


def runtime_gate(report: dict) -> None:
    tool_call("run_project", {"allow_window": True})
    tool_call("await_scene_ready", {"scene_name": "Main", "timeout_sec": 12})
    tool_call("get_runtime_info", {})
    tool_call("get_runtime_scene_tree", {"max_depth": 7})
    tool_call("inspect_runtime_node", {"node_path": "/root/Main/Player"})
    tool_call("evaluate_runtime_expression", {"node_path": "/root/Main", "expression": "score"})
    tool_call("list_runtime_input_actions", {})
    tool_call("upsert_runtime_input_action", {"action_name": "mcp_gate_action", "erase_existing": True,
                                              "events": [{"type": "key", "keycode": 71, "pressed": True}]})
    tool_call("simulate_runtime_input_event", {"event": {"type": "key", "keycode": 71, "pressed": True}})

    play = tool_call("play_and_verify", {"deterministic": True, "frame_type": "physics", "timeout_ms": 5000,
        "steps": [{"action": "move_right", "pressed": True, "wait_frames": 150, "screenshot": True},
                  {"action": "move_right", "pressed": False, "wait_frames": 2},
                  {"action": "dash", "pressed": True, "wait_frames": 1}, {"action": "dash", "pressed": False, "wait_frames": 1}],
        "assertions": [{"expression": "position.x > 200", "node_path": "/root/Main/Player"},
                       {"expression": "score == 3", "node_path": "/root/Main"},
                       {"expression": "won", "node_path": "/root/Main"},
                       {"expression": "dash_count >= 1", "node_path": "/root/Main"}],
        "screenshot_dir": "res://evidence/play", "screenshot_format": "png", "fail_on_runtime_error": True})
    if not play.get("passed", False):
        raise AssertionError(f"Playable gate failed: {play}")

    tool_call("list_runtime_tilemap_layers", {"node_path": "/root/Main/LegacyTileMap"})
    tool_call("set_runtime_tilemap_cell", {"node_path": "/root/Main/LegacyTileMap", "layer": 0,
                                           "coords": {"x": 2, "y": 2}, "source_id": 0,
                                           "atlas_coords": {"x": 0, "y": 0}})
    tool_call("get_runtime_tilemap_cell", {"node_path": "/root/Main/LegacyTileMap", "layer": 0, "coords": {"x": 2, "y": 2}})
    tool_call("create_runtime_node", {"parent_path": "/root/Main", "node_type": "Node2D", "node_name": "RuntimeMarker"})
    tool_call("update_runtime_node_property", {"node_path": "/root/Main/RuntimeMarker", "property_name": "position", "property_value": [42, 42]})
    tool_call("delete_runtime_node", {"node_path": "/root/Main/RuntimeMarker"})

    tool_call("get_runtime_theme_item", {"node_path": "/root/Main/UI/HUD/Panel/Status", "item_type": "color",
                                         "item_name": "font_color", "theme_type": "Label"})
    tool_call("set_runtime_theme_override", {"node_path": "/root/Main/UI/HUD/Panel/Status", "item_type": "color",
                                             "item_name": "font_color", "theme_type": "Label", "value": "#ffec7aff"})
    tool_call("clear_runtime_theme_override", {"node_path": "/root/Main/UI/HUD/Panel/Status", "item_type": "color",
                                               "item_name": "font_color", "theme_type": "Label"})
    tool_call("list_runtime_animations", {"node_path": "/root/Main/AnimationPlayer"})
    tool_call("play_runtime_animation", {"node_path": "/root/Main/AnimationPlayer", "animation_name": "pulse"})
    tool_call("get_runtime_animation_state", {"node_path": "/root/Main/AnimationPlayer"})
    tool_call("stop_runtime_animation", {"node_path": "/root/Main/AnimationPlayer"})
    tool_call("list_runtime_audio_buses", {})
    tool_call("get_runtime_audio_bus", {"bus_name": "Master"})
    tool_call("update_runtime_audio_bus", {"bus_name": "Master", "volume_db": -3.0})
    tool_call("update_runtime_audio_bus", {"bus_name": "Master", "volume_db": 0.0})

    tool_call("get_runtime_screenshot", {"save_path": "res://evidence/runtime.png", "format": "png"})
    tool_call("assert_visual_baseline", {"baseline_path": "res://evidence/golden.png", "candidate_path": "res://evidence/runtime.png",
                                         "update_baseline": True})
    visual = tool_call("assert_visual_baseline", {"baseline_path": "res://evidence/golden.png", "candidate_path": "res://evidence/runtime.png"})
    if visual.get("passed") is False:
        raise AssertionError(f"Visual gate failed: {visual}")

    snapshot = tool_call("get_runtime_performance_snapshot", {})
    memory = tool_call("get_runtime_memory_trend", {"sample_count": 5, "sample_interval_ms": 80})
    impossible = tool_call("assert_performance_budget", {"snapshot": snapshot, "budget": {"min_fps": 100000}})
    if impossible.get("passed", True):
        raise AssertionError("Impossible performance budget falsely passed")
    sane = tool_call("assert_performance_budget", {"snapshot": snapshot,
                                                    "budget": {"min_fps": 1, "max_memory_mb": 4096, "max_node_count": 10000}})
    if sane.get("passed") is False:
        raise AssertionError(f"Safety performance gate failed: {sane}")
    negative = tool_call("assert_runtime_condition", {"node_path": "/root/Main", "expression": "score > 999", "timeout_ms": 250})
    if negative.get("passed", True):
        raise AssertionError("Impossible runtime assertion falsely passed")
    tool_call("assert_runtime_condition", {"node_path": "/root/Main", "expression": "won", "timeout_ms": 1000})
    no_errors = tool_call("assert_no_runtime_errors", {"categories": ["stderr"], "count": 500})
    if no_errors.get("passed") is False:
        raise AssertionError(f"Runtime errors found: {no_errors}")
    report["runtime_baseline"] = {"performance": snapshot, "memory": memory}
    report["runtime_gate"] = "passed"
    tool_call("stop_project", {"allow_window": True})


def fault_gate(project_dir: Path, report: dict) -> None:
    faults = project_dir / "faults"
    faults.mkdir(parents=True, exist_ok=True)
    (faults / "broken.gd").write_text("extends Node\nfunc broken(\n    return 1\n", encoding="utf-8")
    (faults / "missing.tscn").write_text('[gd_scene load_steps=2 format=3]\n[ext_resource type="Script" path="res://faults/nope.gd" id="1"]\n[node name="Broken" type="Node"]\nscript=ExtResource("1")\n', encoding="utf-8")
    (faults / "a.tscn").write_text('[gd_scene load_steps=2 format=3]\n[ext_resource type="PackedScene" path="res://faults/b.tscn" id="1"]\n[node name="A" type="Node"]\n[node name="B" parent="." instance=ExtResource("1")]\n', encoding="utf-8")
    (faults / "b.tscn").write_text('[gd_scene load_steps=2 format=3]\n[ext_resource type="PackedScene" path="res://faults/a.tscn" id="1"]\n[node name="B" type="Node"]\n[node name="A" parent="." instance=ExtResource("1")]\n', encoding="utf-8")
    tool_call("reload_project", {"full_scan": True})
    broken = tool_call("detect_broken_scripts", {"search_path": "res://faults", "max_results": 20})
    missing = tool_call("scan_missing_resource_dependencies", {"search_path": "res://faults", "max_results": 20})
    cycles = tool_call("scan_cyclic_resource_dependencies", {"search_path": "res://faults", "max_results": 20})
    health = tool_call("audit_project_health", {"search_path": "res://faults", "max_results": 50})
    if broken.get("broken_count", 0) < 1 or health.get("status") != "failing":
        raise AssertionError(f"Negative health gate failed: {broken} {health}")
    if missing.get("issue_count", missing.get("missing_count", 0)) < 1 or cycles.get("issue_count", 0) < 1:
        raise AssertionError(f"Dependency faults escaped gate: {missing} {cycles}")
    report["negative_gate"] = {"broken": broken.get("broken_count", 0),
        "missing": missing.get("issue_count", missing.get("missing_count", 0)), "cycles": cycles.get("issue_count", 0)}
    shutil.rmtree(faults)
    tool_call("reload_project", {"full_scan": True})
    good = tool_call("audit_project_health", {"search_path": "res://", "max_results": 100})
    if good.get("status") == "failing":
        raise AssertionError(f"Health did not recover: {good}")
    tool_call("find_deprecated_api_usage", {"search_path": "res://", "limit": 200})
    tool_call("scan_migration_compatibility", {"search_path": "res://", "target_version": "4.7", "limit": 200})
    tool_call("list_unused_resources", {"search_path": "res://", "limit": 200})
    uid = tool_call("get_resource_uid_info", {"resource_path": "res://scenes/Main.tscn"})
    if not uid.get("uid"):
        tool_call("fix_resource_uid", {"resource_path": "res://scenes/Main.tscn"})
    report["health_gate"] = "passed"


def shipping_probe(report: dict) -> None:
    presets = tool_call("list_export_presets", {})
    templates = tool_call("inspect_export_templates", {})
    gaps: list[str] = []
    if presets.get("count", 0) < 1:
        gaps.append("no_export_preset")
    if not templates.get("matching_version_installed", False):
        gaps.append("missing_export_templates")
    shipping = {"status": "observed", "gaps": gaps, "preset_count": presets.get("count", 0),
                "matching_templates": templates.get("matching_version_installed", False)}
    if REQUIRE_EXPORT:
        if gaps:
            shipping["status"] = "blocked"
            report["shipping_gate"] = shipping
            raise AssertionError(f"Required shipping gate blocked: {shipping}")
        preset = presets["presets"][0]["name"]
        tool_call("validate_export_preset", {"preset": preset})
        tool_call("run_export", {"preset": preset, "mode": "release"})
        smoke = tool_call("smoke_test_export", {"preset": preset, "launch": True})
        if smoke.get("passed") is False:
            raise AssertionError(f"Smoke export failed: {smoke}")
        shipping["status"] = "passed"
    report["shipping_gate"] = shipping


def coverage_gate(report: dict) -> None:
    called = set(CALLED_TOOLS)
    missing = sorted(TWO_D_DOMAIN - called)
    report["tool_coverage"] = {"distinct_tools": len(called), "total_calls": len(CALLED_TOOLS),
        "2d_domain_total": len(TWO_D_DOMAIN), "2d_domain_called": len(TWO_D_DOMAIN) - len(missing),
        "2d_domain_coverage": (len(TWO_D_DOMAIN) - len(missing)) / len(TWO_D_DOMAIN), "2d_domain_missing": missing,
        "called_tools": sorted(called)}
    if missing:
        raise AssertionError(f"2D domain not fully exercised: {missing}")
    if len(called) < 60:
        raise AssertionError(f"Expected >=60 distinct tools, got {len(called)}")


def main() -> int:
    report: dict = {"gate": "P4 2D Gate Lab", "status": "running", "require_export": REQUIRE_EXPORT}
    godot = resolve_godot()
    with tempfile.TemporaryDirectory(prefix="godot_mcp_p4_2d_gate_") as temp:
        project_dir = Path(temp)
        prepare_project(project_dir)
        args = [godot, "--editor", "--path", str(project_dir), "--", "--mcp-server"]
        if os.environ.get("P4_2D_GATE_HEADLESS", "0") == "1":
            args.insert(1, "--headless")
        process = subprocess.Popen(args, cwd=project_dir, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            wait_for_server()
            build_game(report)
            runtime_gate(report)
            fault_gate(project_dir, report)
            shipping_probe(report)
            coverage_gate(report)
            report["status"] = "passed"
            print("P4_2D_GATE_REPORT=" + json.dumps(report, ensure_ascii=False, sort_keys=True, default=str))
            return 0
        except Exception as exc:
            report["status"] = "failed"
            report["error"] = str(exc)
            report["called_tools"] = sorted(set(CALLED_TOOLS))
            print("P4_2D_GATE_REPORT=" + json.dumps(report, ensure_ascii=False, sort_keys=True, default=str))
            raise
        finally:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=10)


if __name__ == "__main__":
    sys.exit(main())
