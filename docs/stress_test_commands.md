# Standard Stress Test: Lights + Shadows
godot --path "D:\Game Dev\lit" res://Test/StressTest.tscn -- shadow_algo=cone warmup=3 measure=6
godot --rendering-method gl_compatibility --path "D:\Game Dev\lit" res://Test/StressTest.tscn -- shadow_algo=cone warmup=3 measure=6
godot --rendering-method gl_compatibility --rendering-driver opengl3_angle --path "D:\Game Dev\lit" res://Test/StressTest.tscn -- shadow_algo=cone warmup=3 measure=6
godot --path "D:\Game Dev\lit" res://Test/StressTest.tscn -- shadow_algo=cone ysort=on warmup=3 measure=6
godot --path "D:\Game Dev\lit" res://Test/StressTest.tscn -- shadow_algo=cone masks=tilemap warmup=3 measure=6
godot --path "D:\Game Dev\lit" res://Test/StressTest.tscn -- shadow_algo=cone warmup=3 measure=6 post=AutoExposure
godot --path "D:\Game Dev\lit" res://Test/StressTest.tscn -- shadow_algo=cone warmup=3 measure=6 shadowlen=on
godot --path "D:\Game Dev\lit" res://Test/StressTest.tscn -- shadow_algo=cone warmup=3 measure=6 texoffset=on
godot --path "D:\Game Dev\lit" res://Test/StressTest.tscn -- shadow_algo=cone warmup=3 measure=6 layers=on
godot --path "D:\Game Dev\lit" res://Test/StressTest.tscn -- shadow_algo=cone warmup=3 measure=6 layers=z_pairs
godot --path "D:\Game Dev\lit" res://Test/StressTest.tscn -- shadow_algo=cone warmup=3 measure=6 layers=z_grid
godot --path "D:\Game Dev\lit" res://Test/StressTest.tscn -- shadow_algo=cone warmup=3 measure=6 layers=layer_pairs
godot --path "D:\Game Dev\lit" res://Test/StressTest.tscn -- shadow_algo=cone warmup=3 measure=6 layers=layer_grid
godot --path "D:\Game Dev\lit" res://Test/StressTest.tscn -- shadow_algo=cone warmup=3 measure=6 skeleton=animated
godot --path "D:\Game Dev\lit" res://Test/StressTest.tscn -- shadow_algo=cone warmup=3 measure=6 receivers=animated receiver_count=100
godot --path "D:\Game Dev\lit" res://Test/StressTest.tscn -- shadow_algo=cone warmup=3 measure=6 kinds=point
godot --path "D:\Game Dev\lit" res://Test/StressTest.tscn -- shadow_algo=cone warmup=3 measure=6 lines=on
godot --path "D:\Game Dev\lit" res://Test/StressTest.tscn -- shadow_algo=cone warmup=3 measure=6 lines=on linecurve=straight
godot --path "D:\Game Dev\lit" res://Test/StressTest.tscn -- shadow_algo=cone warmup=3 measure=6 lines=on linelen=0

# Functional Demo
godot --path "D:\Game Dev\lit" res://Test/Test.tscn
godot --rendering-method gl_compatibility --path "D:\Game Dev\lit" res://Test/Test.tscn
godot --rendering-method gl_compatibility --rendering-driver opengl3_angle --path "D:\Game Dev\lit" res://Test/Test.tscn
godot --path "D:\Game Dev\lit" res://Test/Test.tscn -- demo=point capture="D:/Game Dev/lit/demo_point.png"
godot --rendering-method gl_compatibility --rendering-driver opengl3_angle --path "D:\Game Dev\lit" res://Test/Test.tscn -- demo=dir capture="D:/Game Dev/lit/demo_dir.png"

# Integration Test Harness (every eyeball scene behind one tile menu; thumbs=on regenerates the tile thumbnails and quits)
godot --path "D:\Game Dev\lit" res://Test/integration_test_harness/integration_test_harness.tscn
godot --rendering-method gl_compatibility --path "D:\Game Dev\lit" res://Test/integration_test_harness/integration_test_harness.tscn
godot --rendering-method gl_compatibility --rendering-driver opengl3_angle --path "D:\Game Dev\lit" res://Test/integration_test_harness/integration_test_harness.tscn
godot --path "D:\Game Dev\lit" res://Test/integration_test_harness/integration_test_harness.tscn -- thumbs=on

# Line Light Benches
godot --path "D:\Game Dev\lit" res://Test/integration_tests/line_light_test/line_light_test.tscn
godot --path "D:\Game Dev\lit" res://Test/integration_tests/line_light_test/line_light_arc_test.tscn
godot --rendering-method gl_compatibility --path "D:\Game Dev\lit" res://Test/integration_tests/line_light_test/line_light_test.tscn
godot --rendering-method gl_compatibility --rendering-driver opengl3_angle --path "D:\Game Dev\lit" res://Test/integration_tests/line_light_test/line_light_test.tscn
godot --rendering-method gl_compatibility --path "D:\Game Dev\lit" res://Test/integration_tests/line_light_test/line_light_arc_test.tscn
godot --rendering-method gl_compatibility --rendering-driver opengl3_angle --path "D:\Game Dev\lit" res://Test/integration_tests/line_light_test/line_light_arc_test.tscn

# Real World Stress Test: Objects at scale in a level
godot --path "D:\Game Dev\lit" res://Test/misc/tilemaplayer_perf_bench/tilemaplayer_perf_bench.tscn -- warmup=3 measure=6
godot --path "D:\Game Dev\lit" res://Test/misc/tilemaplayer_perf_bench/tilemaplayer_perf_bench.tscn -- size=640 warmup=3 measure=6
godot --path "D:\Game Dev\lit" res://Test/misc/tilemaplayer_perf_bench/tilemaplayer_perf_bench.tscn -- warmup=3 measure=6 lines=on
godot --rendering-method gl_compatibility --path "D:\Game Dev\lit" res://Test/misc/tilemaplayer_perf_bench/tilemaplayer_perf_bench.tscn -- warmup=3 measure=6
godot --rendering-method gl_compatibility --rendering-driver opengl3_angle --path "D:\Game Dev\lit" res://Test/misc/tilemaplayer_perf_bench/tilemaplayer_perf_bench.tscn -- warmup=3 measure=6
godot --rendering-method gl_compatibility --path "D:\Game Dev\lit" res://Test/misc/tilemaplayer_perf_bench/tilemaplayer_perf_bench.tscn -- size=640 warmup=3 measure=6
godot --rendering-method gl_compatibility --rendering-driver opengl3_angle --path "D:\Game Dev\lit" res://Test/misc/tilemaplayer_perf_bench/tilemaplayer_perf_bench.tscn -- size=640 warmup=3 measure=6
godot --rendering-method gl_compatibility --path "D:\Game Dev\lit" res://Test/misc/tilemaplayer_perf_bench/tilemaplayer_perf_bench.tscn -- warmup=3 measure=6 lines=on
godot --rendering-method gl_compatibility --rendering-driver opengl3_angle --path "D:\Game Dev\lit" res://Test/misc/tilemaplayer_perf_bench/tilemaplayer_perf_bench.tscn -- warmup=3 measure=6 lines=on

# Functional Test Suite
godot --path "D:\Game Dev\lit" res://Test/test_suite/TestSuite.tscn
godot --rendering-method gl_compatibility --path "D:\Game Dev\lit" res://Test/test_suite/TestSuite.tscn
godot --rendering-method gl_compatibility --rendering-driver opengl3_angle --path "D:\Game Dev\lit" res://Test/test_suite/TestSuite.tscn
godot --path "D:\Game Dev\lit" res://Test/test_suite/TestSuite.tscn -- only=line_light
godot --headless --path "D:\Game Dev\lit" --import

# Shader Precompilation Diagnostic
LIT="$(cygpath "$APPDATA")/Godot/app_userdata/Lit"; AMD="$(cygpath "$LOCALAPPDATA")/AMD"; rm -rf "$LIT/shader_cache" "$LIT/vulkan" "$LIT/lit_worker" "$LIT/lit_shaders.cfg"; rm -f "$AMD/DxcCache/"* "$AMD/VkCache/"* "$AMD/DxCache/"*
godot --path "D:\Game Dev\lit" res://Test/integration_tests/precompile_diag/precompile_diag.tscn
godot --path "D:\Game Dev\lit" res://Test/integration_tests/precompile_diag/precompile_diag.tscn -- cold=on capture="D:/Game Dev/lit/precompile_diag.png"

# Update Tool Bench
godot --headless --path "D:\Game Dev\lit" --script res://Test/gate_update_tool.gd
godot --headless --path "D:\Game Dev\lit" --script res://Test/gate_port_tool.gd
godot --headless --path "D:\Game Dev\lit" --script res://Test/gate_migration_schema.gd

# Web Harness
python "d:/Game Dev/lit/Test/.web_harness/serve.py" "d:/Game Dev/builds/Lit/web" 8765
