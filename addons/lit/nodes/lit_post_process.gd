@tool
@icon("res://addons/lit/icons/lit_post_process.svg")
extends CanvasLayer
class_name LitPostProcess

## Post-processing chain host. LitPostEffect children run in child order, each pass
## reading the result of the ones above it. Hiding this node disables the chain.

var _built_layer: int = 0


func _ready() -> void:
	if not child_order_changed.is_connected(_relayer):
		child_order_changed.connect(_relayer)
	if not visibility_changed.is_connected(_on_visibility_changed):
		visibility_changed.connect(_on_visibility_changed)
	_relayer()
	_on_visibility_changed()
	set_process(Engine.is_editor_hint())


func _process(_delta: float) -> void:
	if layer != _built_layer:
		_relayer()


## Add an effect as a child at its canonical pipeline slot (_rank()); reorder freely.
func add_effect(fx: LitPostEffect) -> void:
	add_child(fx)
	for i in get_child_count():
		var other := get_child(i) as LitPostEffect
		if other != null and other != fx and other._rank() > fx._rank():
			move_child(fx, i)
			break


func _relayer() -> void:
	var index := 0
	for child in get_children():
		var fx := child as LitPostEffect
		if fx != null:
			fx._set_pass_index(index)
			index += 1
	_built_layer = layer


func _on_visibility_changed() -> void:
	for child in get_children():
		var fx := child as LitPostEffect
		if fx != null:
			fx._refresh()
