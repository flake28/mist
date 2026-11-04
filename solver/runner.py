"""Runs model-written code (stdin) and prints its claims as JSON. Always launched inside sandbox.sb."""
import json, os, sys
import sympy as sp
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fmt import text as fmt_text

CLAIMS = []
STEPS = []

def _ser(v):
    if isinstance(v, bool) or v is None or isinstance(v, str):
        return v
    if isinstance(v, (list, tuple)):
        return [_ser(x) for x in v]
    if isinstance(v, dict):
        return {"__dict__": [[_ser(k), _ser(x)] for k, x in v.items()]}
    return {"__sympy__": sp.srepr(sp.sympify(v))}

ALIASES = {"eq": "ode", "equation": "ode", "de": "ode", "y": "solution", "sol": "solution", "answer": "value",
           "eigenvalue": "eigenvalues", "eigenvector": "eigenvectors", "A_matrix": "A"}

def claim(kind, **fields):
    fields = {ALIASES.get(k, k) if ALIASES.get(k, k) not in fields else k: v for k, v in fields.items()}
    if kind == "step":  # small models sometimes report steps through claim()
        return step(fields.get("label", ""), fields.get("value", ""))
    CLAIMS.append({"kind": kind, **{k: _ser(v) for k, v in fields.items()}})

def step(label, value):
    """An intermediate result for the explanation (computed by SymPy, so arithmetic-correct; not separately checked)."""
    STEPS.append([str(label), fmt_text(value)])

code = sys.stdin.read()
ns = {"sp": sp, "claim": claim, "step": step}
exec("from sympy import *", ns)
# Names small models use without defining them.
exec("x, t, s, n, r, lam = symbols('x t s n r lam'); a, b, c, k = symbols('a b c k')\n"
     "C1, C2, C3, C4, k1, k2, k3 = symbols('C1 C2 C3 C4 k1 k2 k3')\n"
     "x1, x2, x3, x4, x5, y1, y2, y3 = symbols('x1 x2 x3 x4 x5 y1 y2 y3')\n"
     "u = Function('u')", ns)
import contextlib, io
with contextlib.redirect_stdout(io.StringIO()):  # stray prints are ignored; the working comes from step()
    exec(compile(code, "<model code>", "exec"), ns)
print("@@CLAIMS@@" + json.dumps({"claims": CLAIMS, "steps": STEPS}))
