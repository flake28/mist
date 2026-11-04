"""Runs every eval item through solve.py on one model; appends logs to eval/log.jsonl. Usage: run.py <model>"""
import json, os, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import solve
model = sys.argv[1]
items = json.load(open(os.path.join(os.path.dirname(__file__), "items.json")))
out = open(os.path.join(os.path.dirname(__file__), "log.jsonl"), "a")
for it in items:
    try:
        log = solve.solve(it["text"], model)
    except Exception as e:
        log = {"status": "error", "error": str(e), "attempts": [], "solve_s": None}
    log.update(id=it["id"], model=model)
    out.write(json.dumps(log) + "\n"); out.flush()
    last = log["attempts"][-1] if log["attempts"] else {}
    print(f"{model} {it['id']:4} {log['status']:12} {len(log['attempts'])} att  {log.get('solve_s')}s  "
          + "; ".join(f"{c['kind']}:{v['verdict']}" for c, v in zip(last.get('claims') or [], last.get('verdicts') or [])), flush=True)
