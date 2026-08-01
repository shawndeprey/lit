// Receiver pipeline spine: units in dependency order; a unit only calls units above it.
// Variant axes (set by LitShaderLibrary): LIT_SELF_EXCLUSION, LIT_YSORT, LIT_SHADOW_CONE,
// LIT_SHADOW_STOCH, LIT_OCC_GX, LIT_OCC_MASKS, LIT_OCC_RX.

#include "res://addons/lit/shaders/receiver/include/lit_header.gdshaderinc"
#include "res://addons/lit/shaders/receiver/include/lit_exclusion.gdshaderinc"
#include "res://addons/lit/shaders/receiver/include/lit_ysort.gdshaderinc"
#include "res://addons/lit/shaders/receiver/include/lit_wsdf.gdshaderinc"
#include "res://addons/lit/shaders/receiver/include/lit_shadow_march.gdshaderinc"
#include "res://addons/lit/shaders/receiver/include/lit_shadow_cone.gdshaderinc"
#include "res://addons/lit/shaders/receiver/include/lit_shadow_stoch.gdshaderinc"
#include "res://addons/lit/shaders/receiver/include/lit_brdf.gdshaderinc"
#include "res://addons/lit/shaders/receiver/include/lit_shade.gdshaderinc"
#include "res://addons/lit/shaders/receiver/include/lit_fragment.gdshaderinc"
