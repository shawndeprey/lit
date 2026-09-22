@tool
extends LitSprite2D

## Suite fixture: a LitSprite2D subclass that overrides _ready without calling super(),
## which the pre-wiring must survive. @tool only because the base class is a tool script;
## it is never placed in a scene.

func _ready() -> void:
	pass
