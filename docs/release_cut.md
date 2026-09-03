# Release Cut
All releases must update the version in `addons/lit/plugin.cfg`

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
chained per node oldest-to-newest by the "Update Project to Lit" tool;
value-transforming `apply` overrides receive the node plus its as-saved property
dictionary and must be idempotent (guard on the old stored name, or on the node's
stamped `lit_version`). A semantic-only change (same name, type, and default, new
meaning) is invisible to the gate - rename the property as part of such a change so
old data stays detectable. Run locally:
```
godot --headless --path . --script res://Test/gate_migration_schema.gd
godot --headless --path . --script res://Test/gate_update_tool.gd
```

A release must be tagged prior to uploading to the Asset Library.
```
git tag -a v1.1.3 -m "Release v1.1.3"
git push origin --tags
```

For uploading to the asset store, we need an archive of the repo.
```
git archive --format=zip --output=release.zip HEAD
```
