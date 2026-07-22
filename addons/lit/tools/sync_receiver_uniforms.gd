@tool
extends EditorScript
# Godot builds inspector hover tooltips only from /** */ doc comments in a shader's
# own source, never from #include'd files, so the receiver uniform block must exist
# verbatim in every lit_receiver*.gdshader wrapper. This script keeps those copies in
# sync: edit the block in lit_receiver.gdshader (the source of truth), then run this
# with File > Run (Ctrl+Shift+X). It replaces the [receiver-uniforms] span in every
# other wrapper with the source's span.

const SHADER_DIR := "res://addons/lit/shaders"
const SOURCE := "lit_receiver.gdshader"
const BEGIN := "// [receiver-uniforms]"
const END := "// [/receiver-uniforms]"


func _run() -> void:
	var source_block := _extract_block(SHADER_DIR + "/" + SOURCE)
	if source_block.is_empty():
		push_error("sync_receiver_uniforms: no [receiver-uniforms] span in " + SOURCE)
		return
	var updated := 0
	for file in DirAccess.get_files_at(SHADER_DIR):
		if not (file.begins_with("lit_receiver") and file.ends_with(".gdshader")):
			continue
		if file == SOURCE:
			continue
		var path := SHADER_DIR + "/" + file
		var text := FileAccess.get_file_as_string(path)
		var begin_idx := text.find(BEGIN)
		var end_idx := text.find(END)
		if begin_idx < 0 or end_idx < 0 or end_idx < begin_idx:
			push_error("sync_receiver_uniforms: no [receiver-uniforms] span in " + file)
			continue
		var new_text := text.substr(0, begin_idx) + source_block + text.substr(end_idx + END.length())
		if new_text == text:
			continue
		var out := FileAccess.open(path, FileAccess.WRITE)
		out.store_string(new_text)
		out.close()
		updated += 1
	if updated > 0:
		EditorInterface.get_resource_filesystem().scan()
	print("sync_receiver_uniforms: %d wrapper(s) updated." % updated)


func _extract_block(path: String) -> String:
	var text := FileAccess.get_file_as_string(path)
	var begin_idx := text.find(BEGIN)
	var end_idx := text.find(END)
	if begin_idx < 0 or end_idx < 0 or end_idx < begin_idx:
		return ""
	return text.substr(begin_idx, end_idx + END.length() - begin_idx)
