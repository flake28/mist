import Foundation

/// Turns LaTeX math in answers into readable Unicode (x², √x, α, H₂O, a/b).
/// Lightweight on purpose: no web view or math engine. Complex layouts (matrices, stacked limits) degrade to inline text.
enum LaTeX {
    /// Finds $$…$$, \[…\], \(…\), $…$ (and bare \ce{…}) and converts their contents.
    static func replaceMath(in text: String) -> String {
        var s = text
        let patterns = [
            #"\$\$(.+?)\$\$"#,
            #"\\\[(.+?)\\\]"#,
            #"\\\((.+?)\\\)"#,
            // Inline $…$: no space just inside the dollars and no digit right after (so "$5 and $10" stays money).
            #"(?<![\\$\w])\$(?=\S)([^$\n]+?)(?<=\S)\$(?!\d)"#,
            #"(\\ce\{(?:[^{}]|\{[^{}]*\})*\})"#,
        ]
        for pattern in patterns {
            let regex = try! NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
            for match in regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
                guard let whole = Range(match.range, in: s), let inner = Range(match.range(at: 1), in: s) else { continue }
                s.replaceSubrange(whole, with: toUnicode(String(s[inner])).trimmingCharacters(in: .whitespaces))
            }
        }
        return s
    }

    static func toUnicode(_ tex: String) -> String {
        var parser = Parser(chars: Array(tex))
        return parser.parse(until: nil)
            .replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
    }

    // MARK: - Parser

    private struct Parser {
        let chars: [Character]
        var i = 0

        mutating func parse(until end: Character?) -> String {
            var out = ""
            while i < chars.count {
                let ch = chars[i]
                if let end, ch == end { break }
                switch ch {
                case "\\": out += command()
                case "^": i += 1; out += script(group(), sup: true)
                case "_": i += 1; out += script(group(), sup: false)
                case "{": i += 1; out += parse(until: "}"); skip("}")
                case "}": i += 1
                case "*": out += "×"; i += 1
                case "~": out += " "; i += 1
                default: out.append(ch); i += 1
                }
            }
            return out
        }

        /// A braced group, a command, or a single character.
        mutating func group() -> String {
            while i < chars.count && chars[i] == " " { i += 1 }
            guard i < chars.count else { return "" }
            switch chars[i] {
            case "{":
                i += 1
                let s = parse(until: "}")
                skip("}")
                return s
            case "\\":
                return command()
            default:
                defer { i += 1 }
                return String(chars[i])
            }
        }

        mutating func skip(_ ch: Character) { if i < chars.count && chars[i] == ch { i += 1 } }

        mutating func command() -> String {
            i += 1 // the backslash
            guard i < chars.count else { return "" }
            guard chars[i].isLetter else { // \, \; \! \\ \{ etc.
                let ch = chars[i]
                i += 1
                switch ch {
                case ",", ";", ":", " ": return " "
                case "!": return ""
                case "\\": return "\n"
                default: return String(ch)
                }
            }
            var name = ""
            while i < chars.count && chars[i].isLetter { name.append(chars[i]); i += 1 }

            switch name {
            case "frac", "dfrac", "tfrac":
                let a = group(), b = group()
                return LaTeX.fractions["\(a)/\(b)"] ?? "\(wrap(a))/\(wrap(b))"
            case "sqrt":
                var index = ""
                if i < chars.count && chars[i] == "[" {
                    i += 1
                    index = parse(until: "]")
                    skip("]")
                }
                let radicand = group()
                let root = index == "3" ? "∛" : index == "4" ? "∜" : script(index, sup: true) + "√"
                return (index.isEmpty ? "√" : root) + wrap(radicand)
            case "text", "textrm", "textbf", "textit", "mathrm", "mathbf", "mathit", "mathsf", "mathcal",
                 "boldsymbol", "operatorname", "mbox", "emph":
                return group()
            case "mathbb":
                let g = group()
                return LaTeX.blackboard[g] ?? g
            case "ce":
                return chem(rawGroup())
            case "vec": return group() + "\u{20D7}"
            case "hat": return group() + "\u{0302}"
            case "bar", "overline": return group() + "\u{0305}"
            case "dot": return group() + "\u{0307}"
            case "left", "right", "big", "Big", "bigg", "Bigg", "bigl", "bigr", "Bigl", "Bigr",
                 "displaystyle", "textstyle", "limits", "nolimits":
                return ""
            case "quad", "qquad": return "  "
            default:
                let symbol = LaTeX.symbols[name] ?? name // unknown command: show its name, not the backslash
                // LaTeX ignores the space after a command; keep it only around operators like × or ≈.
                if symbol.allSatisfy({ $0.isLetter || "∇∂".contains($0) }) {
                    while i < chars.count && chars[i] == " " { i += 1 }
                }
                return symbol
            }
        }

        /// A braced group's text, unparsed (mhchem has its own syntax).
        mutating func rawGroup() -> String {
            while i < chars.count && chars[i] == " " { i += 1 }
            guard i < chars.count, chars[i] == "{" else { return "" }
            i += 1
            var depth = 1, out = ""
            while i < chars.count {
                if chars[i] == "{" { depth += 1 }
                if chars[i] == "}" { depth -= 1; if depth == 0 { i += 1; break } }
                out.append(chars[i])
                i += 1
            }
            return out
        }

        func wrap(_ s: String) -> String {
            s.count <= 1 || s.allSatisfy({ $0.isLetter || $0.isNumber }) ? s : "(\(s))"
        }

        func script(_ s: String, sup: Bool) -> String {
            let table = sup ? LaTeX.superscripts : LaTeX.subscripts
            let mapped = s.compactMap { table[$0] }
            if mapped.count == s.count { return String(mapped) }
            return (sup ? "^" : "_") + wrap(s)
        }

        /// mhchem-lite: H2O → H₂O, Na+ → Na⁺, SO4^2- → SO₄²⁻, -> → →, <=> → ⇌.
        func chem(_ s: String) -> String {
            var t = s.replacingOccurrences(of: "<=>", with: " ⇌ ").replacingOccurrences(of: "->", with: " → ")
            t = t.replacingOccurrences(of: "  ", with: " ")
            let c = Array(t)
            var out = ""
            var k = 0
            while k < c.count {
                let ch = c[k]
                let prev = out.last
                let next: Character? = k + 1 < c.count ? c[k + 1] : nil
                let afterFormula = prev.map { $0.isLetter || $0 == ")" || $0 == "]" || LaTeX.subscripts.values.contains($0) } ?? false
                if ch == "^" { // explicit charge: ^2- or ^{2-}
                    k += 1
                    var charge = ""
                    if k < c.count && c[k] == "{" {
                        k += 1
                        while k < c.count && c[k] != "}" { charge.append(c[k]); k += 1 }
                        k += 1
                    } else {
                        while k < c.count && c[k] != " " { charge.append(c[k]); k += 1 }
                    }
                    out += String(charge.compactMap { LaTeX.superscripts[$0] })
                    continue
                }
                if afterFormula, let sub = LaTeX.subscripts[ch], ch.isNumber {
                    out.append(sub)
                } else if afterFormula, ch == "+" || ch == "-", next == nil || next == " ", let sup = LaTeX.superscripts[ch] {
                    out.append(sup)
                } else {
                    out.append(ch)
                }
                k += 1
            }
            return out
        }
    }

    // MARK: - Tables

    static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "−": "⁻", "=": "⁼", "(": "⁽", ")": "⁾", "∘": "°", "′": "′", "*": "*",
        "a": "ᵃ", "b": "ᵇ", "c": "ᶜ", "d": "ᵈ", "e": "ᵉ", "f": "ᶠ", "g": "ᵍ", "h": "ʰ", "i": "ⁱ", "j": "ʲ",
        "k": "ᵏ", "l": "ˡ", "m": "ᵐ", "n": "ⁿ", "o": "ᵒ", "p": "ᵖ", "r": "ʳ", "s": "ˢ", "t": "ᵗ", "u": "ᵘ",
        "v": "ᵛ", "w": "ʷ", "x": "ˣ", "y": "ʸ", "z": "ᶻ", "T": "ᵀ",
    ]

    static let subscripts: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "−": "₋", "=": "₌", "(": "₍", ")": "₎",
        "a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ", "j": "ⱼ", "k": "ₖ", "l": "ₗ", "m": "ₘ", "n": "ₙ", "o": "ₒ",
        "p": "ₚ", "r": "ᵣ", "s": "ₛ", "t": "ₜ", "u": "ᵤ", "v": "ᵥ", "x": "ₓ",
    ]

    static let fractions: [String: String] = [
        "1/2": "½", "1/3": "⅓", "2/3": "⅔", "1/4": "¼", "3/4": "¾", "1/5": "⅕", "1/6": "⅙", "1/8": "⅛",
    ]

    static let blackboard: [String: String] = ["R": "ℝ", "N": "ℕ", "Z": "ℤ", "Q": "ℚ", "C": "ℂ"]

    static let symbols: [String: String] = [
        // Greek
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "varepsilon": "ε", "zeta": "ζ",
        "eta": "η", "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν",
        "xi": "ξ", "pi": "π", "rho": "ρ", "sigma": "σ", "tau": "τ", "upsilon": "υ", "phi": "φ", "varphi": "φ",
        "chi": "χ", "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ",
        "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
        // Operators and relations
        "times": "×", "cdot": "·", "div": "÷", "pm": "±", "mp": "∓", "ast": "∗",
        "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥", "neq": "≠", "ne": "≠", "approx": "≈", "sim": "∼",
        "simeq": "≃", "equiv": "≡", "propto": "∝", "ll": "≪", "gg": "≫",
        "in": "∈", "notin": "∉", "subset": "⊂", "subseteq": "⊆", "cup": "∪", "cap": "∩", "emptyset": "∅",
        "forall": "∀", "exists": "∃", "neg": "¬", "land": "∧", "lor": "∨",
        "to": "→", "rightarrow": "→", "leftarrow": "←", "Rightarrow": "⇒", "Leftarrow": "⇐",
        "leftrightarrow": "↔", "Leftrightarrow": "⇔", "implies": "⇒", "iff": "⇔", "mapsto": "↦",
        "rightleftharpoons": "⇌", "uparrow": "↑", "downarrow": "↓",
        // Big operators and calculus
        "sum": "Σ", "prod": "∏", "int": "∫", "iint": "∬", "oint": "∮", "partial": "∂", "nabla": "∇",
        "infty": "∞", "lim": "lim", "log": "log", "ln": "ln", "exp": "exp",
        "sin": "sin", "cos": "cos", "tan": "tan", "max": "max", "min": "min",
        // Misc
        "degree": "°", "circ": "∘", "prime": "′", "hbar": "ħ", "ell": "ℓ", "angle": "∠", "perp": "⊥",
        "parallel": "∥", "ldots": "…", "cdots": "⋯", "dots": "…", "vdots": "⋮",
        "langle": "⟨", "rangle": "⟩", "lvert": "|", "rvert": "|", "mid": "|", "therefore": "∴", "because": "∵",
        "percent": "%",
    ]
}
