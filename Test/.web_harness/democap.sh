#!/bin/bash
# democap.sh <name> <stage> [godot args...] : capture one held demo stage to runs/demo_<name>_<stage>.png
cd "$(dirname "$0")"
R=$(cd runs 2>/dev/null && pwd || (mkdir -p runs && cd runs && pwd))
name=$1; stage=$2; shift 2
python run_godot.py 90 "$R/demo_${name}_${stage}.log" "d:/Game Dev/lit" "$@" --path "d:/Game Dev/lit" res://Test/Test.tscn -- demo=$stage capture="$R/demo_${name}_${stage}.png" | tail -1
grep -E "DEMO capture|SCRIPT ERROR|SHADER ERROR|ERROR" "$R/demo_${name}_${stage}.log" | head -3
