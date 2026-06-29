@tool
@icon("res://addons/lit/icons/lit_point_light_2d.svg")
extends Node2D
class_name LitTintModifier

## Opts a translucent object into the stained-glass tint effect.
##
## Drop this as a CHILD of (or pointing at) any sprite that should colour light passing
## through it — a stained-glass pane, a gem, a coloured bottle. It draws nothing in the
## main scene. Instead it registers with the scene's LitTintBuffer, which mirrors the
## source sprite into the screen-space tint buffer using lit_tint_writer.gdshader. The
## receiver shader and the beam post-pass then read that buffer to tint surfaces, shadows,
## and visible light shafts.
##
## Reuses the receiver's transmission vocabulary so a gem already set up for transmission
## needs almost nothing new: `tint_color` is the same hue as transmission_color, and
## `transmission_map`'s R channel drives density exactly as it drives transmission there.
##
## Requires exactly one LitTintBuffer in the scene. If none exists the modifier waits and
## registers as soon as one appears (it retries on tree entry and when the buffer comes up).

## The sprite whose shape/art is stamped into the tint buffer. Defaults to the parent if
## that parent is a CanvasItem, so the common "modifier as a child of the glass" setup
## needs no wiring.
@export var source: CanvasItem:
	set(value):
		source = value
		_reregister()

## Optional explicit art override. When null, the source's own texture is used (if it's a
## Sprite2D). Set this when the source draws procedurally or you want a custom tint mask.
@export var source_texture: Texture2D

@export var enabled: bool = true:
	set(value):
		enabled = value
		_reregister()

@export_group("Tint")
## When true, pull `tint_color` and `transmission_map` from the source if it's a LitSprite2D
## (or any node exposing `transmission_color` / `transmission_map`), and fold in the source's
## `modulate` so the tint matches the gem's actual on-screen hue. Lets a gem already set up
## for transmission opt in with zero re-authoring. When false, the explicit fields below win.
@export var auto_from_source: bool = true

## The colour light takes on passing through this object. Same meaning as the receiver's
## transmission_color — match them so the lit body and the light it casts agree. Ignored
## when auto_from_source is on and the source supplies a transmission_color.
@export var tint_color: Color = Color(1.0, 0.2, 0.2)

## Packed transmission map (R = transmission/thickness drives density, G = opacity,
## B = reserved). Shared with the receiver; leave null for uniform full-thickness tint.
## Ignored when auto_from_source is on and the source supplies a transmission_map.
@export var transmission_map: Texture2D

## Master density: 0 = no tint (disabled), 1 = full stained-glass. Animatable. Always
## applies, on top of whatever colour/map the auto mode resolves.
@export_range(0.0, 1.0) var density: float = 1.0


## Resolved tint colour the buffer should stamp: the source's transmission_color × modulate
## when auto, else the explicit tint_color. Folding in modulate matters because the gems
## carry their hue partly in modulate (e.g. a magenta gem is white art × magenta modulate),
## so light through them should take that combined colour.
func resolved_tint_color() -> Color:
	if auto_from_source and is_instance_valid(source):
		var base := tint_color
		if "transmission_color" in source:
			base = source.transmission_color
		if source is CanvasItem:
			base = base * (source as CanvasItem).modulate
		return base
	return tint_color


## Resolved transmission map: the source's when auto and it has one, else the explicit field.
func resolved_transmission_map() -> Texture2D:
	if auto_from_source and is_instance_valid(source) and "transmission_map" in source:
		var m = source.transmission_map
		if m != null:
			return m
	return transmission_map


func _enter_tree() -> void:
	if source == null and get_parent() is CanvasItem:
		source = get_parent()
	# The buffer polls this group every frame, so membership — not call order — is what
	# guarantees the writer is picked up. add_to_group is safe to call repeatedly.
	add_to_group("lit_tint_modifiers")
	_reregister()


func _exit_tree() -> void:
	remove_from_group("lit_tint_modifiers")
	LitTintBuffer.deregister(self)


func _ready() -> void:
	# The buffer may enter the tree after this node. Retry registration once the scene is
	# settled so order-of-addition doesn't matter.
	if not LitTintBuffer.has_active():
		call_deferred("_reregister")


func _reregister() -> void:
	if not is_inside_tree():
		return
	LitTintBuffer.deregister(self)
	if enabled and source != null:
		LitTintBuffer.register(self)
