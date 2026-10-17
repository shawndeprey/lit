class_name FixtureOnelineTile extends TileMapLayer


func tile_count() -> int:
	return get_used_cells().size()
