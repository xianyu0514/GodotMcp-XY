# Node Tools

[← Tools reference](README.md)

**26 tools** — 9 core, 17 advanced.

Create, inspect, reorganize and audit nodes in the edited scene. Core tools cover the common node-editing loop; advanced tools add signals, groups, subresources, bulk edits and persistence audits.

## Recommended workflow

1. Read the current scene with `get_scene_tree` or `list_nodes`.
2. Inspect specific nodes with `get_node_properties`.
3. Apply focused edits with `create_node`, `update_node_property`, `move_node` or `rename_node`.
4. Enable advanced node tools when you need signals, groups, Control anchors, subresources or batch operations.

## Tool list

### Node-Read (3 core)

| Tool | Tier | Description |
| --- | --- | --- |
| `get_node_properties` | core | Get all properties of a specific node in the scene tree. |
| `list_nodes` | core | List all nodes in the current scene or under a specific parent node. |
| `get_scene_tree` | core | Get the complete scene tree hierarchy starting from the scene root. Returns full tree structure with node types. |

### Node-Write (6 core)

| Tool | Tier | Description |
| --- | --- | --- |
| `create_node` | core | Create a node and return structured read-back evidence for its live path, name, type, owner and parent attachment. |
| `delete_node` | core | Delete a node from the Godot scene tree. This operation is destructive and cannot be undone. |
| `update_node_property` | core | Update a node property with automatic type conversion, skip unchanged values, and return typed expected/actual read-back evidence. |
| `duplicate_node` | core | Duplicate a node and its children in the scene tree. Returns the new node path. |
| `move_node` | core | Move a node to a new parent in the scene tree. Optionally preserves global transform. |
| `rename_node` | core | Rename a node in the scene tree. The new name must be unique among siblings. |

### Node-Advanced (9 advanced)

| Tool | Tier | Description |
| --- | --- | --- |
| `get_node_groups` | advanced | Get groups that a node belongs to. |
| `find_nodes_in_group` | advanced | Find all nodes in a specific group. |
| `get_node_subresource` | advanced | Read the inline sub-resource currently assigned to a node's Object property in the edited scene (e.g. inspect CollisionShape2D.shape size, or a material's fields). Returns the resource class and its storage properties in a JSON-friendly form. 'has_resource' is false when the property is null. |
| `batch_update_node_properties` | advanced | Update multiple node properties inside one editor UndoRedo action. `dry_run=true` validates targets and returns old/new values plus whether the live scene already matches, without mutation. |
| `batch_scene_node_edits` | advanced | Preview or apply create/delete/rename/move scene edits inside one UndoRedo action; its preview also powers cross-domain change sets. |
| `batch_get_node_properties` | advanced | Read the properties of multiple nodes in a single call. Returns one result entry per requested node path, reducing round trips when inspecting several nodes. |
| `batch_connect_signals` | advanced | Connect multiple node signals in a single call. Returns one result entry per requested connection, reducing round trips when wiring several signals. |
| `audit_scene_node_persistence` | advanced | Audit node owner and persistence state for the currently edited scene. Reports missing or invalid owner relationships that affect scene saving and inheritance. |
| `audit_scene_inheritance` | advanced | Audit inherited or instanced scene structure for the current scene. Classifies local nodes, instance roots, inherited instance content, and local additions inside instanced subtrees. |

### Node-Write-Advanced (8 advanced)

| Tool | Tier | Description |
| --- | --- | --- |
| `add_resource` | advanced | Add a resource child node to a target node. |
| `set_anchor_preset` | advanced | Set anchor preset for a Control node. |
| `connect_signal` | advanced | Connect a signal from one node to another. |
| `disconnect_signal` | advanced | Disconnect a signal from one node to another. |
| `set_node_groups` | advanced | Set groups for a node. |
| `set_control_offset_transform` | advanced | Set the Godot 4.7 offset transform of a Control node (offset_transform_position/rotation/scale/pivot plus enabled and visual_only) without affecting layout. Returns status unsupported below Godot 4.7. |
| `set_collision_one_way` | advanced | Enable or disable one-way collision on a 2D collision node (CollisionShape2D or CollisionPolygon2D) with optional margin and direction. CollisionShape2D one-way collision requires Godot 4.7. |
| `set_node_subresource` | advanced | Create an inline sub-resource of a built-in Resource type, set its properties, and assign it to a node property in the edited scene (wrapped in editor UndoRedo). Use this to set up things like CollisionShape2D.shape = RectangleShape2D{size:[64,32]}, Sprite2D.material = CanvasItemMaterial, or Line2D.gradient = Gradient. Unlike add_resource (which creates child nodes) this writes the sub-resource's own properties. |
