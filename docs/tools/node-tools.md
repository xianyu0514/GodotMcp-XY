# Node Tools

[← Tools reference](README.md)

**26 tools** — 9 core, 17 advanced.

Tools for building and editing the scene tree at edit time: creating, deleting, moving, renaming and duplicating nodes, wiring signals, managing groups and anchors, batch edits wrapped in a single editor UndoRedo step, and structural audits.

> Core tools are enabled out of the box. Advanced tools are registered but disabled by
> default; enable the ones you need from the **MCP** dock panel (or in tests via
> `core.set_tool_enabled("<tool>", true)`). See [the tools overview](README.md) for details.

### Node-Write (6)

| Tool | Tier | Description |
| --- | --- | --- |
| `create_node` | Core | Create a new node in the Godot scene tree. Returns the node path and type. |
| `delete_node` | Core | Delete a node from the Godot scene tree. This operation is destructive and cannot be undone. |
| `update_node_property` | Core | Update a property of a specific node. Supports common property types with automatic type conversion. |
| `duplicate_node` | Core | Duplicate a node and its children in the scene tree. Returns the new node path. |
| `move_node` | Core | Move a node to a new parent in the scene tree. Optionally preserves global transform. |
| `rename_node` | Core | Rename a node in the scene tree. The new name must be unique among siblings. |

### Node-Read (3)

| Tool | Tier | Description |
| --- | --- | --- |
| `get_node_properties` | Core | Get all properties of a specific node in the scene tree. |
| `list_nodes` | Core | List all nodes in the current scene or under a specific parent node. |
| `get_scene_tree` | Core | Get the complete scene tree hierarchy starting from the scene root. Returns full tree structure with node types. |

### Node-Write-Advanced (8)

| Tool | Tier | Description |
| --- | --- | --- |
| `add_resource` | Advanced | Add a resource child node to a target node. |
| `set_anchor_preset` | Advanced | Set anchor preset for a Control node. |
| `connect_signal` | Advanced | Connect a signal from one node to another. |
| `disconnect_signal` | Advanced | Disconnect a signal from one node to another. |
| `set_node_groups` | Advanced | Set groups for a node. |
| `set_control_offset_transform` | Advanced | Set the Godot 4.7 offset transform of a Control node (offset_transform_position/rotation/scale/pivot plus enabled and visual_only) without affecting layout. Returns status unsupported below Godot 4.7. |
| `set_collision_one_way` | Advanced | Enable or disable one-way collision on a 2D collision node (CollisionShape2D or CollisionPolygon2D) with optional margin and direction. CollisionShape2D one-way collision requires Godot 4.7. |
| `set_node_subresource` | Advanced | Create an inline sub-resource of a built-in Resource type, set its properties, and assign it to a node property in the edited scene (wrapped in editor UndoRedo). Use this to set up things like CollisionShape2D.shape = RectangleShape2D{size:[64,32]}, Sprite2D.material = CanvasItemMaterial, or Line2D.gradient = Gradient. Unlike add_resource (which creates child nodes) this writes the sub-resource's own properties. |

### Node-Advanced (9)

| Tool | Tier | Description |
| --- | --- | --- |
| `get_node_groups` | Advanced | Get groups that a node belongs to. |
| `find_nodes_in_group` | Advanced | Find all nodes in a specific group. |
| `get_node_subresource` | Advanced | Read the inline sub-resource currently assigned to a node's Object property in the edited scene (e.g. inspect CollisionShape2D.shape size, or a material's fields). Returns the resource class and its storage properties in a JSON-friendly form. 'has_resource' is false when the property is null. |
| `batch_update_node_properties` | Advanced | Update multiple node properties inside one editor UndoRedo action. Useful for transaction-style scene edits that should undo in a single step. |
| `batch_scene_node_edits` | Advanced | Apply multiple create/delete scene node edits inside one editor UndoRedo action so the full structure change undoes in a single step. |
| `batch_get_node_properties` | Advanced | Read the properties of multiple nodes in a single call. Returns one result entry per requested node path, reducing round trips when inspecting several nodes. |
| `batch_connect_signals` | Advanced | Connect multiple node signals in a single call. Returns one result entry per requested connection, reducing round trips when wiring several signals. |
| `audit_scene_node_persistence` | Advanced | Audit node owner and persistence state for the currently edited scene. Reports missing or invalid owner relationships that affect scene saving and inheritance. |
| `audit_scene_inheritance` | Advanced | Audit inherited or instanced scene structure for the current scene. Classifies local nodes, instance roots, inherited instance content, and local additions inside instanced subtrees. |
