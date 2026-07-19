extends Node2D

## Y-sort functional test bed: instances the real Test scene and moves the Skeleton
## skull around/over the crypt's occluders to compare shadow layering with the
## lit/render/y_sort setting off and on.
##
## Automated use (screenshots), after "--" on the CLI:
##   pos=X,Y     world position for the Skeleton node
##   ysort=0|1   force the lit/render/y_sort project setting for this run
##   out=PATH    capture one frame to PATH, then quit
##   probe=1     print the world rects of occluder-bearing tiles near the room
##               center (for choosing test positions), then quit
##   keeppost=1  keep the LitPostProcess effects (hidden by default for clean diffs)
##   algo=0|1|2  force every visible light's shadow algorithm
##               (0 raymarched, 1 cone traced, 2 stochastic)

var _out := ""
var _probe := false


func _ready() -> void:
	var test: Node2D = load("res://Test/Test.tscn").instantiate()
	add_child(test)

	var keep_post := false
	var pos := Vector2.ZERO
	var has_pos := false
	var ysort := false
	for arg in OS.get_cmdline_user_args():
		var kv := arg.split("=")
		if kv.size() != 2:
			continue
		match kv[0]:
			"pos":
				var xy := kv[1].split(",")
				if xy.size() == 2:
					pos = Vector2(float(xy[0]), float(xy[1]))
					has_pos = true
			"ysort":
				ysort = kv[1] == "1"
			"fade":
				ProjectSettings.set_setting("lit/render/y_sort_fade", float(kv[1]))
			"out":
				_out = kv[1]
			"probe":
				_probe = kv[1] == "1"
			"keeppost":
				keep_post = kv[1] == "1"
			"algo":
				var algo := clampi(int(kv[1]), 0, 2)
				for light in test.find_children("*", "", true, false):
					if "shadow_algorithm" in light and light.is_visible_in_tree():
						light.shadow_algorithm = algo

	# The demo overlay and film-grain post effects just add noise to comparisons.
	var demo := test.get_node_or_null("LitDemo")
	if demo != null:
		demo.queue_free()
	if not keep_post:
		var post := test.get_node_or_null("LitPostProcess")
		if post != null:
			post.visible = false

	# The manager reloads lit/* settings on settings_changed, so a runtime override
	# works exactly like flipping the checkbox in Project Settings.
	ProjectSettings.set_setting("lit/render/y_sort", ysort)

	if has_pos:
		var skeleton := test.get_node_or_null("Skeleton") as Node2D
		if skeleton != null:
			skeleton.position = pos

	if _probe:
		_print_occluder_cells(test)
		get_tree().quit()
		return

	if _out != "":
		_capture.call_deferred()


## Dump the world rect of every occluder-bearing tile inside the camera's view, so
## test positions can be picked against real geometry.
func _print_occluder_cells(test: Node2D) -> void:
	var layer := test.get_node_or_null("TileBasicCrypt") as TileMapLayer
	if layer == null:
		print("YSORT_PROBE no TileBasicCrypt layer")
		return
	var ts := layer.tile_set
	var view := Rect2(-384, -216, 1920, 1080)
	for cell in layer.get_used_cells():
		var td := layer.get_cell_tile_data(cell)
		if td == null:
			continue
		for li in ts.get_occlusion_layers_count():
			for pi in td.get_occluder_polygons_count(li):
				var poly := td.get_occluder_polygon(li, pi)
				if poly == null or poly.polygon.is_empty():
					continue
				var origin := layer.map_to_local(cell)
				var r := Rect2(origin + poly.polygon[0], Vector2.ZERO)
				for p in poly.polygon:
					r = r.expand(origin + p)
				var xf := layer.global_transform
				var wr: Rect2 = xf * r
				if view.intersects(wr):
					print("YSORT_PROBE cell=%s rect=%.0f,%.0f..%.0f,%.0f" % [
						cell, wr.position.x, wr.position.y, wr.end.x, wr.end.y])


func _capture() -> void:
	# Enough frames for the settings reload, receiver-variant swap and occluder-table
	# publish to land before the capture.
	for i in 8:
		await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_out)
	print("YSORT_TEST ysort=%s pos=%s saved=%s" % [
		ProjectSettings.get_setting("lit/render/y_sort", false),
		(get_node("Test/Skeleton") as Node2D).position, _out])
	get_tree().quit()
