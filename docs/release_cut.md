# Release Cut

1. Bump `version` in `addons/lit/plugin.cfg`.

2. Run the suite windowed; it must end with `SUITE RESULT PASS`.
```
godot --path . res://Test/test_suite/TestSuite.tscn -- quit=on
```

3. Run the headless gates; each must print `GATE RESULT: PASS`.
```
Godot_v4.7.2-stable_win64_console.exe --headless --path "D:\Game Dev\lit" --script res://Test/gate_update_tool.gd
Godot_v4.7.2-stable_win64_console.exe --headless --path "D:\Game Dev\lit" --script res://Test/gate_port_tool.gd
Godot_v4.7.2-stable_win64_console.exe --headless --path "D:\Game Dev\lit" --script res://Test/gate_migration_schema.gd
Godot_v4.7.2-stable_win64_console.exe --path "D:\Game Dev\lit" res://Test/test_suite/TestSuite.tscn
```
A red schema gate means a Lit node's stored properties changed without a migration
file; see `addons/lit/editor/lit_update_tool/migrations/migration.gd` for the pattern.

4. Tag, then archive for the Asset Library.
```
git tag -a v1.1.7 -m "Release v1.1.7"
git push origin --tags
git archive --format=zip --output=release.zip HEAD
```
