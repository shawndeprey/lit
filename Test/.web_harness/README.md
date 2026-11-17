# Web harness

Local tooling (this folder is git-ignored). Setup once, in this folder:

```
python -m pip install --target pylib playwright
set PYTHONPATH=pylib && python -m playwright install firefox
```

`webrun.py` expects `pylib` one level above itself; either move it next to a `pylib` folder or
adjust the `sys.path` line at its top. `run_godot.py` holds the Godot executable path.

Typical loop:

```
python webbuild.py res://Test/test_suite/TestSuite.tscn
python serve.py build 8765
python webrun.py --out runs/suite --timeout 1500 --fresh --godot-args "[\"--\",\"quit=on\"]" --until "SUITE RESULT"
python webrun.py --browser firefox --out runs/ff --timeout 1500 --fresh --godot-args "[\"--\",\"quit=on\"]" --until "SUITE RESULT"
python webbuild.py res://Test/StressTest.tscn
python webrun.py --out runs/stress --timeout 600 --godot-args "[\"--\",\"shadow_algo=cone\",\"warmup=3\",\"measure=6\"]" --until LITBENCH
```

`runs/<name>/summary.txt` lists the slowest links, the SUITE or LITBENCH lines and the first
errors; `src_<n>_frag.glsl` are the Lit programs the page compiled. Exit codes: 0 matched,
2 timeout, 3 context lost, 4 crash, 5 failure notice, 6 idle, 7 hard kill.

Offline compile timing of one dumped shader (no browser window after the translate step):

```
python benchrun.py runs/suite/src_22_vert.glsl runs/suite/src_22_frag.glsl --translate
python fxc.py runs/bench_b_<stamp>/f0_src_22_frag.frag.hlsl
python inltree.py runs/suite/src_22_frag.glsl
```
