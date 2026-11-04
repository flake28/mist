"""Run model code and the verifier in separate sandboxed processes (no network, writes only to a temp dir)."""
import json, os, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__))
PY = os.path.join(HERE, ".venv/bin/python")
TMP = "/private/tmp/mist-solver"

def _run(script, stdin, timeout):
    os.makedirs(TMP, exist_ok=True)
    cmd = ["/usr/bin/sandbox-exec", "-f", os.path.join(HERE, "sandbox.sb"), PY, "-I", "-B", os.path.join(HERE, script)]
    try:
        p = subprocess.run(cmd, input=stdin, capture_output=True, text=True, timeout=timeout, cwd=TMP,
                           env={"PATH": "/usr/bin:/bin", "HOME": TMP, "TMPDIR": TMP})
    except subprocess.TimeoutExpired:
        return None, f"timed out after {timeout}s"
    return p.stdout, p.stderr

def run_code(code, timeout=30):
    """Returns (claims, error, steps)."""
    out, err = _run("runner.py", code, timeout)
    if out is None:
        return None, err, []
    marker = "@@CLAIMS@@"
    if marker not in out:
        tail = (err or "").strip().splitlines()[-6:]
        return None, "\n".join(tail) or "no claims printed", []
    data = json.loads(out.split(marker, 1)[1].strip())
    claims, steps = data["claims"], data["steps"]
    if not claims:
        return None, "code ran but made no claim(...) calls", []
    return claims, None, steps

def verify(claims, timeout=60):
    out, err = _run("verify.py", json.dumps(claims), timeout)
    if out is None:
        return [{"verdict": "unverifiable", "why": err}] * len(claims)
    try:
        return json.loads(out.strip().splitlines()[-1])
    except Exception:
        return [{"verdict": "unverifiable", "why": "verifier crashed: " + (err or "")[-300:]}] * len(claims)
