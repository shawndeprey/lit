# Release Cut

1. Bump `version` in `addons/lit/plugin.cfg`.

2. Run the suite windowed; it must end with `SUITE RESULT PASS`.
```
godot --path . res://Test/test_suite/TestSuite.tscn -- quit=on
```

3. Run the headless gates; each must print `GATE RESULT: PASS`.
```
godot --headless --path "D:\Game Dev\lit" --script res://Test/gate_update_tool.gd
godot --headless --path "D:\Game Dev\lit" --script res://Test/gate_port_tool.gd
godot --headless --path "D:\Game Dev\lit" --script res://Test/gate_migration_schema.gd
```
A red schema gate means a Lit node's stored properties changed without a migration
file; see `addons/lit/editor/lit_update_tool/migrations/migration.gd` for the pattern.

4. Run a cold precompile diagnostic; must run in a reasonable time.
```
LIT="$(cygpath "$APPDATA")/Godot/app_userdata/Lit"; AMD="$(cygpath "$LOCALAPPDATA")/AMD"; rm -rf "$LIT/shader_cache" "$LIT/vulkan" "$LIT/lit_worker" "$LIT/lit_shaders.cfg"; rm -f "$AMD/DxcCache/"* "$AMD/VkCache/"* "$AMD/DxCache/"*
godot --path "D:\Game Dev\lit" res://Test/integration_tests/precompile_diag/precompile_diag.tscn
```
Note, the above is tuned for a red box; The first command will need tweaking for a green box.

5. Tag, then archive for the Asset Library.
```
git tag -a v1.1.8 -m "Release v1.1.8"
git push origin --tags
git archive --format=zip --output=release.zip HEAD
```
