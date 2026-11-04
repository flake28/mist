"""Independent checks for solver claims (stdin: claims JSON; stdout: verdicts JSON). Runs inside sandbox.sb.

Each check tests the CLAIMED RESULT directly (substitution, numeric integration, rank, an independent solver),
never by re-running the model's method. Verdicts: "verified", "failed" (claim is wrong), "unverifiable".
"""
import json, random, sys
import mpmath as mp
import sympy as sp

mp.mp.dps = 30
TOL = 1e-8


class Unverifiable(Exception):
    pass


# ---------- parsing ----------

SREPR_NS = {}
exec("from sympy import *", SREPR_NS)
SREPR_NS["ExprCondPair"] = sp.functions.elementary.piecewise.ExprCondPair

def I(v):
    return int(de(v)) if v is not None else None

def de(v):
    if isinstance(v, dict) and "__sympy__" in v:
        return sp.sympify(eval(v["__sympy__"], SREPR_NS))  # srepr strings from our own runner
    if isinstance(v, dict) and "__dict__" in v:
        return {de(k): de(x) for k, x in v["__dict__"]}
    if isinstance(v, list):
        return [de(x) for x in v]
    return v


def sym(expr, name):
    """The symbol called `name` inside expr (assumptions may differ), else a fresh one."""
    for s in getattr(expr, "free_symbols", set()):
        if s.name == name:
            return s
    return sp.Symbol(name)


def plain(expr):
    """Rename every symbol to an assumption-free one, so x, x(real) and x(positive) compare equal."""
    if not isinstance(expr, sp.Basic):
        return expr
    return expr.xreplace({s: sp.Symbol(s.name) for s in expr.free_symbols})


def no_steps(expr):
    return expr.replace(sp.Heaviside, lambda a, *r: sp.Piecewise((0, a < 0), (1, True)))


def num(expr, **vals):
    """Evaluate expr numerically with mpmath, substituting symbols by name."""
    e = plain(no_steps(sp.sympify(expr)))
    e = e.subs({sp.Symbol(k): v for k, v in vals.items()})
    if e.free_symbols:
        raise Unverifiable(f"leftover symbols {sorted(map(str, e.free_symbols))}")
    return mp.mpmathify(complex(sp.N(e, 30)))


def close(a, b, tol=TOL):
    return abs(a - b) <= tol * max(1, abs(a), abs(b))


def is_zero(expr, vars_, trials=6):
    """Symbolic simplify first, then random numeric points (handles what simplify can't)."""
    expr = plain(expr)
    if sp.simplify(expr) == 0:
        return True
    rnd = random.Random(1)
    for _ in range(trials):
        vals = {v: rnd.uniform(0.3, 2.7) for v in vars_}
        if not close(num(expr, **vals), 0, 1e-9):
            return False
    return True


# ---------- checks ----------

def check_ode(c):
    ode, sol = de(c["ode"]), de(c["solution"])
    ics = de(c.get("ics") or [])
    if isinstance(ode, sp.Equality):
        ode = ode.lhs - ode.rhs
    funcs = [f for f in ode.atoms(sp.Function) if isinstance(f, sp.core.function.AppliedUndef)]
    if len(funcs) != 1 or len(funcs[0].args) != 1:
        raise Unverifiable("need exactly one unknown function y(x)")
    y = funcs[0]
    x = y.args[0]
    order = max((d.derivative_count for d in ode.atoms(sp.Derivative)), default=0)
    sol = sol.subs(sym(sol, x.name), x)
    residual = ode.subs(y, sol).doit()
    consts = sorted((s for s in sol.free_symbols if s.name.startswith("C")), key=lambda s: s.name)
    if not is_zero(residual, [x.name] + [k.name for k in consts]):
        return "failed", "solution does not satisfy the equation"
    if ics:
        for x0, k, val in ics:
            if not is_zero(sp.diff(sol, x, I(k) if isinstance(k, dict) else int(k)).subs(x, x0) - val, [k.name for k in consts]):
                return "failed", f"initial condition y^({k})({x0}) = {val} not met"
        if consts:
            return "failed", "constants left in a solution that has initial conditions"
        return "verified", "satisfies the equation and every initial condition"
    # General solution: `order` independent arbitrary constants (non-zero Wronskian of ∂y/∂Ci).
    if len(consts) != order:
        return "failed", f"general solution of an order-{order} equation needs {order} constants, has {len(consts)}"
    basis = [sp.diff(sol, k) for k in consts]
    W = sp.Matrix([[sp.diff(b, x, i) for b in basis] for i in range(order)]).det()
    if is_zero(W, [x.name] + [k.name for k in consts]):
        return "failed", "the constants are not independent"
    return "verified", f"satisfies the equation, with {order} independent constants"


BREAKS = [0, 0.5, 1, 1.5, 2, 2.5, 3, mp.pi, 3.5, 4, 5, 2 * mp.pi, 7, 10, 20, mp.inf]


def laplace_num(f, s_val):
    tt = sp.Symbol("tt")
    g = sp.lambdify(tt, plain(no_steps(f)).subs(sp.Symbol("t"), tt), "mpmath")
    return mp.quad(lambda u: mp.exp(-s_val * u) * g(u), BREAKS)


def check_laplace(c, inverse=False):
    f, F = de(c["f"]), de(c["F"])
    fs = [str(s) for s in plain(f).free_symbols]
    if set(fs) - {"t"} or set(str(s) for s in plain(F).free_symbols) - {"s"}:
        raise Unverifiable("f must use only t and F only s")
    # Test just right of the rightmost pole: large s would shrink shifted terms like e^(−3s) below tolerance.
    sv = sym(F, "s")
    den = sp.denom(sp.together(F.replace(sp.exp, lambda *_: 1)))  # e^(−as) shifts have no poles
    poles = [complex(r).real for r in sp.Poly(den, sv).nroots()] if den.has(sv) else []
    a = max([0.0] + poles)
    pts = [a + 0.6, a + 1.1, a + 2.3]
    for s_val in pts:
        got, want = laplace_num(f, s_val), num(F, s=s_val)
        if abs(got - want) > 1e-9 * max(abs(want), 1e-6):
            return "failed", f"∫e^(−st)f(t)dt ≠ F(s) at s = {s_val:.2f}"
    return "verified", "F(s) matches ∫₀^∞ e^(−st) f(t) dt numerically at s = " + ", ".join(f"{p:.1f}" for p in pts)


def check_integral(c):
    integrand, x, res = de(c["integrand"]), de(c["var"]), de(c["result"])
    lo, hi = de(c.get("lower")), de(c.get("upper"))
    if lo is None and hi is None:
        if is_zero(sp.diff(res, x) - integrand, [x.name]):
            return "verified", "differentiating the result gives the integrand"
        return "failed", "derivative of the result is not the integrand"
    xs = sp.Symbol("xs")
    g = sp.lambdify(xs, plain(no_steps(integrand)).subs(sp.Symbol(x.name), xs), "mpmath")
    a, b = num(lo).real, (mp.inf if hi == sp.oo else num(hi).real)
    val = mp.quadosc(g, [a, mp.inf], omega=1) if b == mp.inf else mp.quad(g, [a, b])
    if close(val, num(res), 1e-7):
        return "verified", "matches numerical integration"
    return "failed", f"numerical value is {mp.nstr(val, 10)}"


def check_series(c):
    term, val = de(c["term"]), de(c["value"])
    start, step = I(c.get("start", 1)), I(c.get("step", 1))
    n = sym(term, "n")
    k = sp.Symbol("k")
    g = sp.lambdify(k, plain(term).subs(sp.Symbol("n"), start + step * k), "mpmath")
    s = mp.nsum(g, [0, mp.inf])
    if close(s, num(val), 1e-9):
        return "verified", "matches the numerically summed series"
    return "failed", f"series sums to {mp.nstr(s, 12)}"


def check_fourier(c):
    f, start, period = de(c["f"]), de(c["start"]), de(c["period"])
    a0h, an, bn = de(c["a0_half"]), de(c["an"]), de(c["bn"])
    x = sym(f, "x")
    L = num(period).real / 2
    a = num(start).real
    xs = sp.Symbol("xs")
    g = sp.lambdify(xs, plain(f).subs(sp.Symbol("x"), xs), "mpmath")
    pts = sorted({a, a + L, a + 2 * L, a + L / 2, a + 3 * L / 2})
    if not close(mp.quad(g, pts) / (2 * L), num(a0h), 1e-8):
        return "failed", "constant term wrong"
    for n_val in range(1, 8):
        ca = mp.quad(lambda u: g(u) * mp.cos(n_val * mp.pi * u / L), pts) / L
        cb = mp.quad(lambda u: g(u) * mp.sin(n_val * mp.pi * u / L), pts) / L
        if not close(ca, num(an, n=n_val), 1e-8):
            return "failed", f"a_{n_val} wrong (should be {mp.nstr(ca, 8)})"
        if not close(cb, num(bn, n=n_val), 1e-8):
            return "failed", f"b_{n_val} wrong (should be {mp.nstr(cb, 8)})"
    return "verified", "a₀, aₙ, bₙ match numerical integration for n = 1…7"


def check_pde_series(c):
    pde, term = de(c["pde"]), de(c["term"])
    step, Lval = I(c.get("step", 1)), de(c["length"])
    if isinstance(pde, sp.Equality):
        pde = pde.lhs - pde.rhs
    u = [f for f in pde.atoms(sp.Function) if isinstance(f, sp.core.function.AppliedUndef)]
    if len(u) != 1:
        raise Unverifiable("need one unknown u(x, t)")
    u = u[0]
    x, t = u.args
    n = sym(term, "n")
    T = term.subs({sym(term, "x"): x, sym(term, "t"): t})
    params = {s.name: 1.37 for s in (pde.free_symbols | T.free_symbols) if s.name not in ("x", "t", "n")}
    nk = sp.Symbol("nk", integer=True, positive=True)
    for n_val in (1, 2, 3, 5):
        Tn = T.subs(n, n_val)
        res = pde.subs(u, Tn).doit()
        if not is_zero(res.subs({sp.Symbol(k): v for k, v in params.items()}), ["x", "t"]):
            return "failed", f"term n = {n_val} does not satisfy the PDE"
        for xb, ub in de(c.get("bcs") or []):
            if not is_zero((Tn.subs(x, xb) - ub).subs({sp.Symbol(k): v for k, v in params.items()}), ["t"]):
                return "failed", f"boundary condition at x = {xb} fails"
    N = 4000
    tt = sp.Symbol("tt"); xx = sp.Symbol("xx"); kk = sp.Symbol("kk")
    Tp = plain(T).subs({sp.Symbol(k): v for k, v in params.items()})
    u0f = sp.lambdify((kk, xx), Tp.subs({sp.Symbol("n"): kk, sp.Symbol("t"): 0, sp.Symbol("x"): xx}), "mpmath")
    ut = sp.diff(Tp, sp.Symbol("t")).subs(sp.Symbol("t"), 0)
    utf = sp.lambdify((kk, xx), ut.subs({sp.Symbol("n"): kk, sp.Symbol("x"): xx}), "mpmath")
    L = num(Lval).real
    mp.mp.dps = 15
    try:
        for frac in (0.23, 0.5, 0.71):
            xv = frac * L
            approx = mp.fsum(u0f(1 + step * k, xv) for k in range(N))
            want = num(de(c["u0"]), x=xv, **params)
            if not close(approx, want, 2e-3):
                return "failed", f"u(x,0) ≠ initial shape at x = {mp.nstr(xv, 4)}"
            if c.get("ut0") is not None:
                v = mp.fsum(utf(1 + step * k, xv) for k in range(200))
                if not close(v, num(de(c["ut0"]), x=xv, **params), 2e-3):
                    return "failed", "initial velocity condition fails"
    finally:
        mp.mp.dps = 30
    return "verified", "each term satisfies the PDE and boundary conditions; the series reproduces the initial condition"


def as_matrix(v):
    return sp.Matrix(v) if not isinstance(v, sp.MatrixBase) else v


def check_eigen(c):
    A = as_matrix(de(c["matrix"]))
    claimed = sorted(sp.nsimplify(v) for v in de(c["eigenvalues"]))
    lam = sp.Symbol("lam")
    true = sorted(sp.roots(A.charpoly(lam).as_expr(), lam, multiple=True))
    if len(true) != A.rows:
        raise Unverifiable("characteristic polynomial has no closed-form roots")
    if [sp.simplify(a - b) for a, b in zip(claimed, true)] != [0] * len(true) or len(claimed) != len(true):
        return "failed", f"eigenvalues are {true}"
    for lv, v in de(c.get("eigenvectors") or []):
        v = as_matrix(v)
        if v.is_zero_matrix or not (A * v - lv * v).applyfunc(sp.simplify).is_zero_matrix:
            return "failed", f"{list(v)} is not an eigenvector for {lv}"
    return "verified", "eigenvalues are the roots of det(A − λI); A·v = λ·v holds for each vector"


def check_linear_system(c):
    A, b = as_matrix(de(c["A"])), as_matrix(de(c["b"]))
    conds, sol = de(c.get("conditions")), de(c.get("solution"))
    # Consistency conditions: left-null-space vectors w give w·b = 0.
    needed = [(w.T * b)[0] for w in A.T.nullspace()]
    params = sorted(b.free_symbols, key=str)
    if conds is None:  # claimed: never consistent
        if params or not needed or all(sp.simplify(e) == 0 for e in needed):
            return "failed", "the system can be consistent"
        return "verified", "rank(A) < rank([A|b]): inconsistent"
    if params:
        coef = lambda e: [sp.expand(e).coeff(p) for p in params]
        M_need, M_all = sp.Matrix([coef(e) for e in needed] or [[0] * len(params)]), sp.Matrix([coef(e) for e in needed + list(conds)] or [[0] * len(params)])
        M_claim = sp.Matrix([coef(e) for e in conds] or [[0] * len(params)])
        if not (M_need.rank() == M_all.rank() == M_claim.rank()):
            return "failed", f"consistency needs {[sp.Eq(e, 0) for e in needed] or 'nothing'}"
    else:
        consistent = all(sp.simplify(e) == 0 for e in needed)
        if consistent != (conds == []):
            return "failed", "consistency claim is wrong"
    if sol is not None:
        sol = as_matrix(sol)
        if not (A * sol - b).applyfunc(sp.simplify).is_zero_matrix:
            return "failed", "solution does not satisfy A·x = b"
        free = [s for s in sol.free_symbols if s not in b.free_symbols]
        if len(free) != A.cols - A.rank():
            return "failed", f"complete solution needs {A.cols - A.rank()} free parameter(s)"
    return "verified", "matches rank(A) = rank([A|b]) and A·x = b"


def check_span(c):
    vs = [as_matrix(v) for v in de(c["vectors"])]
    target = as_matrix(de(c["target"]))
    S = sp.Matrix.hstack(*vs)
    inside = S.rank() == sp.Matrix.hstack(S, target).rank()
    if bool(c["in_span"]) != inside:
        return "failed", "in-span claim is wrong (rank test)"
    coefs = de(c.get("coefficients"))
    if inside and coefs is not None:
        combo = sum((k * v for k, v in zip(coefs, vs)), sp.zeros(*target.shape))
        if not (combo - target).applyfunc(sp.simplify).is_zero_matrix:
            return "failed", "the given coefficients don't produce the vector"
    return "verified", "rank of the vectors with and without the target"


def check_basis(c):
    vs = [as_matrix(v) for v in de(c["vectors"])]
    dim = I(c["dim"])
    ok = len(vs) == dim and sp.Matrix.hstack(*vs).rank() == dim
    if bool(c["is_basis"]) != ok:
        return "failed", "basis claim is wrong (rank test)"
    return "verified", f"{len(vs)} vectors, rank {sp.Matrix.hstack(*vs).rank()} in dimension {dim}"


def check_subspace(c):
    vars_ = de(c["variables"])
    conds = de(c["conditions"])
    conds = [e.lhs - e.rhs if isinstance(e, sp.Equality) else e for e in conds]
    claim = bool(c["is_subspace"])
    polys = [sp.Poly(e, *vars_) for e in conds]
    if all(p.total_degree() <= 1 for p in polys):
        homogeneous = all(p.coeff_monomial(1) == 0 for p in polys)
        if claim != homogeneous:
            return "failed", "linear conditions: a subspace exactly when every condition is homogeneous (contains 0)"
        return "verified", "defined by linear equations, " + ("all homogeneous (closed under + and scaling)" if homogeneous else "not homogeneous (0 is not in the set)")
    if claim:
        raise Unverifiable("non-linear conditions: a 'yes' can't be checked mechanically")
    ce = de(c.get("counterexample"))
    if not ce:
        raise Unverifiable("non-linear conditions: need a counterexample to verify 'no'")
    u, v, k = ce
    member = lambda p: all(sp.simplify(e.subs(dict(zip(vars_, p)))) == 0 for e in conds)
    if not (member(u) and member(v)):
        return "failed", "counterexample points are not in the set"
    if member([a + b for a, b in zip(u, v)]) and member([k * a for a in u]):
        return "failed", "counterexample doesn't break closure"
    return "verified", "counterexample: members whose sum or multiple leaves the set"


def check_lp(c):
    from scipy.optimize import linprog, milp, LinearConstraint, Bounds
    import numpy as np
    vars_ = de(c["variables"])
    obj = de(c["objective"])
    sense = c["sense"]
    cons = de(c["constraints"])
    integer = de(c.get("integer") or [])
    point, value = de(c["point"]), de(c["value"])
    cvec = np.array([float(obj.coeff(v)) for v in vars_]) * (-1 if sense == "max" else 1)
    rows, lo, hi = [], [], []
    for r in cons:
        e = r.lhs - r.rhs
        coefs = [float(e.coeff(v)) for v in vars_]
        const = float(e.subs({v: 0 for v in vars_}))
        if sp.Poly(e, *vars_).total_degree() > 1:
            raise Unverifiable("non-linear constraint")
        rows.append(coefs)
        if isinstance(r, (sp.LessThan, sp.StrictLessThan)):
            lo.append(-np.inf); hi.append(-const)
        elif isinstance(r, (sp.GreaterThan, sp.StrictGreaterThan)):
            lo.append(-const); hi.append(np.inf)
        else:
            lo.append(-const); hi.append(-const)
    integrality = np.array([1 if v in integer else 0 for v in vars_])
    res = milp(cvec, constraints=LinearConstraint(np.array(rows), lo, hi), integrality=integrality,
               bounds=Bounds(-np.inf, np.inf))
    if not res.success:
        return ("verified", "solver agrees: no optimum") if value is None else ("failed", f"solver: {res.message}")
    best = -res.fun if sense == "max" else res.fun
    if value is None or not close(mp.mpf(best), num(value), 1e-7):
        return "failed", f"optimal value is {best:.6g}"
    pt = {v: point.get(v, point.get(sp.Symbol(v.name), 0)) for v in vars_} if isinstance(point, dict) else dict(zip(vars_, point))
    if not close(num(obj.subs(pt)), num(value), 1e-7):
        return "failed", "claimed point doesn't give the claimed value"
    for r in cons:
        if not bool(r.subs(pt)):
            return "failed", f"claimed point breaks {r}"
    return "verified", "an independent solver (SciPy MILP) finds the same optimum; the point is feasible"


CHECKS = {
    "ode": check_ode, "laplace": check_laplace, "inverse_laplace": lambda c: check_laplace(c, True),
    "integral": check_integral, "series_sum": check_series, "fourier": check_fourier,
    "pde_series": check_pde_series, "eigen": check_eigen, "linear_system": check_linear_system,
    "span": check_span, "basis": check_basis, "subspace": check_subspace, "lp": check_lp,
}


def verify(c):
    fn = CHECKS.get(c.get("kind"))
    if fn is None:
        return "unverifiable", c.get("reason") or f"no checker for '{c.get('kind')}'"
    try:
        out = fn(c)
        return out if isinstance(out, tuple) else ("unverifiable", str(out))
    except Unverifiable as e:
        return "unverifiable", str(e)
    except Exception as e:
        return "unverifiable", f"checker error: {type(e).__name__}: {e}"


if __name__ == "__main__":
    claims = json.loads(sys.stdin.read())
    print(json.dumps([dict(zip(("verdict", "why"), verify(c))) for c in claims]))
