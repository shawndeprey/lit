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
## Passes always run in a fixed canonical order, regardless of child order:
##   threshold, bloom, halation, glitch, grade, lut, pixelate, posterize, outline,
##   halftone, dither, letterbox, lens, vhs, crt, aberration, leaks, grain, vignette,
##   focus.
## Lower layers render first, so each pass reads the result of the ones before it. The
## order follows a signal-to-display pipeline: correct and glow the image, grade its
## color, stylize it, then matte it and run it through the display medium (tape, then
## tube, then film grain). Letterbox sits at the content/display boundary, so the
## display passes render over the bars.
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


## The chain's LitPostEffect children in canonical order: sorted by each effect's
## _rank(), ties keeping child order.
func effects() -> Array:
	var keyed := []
	var index := 0
	for child in get_children():
		var fx := child as LitPostEffect
		if fx != null:
			keyed.append([fx._rank(), index, fx])
			index += 1
	keyed.sort()
	var out := []
	for k in keyed:
		out.append(k[2])
	return out


## Assign each pass's CanvasLayer `layer` from the canonical order. Lower-layer passes
## render first, so each reads the result of the ones before it.
func _relayer() -> void:
	var index := 0
	for fx in effects():
		fx.layer = layer + index + 1    # above this node's base layer, in order
		index += 1
	_built_layer = layer


func _on_visibility_changed() -> void:
	for child in get_children():
		var fx := child as LitPostEffect
		if fx != null:
			fx._sync_host_visibility()
