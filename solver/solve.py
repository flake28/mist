"""Verified maths solver: the model writes SymPy code, the sandbox runs it, an independent checker verifies
every claimed result. Answers only when all claims verify; otherwise says it couldn't solve it.

Usage: .venv/bin/python -I solve.py "question text"      (model: MIST_LOCAL_MODEL, default qwen/qwen3.5-4b)
"""
import json, os, re, sys, time, urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sandbox

LMSTUDIO = "http://localhost:1234/v1/chat/completions"

CODE_SYSTEM = """You solve maths questions by writing Python code with SymPy. Never do arithmetic or algebra in your \
head: the code computes everything. Reply with ONE ```python block and nothing else.

`from sympy import *` is already done. The code must compute the answer with SymPy (dsolve, laplace_transform, \
inverse_laplace_transform, integrate, solve, linsolve, Matrix.rref, Matrix.eigenvects, ...) and then report each \
result by calling claim(...) with one of these kinds, so an independent checker can verify it:

claim("ode", ode=Eq(...), solution=<expr for y>, ics=[[x0, derivative_order, value], ...])
    # y = Function('y')(x); ics=[] for a general solution, whose arbitrary constants must be named C1, C2, ...
claim("laplace", f=<expr in t>, F=<expr in s>)              # F = L{f}; unit step u(t-a) = Heaviside(t - a)
claim("inverse_laplace", F=<expr in s>, f=<expr in t>)
claim("integral", integrand=<expr>, var=x, lower=<a or None>, upper=<b or oo or None>, result=<expr>)
claim("series_sum", term=<expr in n>, start=1, step=<1, or 2 for odd n only>, value=<exact sum>)
claim("fourier", f=<Piecewise in x over one period>, start=<left end>, period=<2L>, a0_half=<constant term a0/2>,
      an=<expr in n>, bn=<expr in n>)                       # f(x) = a0/2 + sum(an cos(n pi x/L) + bn sin(n pi x/L))
claim("pde_series", pde=Eq(...), term=<general term in n, x, t>, step=<1 or 2>, length=<L>,
      bcs=[[x_value, u_value], ...], u0=<u(x,0)>, ut0=<u_t(x,0), or None for first order in t>)
    # u = Function('u')(x, t); the solution is the sum of term over n = 1, 1+step, ...
claim("eigen", matrix=Matrix(...), eigenvalues=[... repeated by multiplicity], eigenvectors=[[value, Matrix(...)], ...])
claim("linear_system", A=Matrix(...), b=Matrix(...), conditions=[expr, ...], solution=<Matrix or None>)
    # conditions: each expr = 0 is needed for consistency ([] = always consistent, None = never consistent)
    # solution: the complete solution with free parameters (use symbols like k1), or None
claim("span", vectors=[Matrix(...), ...], target=Matrix(...), in_span=True/False, coefficients=[...] or None)
claim("basis", vectors=[Matrix(...), ...], dim=n, is_basis=True/False)
claim("subspace", variables=[...], conditions=[expr, ...], is_subspace=True/False, counterexample=None or [u, v, k])
    # the set = points where every expr = 0; a counterexample is two members u, v and a scalar k where u+v or k*u leaves it
claim("lp", variables=[...], objective=<expr>, sense="max"/"min", constraints=[<Le/Ge/Eq relations, incl. x >= 0>],
      integer=[vars that must be integers], point={var: value}, value=<optimal value>)

Also call step("label", value) for every intermediate result a student would write in an exam answer, in order, \
6–12 steps: e.g. the auxiliary equation and its roots, complementary function, particular integral, A − λI, the \
characteristic polynomial, the row-reduced matrix, partial fractions, each Fourier coefficient integral, and finally \
step("Final answer", ...). Labels are short phrases; values are SymPy objects.

Polynomials in P2 are coefficient vectors Matrix([constant, x coefficient, x^2 coefficient]).
Use exact numbers (Rational(1, 3), pi, sqrt(2)), never decimals. If part of the question fits none of these kinds \
(e.g. a proof or a sketch), call claim("unverifiable", reason="...") for that part.
Write short, plain code: no comments, no print(), no explanations outside the code block, at most 60 lines."""

EXPLAIN_SYSTEM = """You are Mist, a friendly study buddy explaining a solved maths question to a student, the way a \
good tutor writes a model answer. The working was computed by SymPy and is listed as numbered values ⟦1⟧, ⟦2⟧, …

Write the explanation in Markdown:
- One short sentence naming the method and why it applies.
- Numbered steps. Each says in words what we do and why, then shows the result by writing its placeholder, e.g. \
"Setting det(A − λI) = 0 gives the characteristic equation ⟦2⟧."
- A final line: **Answer:** followed by the placeholder(s) of the final result, named (e.g. "y = ⟦7⟧").

Hard rule: never write a digit, number, matrix, equation or formula yourself. Every value appears only as a \
placeholder ⟦k⟧, which will be replaced with the exact computed value. Short standard formulas that are part of \
the method (det(A − λI) = 0, y(0)) are fine. Under 170 words."""

PLACEHOLDER = re.compile(r"⟦(\d+)⟧")


def chat(system, user, model, max_tokens=3000, temperature=0.2, timeout=150):
    """Streams the reply and stops on our own limits. Measured 2026-11-04: LM Studio sometimes ignored max_tokens
    and generated for 30+ minutes, and urllib's timeout never fired on the open connection."""
    body = {"model": model, "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
            "temperature": temperature, "max_tokens": max_tokens, "reasoning_effort": "none", "stream": True}
    req = urllib.request.Request(LMSTUDIO, json.dumps(body).encode(), {"Content-Type": "application/json"})
    deadline, text = time.time() + timeout, ""
    with urllib.request.urlopen(req, timeout=30) as r:
        for raw in r:  # closing the connection early makes LM Studio stop generating
            line = raw.decode("utf-8", "ignore").strip()
            if not line.startswith("data:") or line.endswith("[DONE]"):
                continue
            try:
                delta = json.loads(line[5:])["choices"][0].get("delta", {}).get("content") or ""
            except (ValueError, KeyError, IndexError):
                continue
            text += delta
            if time.time() > deadline or len(text) > max_tokens * 4:
                break
    return text


def extract_code(reply):
    m = re.search(r"```(?:python)?[^\n]*\n(.*?)(?:```|\Z)", reply, re.S)  # also recovers a reply cut off mid-code
    return m.group(1) if m else reply


def explain(question, steps, model):
    """Model writes prose with placeholders; code fills in the computed values. Falls back to a plain step list."""
    listing = "\n".join(f"⟦{i}⟧ {label}: {value}" for i, (label, value) in enumerate(steps, 1))
    user = f"Question:\n{question}\n\nComputed working:\n{listing}"
    for _ in range(2):
        prose = chat(EXPLAIN_SYSTEM, user, model, max_tokens=700, temperature=0.3, timeout=120)
        bare = PLACEHOLDER.sub("", prose)
        bare = re.sub(r"(?m)^\s*\d+[.)]\s", "", bare)  # step numbering is fine
        refs = [int(k) for k in PLACEHOLDER.findall(prose)]
        # Numbers copied from the question or the computed working are fine ("det(A − λI) = 0", "A + 2I");
        # a number appearing nowhere there was computed by the model itself, so the draft is rejected.
        known = set(re.findall(r"\d+(?:\.\d+)?", question + " " + " ".join(v for _, v in steps))) | {"0", "1"}
        invented = [n for n in re.findall(r"\d+(?:\.\d+)?", bare) if n not in known]
        if not invented and refs and all(1 <= k <= len(steps) for k in refs):
            return PLACEHOLDER.sub(lambda m: steps[int(m.group(1)) - 1][1], prose), True
        user += "\n\n(Your last draft wrote numbers that aren't in the working. Use ⟦k⟧ placeholders for every computed value.)"
    plain = "\n".join(f"{i}. {label}: {value}" for i, (label, value) in enumerate(steps, 1))
    return plain, False


def solve(question, model, retries=2, with_explanation=True):
    log = {"question": question, "model": model, "attempts": []}
    t0 = time.time()
    user = f"Question:\n{question}"
    for attempt in range(retries + 1):
        try:
            reply = chat(CODE_SYSTEM, user, model)
        except Exception as e:
            log["attempts"].append({"code": "", "error": f"model call failed: {e}", "claims": None, "verdicts": [], "steps": []})
            log["status"] = "failed"
            break
        code = extract_code(reply)
        claims, err, steps = sandbox.run_code(code)
        verdicts = sandbox.verify(claims) if claims else []
        log["attempts"].append({"code": code, "error": err, "claims": claims, "verdicts": verdicts, "steps": steps})
        if claims and all(v["verdict"] == "verified" for v in verdicts):
            log["status"] = "verified"
            break
        problems = err or "\n".join(f"- claim {i + 1} ({c['kind']}): {v['verdict']}: {v['why']}"
                                    for i, (c, v) in enumerate(zip(claims, verdicts)) if v["verdict"] != "verified")
        log["status"] = "unverifiable" if claims and not any(v["verdict"] == "failed" for v in verdicts) else "failed"
        user = (f"Question:\n{question}\n\nYour previous code:\n```python\n{code}\n```\n\nIt failed with:\n{problems}\n\n"
                "Fix it and reply with the full corrected code only (short, no comments). Re-read the question: "
                "make sure every claim answers exactly what is asked.")
    log["solve_s"] = round(time.time() - t0, 1)
    if log["status"] == "verified" and with_explanation:
        steps = log["attempts"][-1]["steps"]
        if steps:
            log["explanation"], log["explained_by_model"] = explain(question, steps, model)
    log["total_s"] = round(time.time() - t0, 1)
    return log


CHECK_NAMES = {"ode": "solution checked by substituting into the equation", "laplace": "transform checked numerically",
               "inverse_laplace": "inverse checked by transforming back numerically", "eigen": "eigenvalues and A·v = λv checked",
               "fourier": "coefficients checked by numerical integration", "pde_series": "PDE, boundary and initial conditions checked",
               "linear_system": "consistency checked by rank", "span": "checked by rank", "basis": "checked by rank",
               "subspace": "closure checked", "lp": "optimum confirmed by an independent solver",
               "series_sum": "sum checked numerically", "integral": "checked by numerical integration"}


def render(log):
    if log["status"] == "verified":
        last = log["attempts"][-1]
        checks = "; ".join(dict.fromkeys(CHECK_NAMES.get(c["kind"], c["kind"]) for c in last["claims"]))
        return f"{log.get('explanation', '')}\n\n✓ Verified: {checks}."
    last = log["attempts"][-1]
    why = last["error"] or "; ".join(v["why"] for v in last["verdicts"] if v["verdict"] != "verified")
    return f"I couldn't solve this reliably, so I won't guess.\n(Last problem: {why.strip().splitlines()[-1][:160]})"


if __name__ == "__main__":
    model = os.environ.get("MIST_LOCAL_MODEL", "qwen/qwen3.5-4b")
    log = solve(" ".join(sys.argv[1:]), model)
    print(render(log))
    print(f"\n[{log['status']} · {len(log['attempts'])} attempt(s) · solve {log['solve_s']}s · total {log['total_s']}s]")
