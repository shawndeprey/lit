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
git tag -a v1.1.6 -m "Release v1.1.6"
git push origin --tags
git archive --format=zip --output=release.zip HEAD
```



# Release Cut
All releases must update the version in `addons/lit/plugin.cfg`

## Feature pass
Before signing off any change (and before a release cut), run the full test suite
windowed and read its report: every Lit feature is exercised on screen and any FAIL line
names the feature, the expectation, and the value observed (see `Test/test_suite/README.md`).
```
godot --path . res://Test/test_suite/TestSuite.tscn -- quit=on
```

## Schema lock & migrations
The stored (exported) properties of every Lit node class are locked in
`addons/lit/editor/lit_update_tool/migrations/baseline_schema.gd`, and
`Test/gate_migration_schema.gd` fails whenever a class's live schema differs from the
locked baseline advanced through the registered migration files. If a PR renames,
removes, retypes, re-defaults, or adds a stored property on any Lit node - or adds a
new Lit node class - the gate stays red until the PR ships the matching migration
file (or, for a brand-new class, a schema entry) describing the change from the
previous release version; never edit `BASELINE_SCHEMA` in place after a release. One
breaking change = one file: `migrations/X_Y_Z_migration.gd` extending `migration.gd`
(which documents the pattern), registered in `migration_registry.gd`. Migrations are
chained per node oldest-to-newest by "Update Project to Lit" (the one-time
"Port Project to Lit" never touches existing Lit nodes);
value-transforming `apply` overrides receive the node plus its as-saved property
dictionary and must be idempotent (guard on the old stored name, or on the node's
stamped `lit_version`). A semantic-only change (same name, type, and default, new
meaning) is invisible to the gate - rename the property as part of such a change so
old data stays detectable. Run locally:
```
godot --headless --path . --script res://Test/gate_migration_schema.gd
godot --headless --path . --script res://Test/gate_update_tool.gd
godot --headless -e --path . --script res://Test/gate_update_tool.gd
godot --headless --path . --script res://Test/gate_port_tool.gd
godot --headless -e --path . --script res://Test/gate_port_tool.gd
```

A release must be tagged prior to uploading to the Asset Library.
```
git tag -a v1.1.6 -m "Release v1.1.6"
git push origin --tags
```

For uploading to the asset store, we need an archive of the repo.
```
git archive --format=zip --output=release.zip HEAD
```