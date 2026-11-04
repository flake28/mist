"""Readable Unicode for SymPy values (used for the working shown to students)."""
import re
import sympy as sp

SUP = str.maketrans("0123456789-()", "⁰¹²³⁴⁵⁶⁷⁸⁹⁻⁽⁾")


def _clean(expr):
    if not isinstance(expr, sp.Basic):
        return expr
    # y'' instead of Derivative(y(x), (x, 2)); y instead of y(x); u(t − a) instead of Heaviside.
    reps = {}
    for d in expr.atoms(sp.Derivative):
        f = d.expr.func.__name__ if hasattr(d.expr, "func") else str(d.expr)
        reps[d] = sp.Symbol(f + "′" * d.derivative_count if d.derivative_count <= 3 else f"{f}⁽{d.derivative_count}⁾")
    expr = expr.xreplace(reps)
    expr = expr.replace(lambda e: isinstance(e, sp.core.function.AppliedUndef) and len(e.args) == 1,
                        lambda e: sp.Symbol(e.func.__name__))
    return expr


def text(v):
    if isinstance(v, bool):
        return "yes" if v else "no"
    if isinstance(v, (list, tuple, set)):
        return ", ".join(text(x) for x in v)
    if isinstance(v, dict):
        return ", ".join(f"{text(k)} → {text(x)}" for k, x in v.items())
    if isinstance(v, sp.MatrixBase):
        if v.cols == 1:
            return "(" + ", ".join(text(x) for x in v) + ")ᵀ" if v.rows > 1 else text(v[0])
        return "[" + "; ".join("  ".join(text(x) for x in v.row(i)) for i in range(v.rows)) + "]"
    if isinstance(v, sp.Equality):
        return f"{text(v.lhs)} = {text(v.rhs)}"
    if isinstance(v, sp.Rel):
        op = {"<=": "≤", ">=": "≥", "<": "<", ">": ">", "!=": "≠"}[v.rel_op]
        return f"{text(v.lhs)} {op} {text(v.rhs)}"
    if not isinstance(v, sp.Basic):
        return str(v)
    s = sp.sstr(_clean(v))
    s = re.sub(r"\bHeaviside\(", "u(", s)
    s = re.sub(r"\blog\(", "ln(", s)
    s = re.sub(r"\bsqrt\((\w+)\)", r"√\1", s)
    s = s.replace("sqrt(", "√(")
    s = re.sub(r"\bexp\(([^()]+)\)", lambda m: "e^(" + m.group(1) + ")", s)
    s = re.sub(r"\bpi\b", "π", s)
    s = re.sub(r"\b(lam|lamda|lambda|lmbda)\b", "λ", s)
    s = re.sub(r"\boo\b", "∞", s)
    s = re.sub(r"\bI\b", "i", s)
    s = re.sub(r"\bC(\d)\b", lambda m: "C" + "₀₁₂₃₄₅₆₇₈₉"[int(m.group(1))], s)
    s = re.sub(r"\*\*(-?\d+)", lambda m: m.group(1).translate(SUP), s)
    s = s.replace("**", "^")
    s = re.sub(r"(\d)\*(?=[A-Za-zπλ√(])", r"\1", s)            # 3*x → 3x
    s = re.sub(r"\*(?=(?:sin|cos|tan|ln|e\^|u\(|√))", " ", s)   # x*cos(3x) → x cos(3x)
    s = re.sub(r"(?<=[A-Za-zπλ₀-₉²³])\*(?=[A-Za-zπλ])", "", s)   # C1*x → C₁x
    s = s.replace("*", "·")
    s = s.replace("-", "−")
    return s
