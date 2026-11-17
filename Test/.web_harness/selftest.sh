#!/bin/bash
cd "$(dirname "$0")"
left() { powershell -NoProfile -Command "(Get-CimInstance Win32_Process -Filter \"Name='chrome.exe'\" | Where-Object { \$_.CommandLine -like '*scratchpad*' } | Measure-Object).Count"; }
run() { name=$1; shift; echo "=== $name"; python webrun.py --out ../runs/st_$name "$@" > ../runs/st_$name.out 2>&1; echo "rc=$? leftover_chrome=$(left)"; grep -E "STOP|HARD|blocked|unblocked" ../runs/st_$name/log.txt | head -5; }
run fatal --timeout 60 --godot-args '["res://nope.tscn"]'
run hang --timeout 15 --url http://127.0.0.1:8765/hang.html
run quiet --timeout 60 --idle 8 --url http://127.0.0.1:8765/quiet.html
run crash --timeout 30 --url http://127.0.0.1:8765/crash.html
