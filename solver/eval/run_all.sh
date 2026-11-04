#!/bin/zsh
cd "${0:A:h}"; LMS=~/.lmstudio/bin/lms
for m in qwen/qwen3.5-4b qwen/qwen3.5-9b; do
  $LMS unload --all >/dev/null 2>&1; $LMS load $m --identifier $m -y >/dev/null 2>&1
  ../.venv/bin/python -I run.py $m
done
$LMS unload --all >/dev/null 2>&1; $LMS load qwen/qwen3.5-4b --identifier qwen/qwen3.5-4b -y >/dev/null 2>&1
echo DONE
