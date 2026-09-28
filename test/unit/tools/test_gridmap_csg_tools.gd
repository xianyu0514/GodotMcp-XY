extends "res://addons/gut/test.gd"

## set_gridmap_cells / create_csg_shape（3D 广度补齐）：无编辑器环境下的
## 参数校验与自愈错误；编辑器路径由真机冒烟（bench 场景）覆盖。

const ToolsScript = preload("res://addons/godot_mcp/tools/scene_tools_native.gd")

var _tools: RefCounted

func before_each() -> void:
	_tools = ToolsScript.new()

func after_each() -> void:
	_tools = null

func test_gridmap_requires_node_and_op() -> void:
	var r1: Dictionary = await _tools._tool_set_gridmap_cells({})
	assert_true(r1.has("error") and String(r1["error"]).contains("node_path"))
	var r2: Dictionary = await _tools._tool_set_gridmap_cells({"node_path": "Grid"})
	assert_true(r2.has("error") and String(r2["error"]).contains("op"))
	var r3: Dictionary = await _tools._tool_set_gridmap_cells({"node_path": "Grid", "op": "paint"})
	assert_true(r3.has("error") and String(r3["error"]).contains("set | fill | clear | read | set_mesh_library"),
		"unknown op lists the valid ones")

func test_gridmap_validates_op_params_before_editor() -> void:
	var r1: Dictionary = await _tools._tool_set_gridmap_cells({"node_path": "Grid", "op": "set", "cells": []})
	assert_true(r1.has("error") and String(r1["error"]).contains("non-empty cells"))
	var r2: Dictionary = await _tools._tool_set_gridmap_cells({"node_path": "Grid", "op": "fill", "from": [0, 0, 0]})
	assert_true(r2.has("error") and String(r2["error"]).contains("from"), "fill names every required param")
	var r3: Dictionary = await _tools._tool_set_gridmap_cells({
		"node_path": "Grid", "op": "fill", "from": [0, 0, 0], "to": [100, 100, 100], "item": 1})
	assert_true(r3.has("error") and String(r3["error"]).contains("20000"),
		"oversized fill region is rejected with the limit in the message")

func test_csg_shape_validated_before_editor() -> void:
	var r1: Dictionary = await _tools._tool_create_csg_shape({"shape": "pyramid"})
	assert_true(r1.has("error") and String(r1["error"]).contains("box | sphere"),
		"unknown shape lists the valid shapes")
	var r2: Dictionary = await _tools._tool_create_csg_shape({"shape": "polygon"})
	assert_true(r2.has("error") and String(r2["error"]).contains("polygon"))
	var r3: Dictionary = await _tools._tool_create_csg_shape({"shape": "mesh"})
	assert_true(r3.has("error") and String(r3["error"]).contains("mesh"))

func test_parse_vector3i_forms() -> void:
	assert_eq(ToolsScript._parse_vector3i([2, -3, 4]), Vector3i(2, -3, 4))
	assert_eq(ToolsScript._parse_vector3i({"x": 1, "y": 2, "z": 3}), Vector3i(1, 2, 3))
	assert_eq(ToolsScript._parse_vector3i(Vector3i(5, 6, 7)), Vector3i(5, 6, 7))
	assert_null(ToolsScript._parse_vector3i([1, 2]))
	assert_null(ToolsScript._parse_vector3i("nope"))
	assert_null(ToolsScript._parse_vector3i({"x": 1}))
