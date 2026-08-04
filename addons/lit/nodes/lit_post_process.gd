@tool
@icon("res://addons/lit/icons/lit_post_process.svg")
extends CanvasLayer
class_name LitPostProcess

## Post-processing chain host.
##
## Each pass is a LitPostEffect child node (LitPostBloom, LitPostCrt, ...), holding a
## fullscreen ColorRect with that pass's shader, reading the frame via
## hint_screen_texture. No BackBufferCopy is needed. hint_screen_texture reads the
## screen as drawn so far, and the per-pass CanvasLayer boundary makes each pass
## re-read the accumulated result, so passes compose in order.
##
## Draw order is the child order, exactly like Godot's own node draw order: the top
## child runs first, each later child reads the accumulated result of the ones above
## it, and the bottom child draws last (on top). Reordering children in the scene tree
## reorders the chain live, so effects stack in whatever order you want (e.g. move
## Edge Outline below Posterize or Pixelate to ink a flattened, chunky image).
##
## The recommended default is a signal-to-display pipeline: correct and glow the image
## (threshold, bloom, halation), corrupt the signal (glitch), grade its color (grade,
## lut), stylize it (pixelate, posterize, outline, halftone, dither), then matte it
## (letterbox) and run it through the display medium (lens, vhs, crt, aberration,
## leaks, grain, vignette, focus). Letterbox sits at the content/display boundary, so
## the display passes render over the bars. add_effect() and the inspector's "Add
## Effect" button insert new passes at that canonical position (each effect's _rank());
## the tree order stays yours to rearrange afterward.
##
## Placement: set this node's `layer` above your Lit receivers and below your UI. Pass
## child-layers increment from this node's `layer`, so wherever you park it the passes
## stay above it and in order.
##
## Add effects with the "Add Effect" button at the top of this node's inspector, or
## from the Create Node dialog (LitPost...). Hiding this node disables the whole chain;
## hiding an effect child disables that pass.

# The base `layer` the pass layers were last assigned against, so an inspector edit to
# the node's layer can re-sync the pass child-layers live (editor only).
var _built_layer: int = 0


func _ready() -> void:
	if not child_order_changed.is_connected(_relayer):
		child_order_changed.connect(_relayer)
	# Hiding this node should stop post-processing. The passes are their own child
	# CanvasLayers, which don't inherit a parent CanvasLayer's visibility, so mirror it.
	if not visibility_changed.is_connected(_on_visibility_changed):
		visibility_changed.connect(_on_visibility_changed)
	_relayer()
	_on_visibility_changed()
	set_process(Engine.is_editor_hint())


func _process(_delta: float) -> void:
	# Editor-only: keep pass layers ordered relative to the node if `layer` is edited.
	if layer != _built_layer:
		_relayer()


## Add an effect as a child at its canonical pipeline position (the first spot before
## any existing effect with a higher _rank(); after its equals). The insertion point is
## just a sensible default: child order IS the draw order, reorder freely afterward.
func add_effect(fx: LitPostEffect) -> void:
	add_child(fx)
	for i in get_child_count():
		var other := get_child(i) as LitPostEffect
		if other != null and other != fx and other._rank() > fx._rank():
			move_child(fx, i)
			break


## Assign each pass's CanvasLayer `layer` from the child order. Lower-layer passes
## render first, so each reads the result of the ones before it.
func _relayer() -> void:
	var index := 0
	for child in get_children():
		var fx := child as LitPostEffect
		if fx != null:
			fx.layer = layer + index + 1    # above this node's base layer, in order
			index += 1
	_built_layer = layer


func _on_visibility_changed() -> void:
	for child in get_children():
		var fx := child as LitPostEffect
		if fx != null:
			fx._sync_host_visibility()
