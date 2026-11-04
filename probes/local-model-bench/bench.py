"""Mist — Phase 0, Test 3: local model speed + quality on this Mac (via LM Studio).

Usage: python3 bench.py <model-key> [<model-key> ...]     (keys as shown by `lms ls`)
Starts LM Studio's local server if needed. Adds to results.csv (timings) and answers.json, and regenerates
answers.md (every model's answers side by side, for judging quality). Re-running a model replaces its rows.
"""

import csv
import json
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

LMS = str(Path.home() / ".lmstudio/bin/lms")
SERVER = "http://localhost:1234/v1"
HERE = Path(__file__).parent

# Same instructions Mist sends to Gemini (app/Sources/Prompt.swift), so answers are comparable.
SYSTEM = (
    "You are Mist, a study buddy built into the user's Mac. The user is reading and wants to understand "
    "something quickly without leaving their document. Keep it short and easy to scan: usually 2–4 sentences. "
    "Bold the one or two key terms. Use a short bulleted list only for steps or a few distinct points. "
    "No headings, no preamble, and go longer only if the user asks. Write maths and chemistry with Unicode "
    "(x², √x, ½, ≈, →, α, H₂O), not LaTeX. Use plain language and define jargon. Captured text comes from OCR "
    "and may contain small errors; work with the most likely reading. Don't invent specifics about people, "
    "institutions, dates or numbers that aren't in the text: if the text doesn't say and you aren't sure, say so "
    "briefly instead of guessing."
)

def selection(app, text, question="Explain this."):
    return f'App: {app}\nSelected text:\n"""\n{text}\n"""\n\nQuestion: {question}'

PROMPTS = {
    "biology": selection("Preview", "Oxidative phosphorylation happens across the inner mitochondrial membrane, "
                         "driven by a proton gradient built by the electron transport chain."),
    "chemistry": selection("Safari", "The Gibbs free energy change ΔG = ΔH − TΔS determines whether a reaction is "
                           "spontaneous: if ΔG < 0 the reaction proceeds."),
    "maths": selection("Notes", "x = (−b ± √(b² − 4ac)) / 2a"),
    "no-guessing": selection("Notes", "Lecture 4 notes — Prof. J. Smith", "Who is this professor?"),
    "general": "What's the difference between mitosis and meiosis?",
}


def lms(*args):
    return subprocess.run([LMS, *args], capture_output=True, text=True).stdout


def chat(model, prompt):
    """Streams one answer. First word = first visible answer text, so any hidden 'thinking' counts as delay.
    Returns (first_word_s, total_s, tokens, tokens_per_s, thought_chars, text)."""
    body = json.dumps({
        "model": model, "stream": True, "stream_options": {"include_usage": True}, "temperature": 0.7,
        # Thinking off. Measured 2026-11-02: without this Qwen 3.5 9B thought for ~2 min before answering;
        # chat_template_kwargs, reasoning.effort and "/no_think" were all ignored by LM Studio.
        "reasoning_effort": "none",
        "messages": [{"role": "system", "content": SYSTEM}, {"role": "user", "content": prompt}],
    }).encode()
    req = urllib.request.Request(f"{SERVER}/chat/completions", data=body, headers={"Content-Type": "application/json"})
    start = time.perf_counter()
    first, first_any, text, thought, tokens = None, None, "", 0, 0
    with urllib.request.urlopen(req, timeout=600) as resp:
        for raw in resp:
            line = raw.decode().strip()
            if not line.startswith("data:") or line == "data: [DONE]":
                continue
            chunk = json.loads(line[5:])
            if chunk.get("usage"):
                tokens = chunk["usage"].get("completion_tokens", 0)
            for choice in chunk.get("choices", []):
                delta = choice.get("delta", {})
                reasoning = delta.get("reasoning_content") or delta.get("reasoning") or ""
                thought += len(reasoning)
                piece = delta.get("content") or ""
                if (piece or reasoning) and first_any is None:
                    first_any = time.perf_counter() - start
                if piece and first is None:
                    first = time.perf_counter() - start
                text += piece
    total = time.perf_counter() - start
    gen_time = total - (first_any or total) # tokens include any thinking, so time them from the first token of any kind
    tps = tokens / gen_time if gen_time > 0 and tokens else 0
    return first or total, total, tokens, tps, thought, text


def memory(model):
    for line in lms("ps").splitlines():
        if model in line:
            parts = line.split()
            sizes = [f"{parts[i - 1]} {p}" for i, p in enumerate(parts) if p in ("GB", "MB", "GiB", "MiB")]
            return sizes[0] if sizes else line.strip()
    return "?"


def main(models):
    if "running" not in lms("server", "status").lower():
        lms("server", "start")
    rows = []
    answers = json.loads((HERE / "answers.json").read_text()) if (HERE / "answers.json").exists() else {}
    for model in models:
        print(f"\n=== {model}")
        lms("unload", "--all")

        t = time.perf_counter()
        lms("load", model, "--identifier", model, "-y")
        load_s = time.perf_counter() - t
        mem = memory(model)
        print(f"  load      {load_s:5.2f}s   memory {mem}")

        # First question right after loading (still includes any one-off warm-up).
        f, total, n, tps, thought, _ = chat(model, PROMPTS["general"])
        rows.append([model, "first", "general", f"{f:.2f}", f"{total:.2f}", n, f"{tps:.1f}", thought, f"{load_s:.2f}", mem])
        print(f"  first     first word {f:5.2f}s")

        for name, prompt in PROMPTS.items():
            f, total, n, tps, thought, text = chat(model, prompt)
            rows.append([model, "warm", name, f"{f:.2f}", f"{total:.2f}", n, f"{tps:.1f}", thought, "", ""])
            answers.setdefault(name, {})[model] = text.strip()
            note = f"  (thought {thought} chars first)" if thought else ""
            print(f"  {name:11} first word {f:5.2f}s  total {total:5.2f}s  {n:4d} tok  {tps:5.1f} tok/s{note}")
        lms("unload", model)

    header = ["model", "phase", "prompt", "first_word_s", "total_s", "tokens", "tokens_per_s",
              "thought_chars", "load_s", "memory"]
    previous = []
    if (HERE / "results.csv").exists():
        with open(HERE / "results.csv", newline="") as fh:
            previous = [r for r in list(csv.reader(fh))[1:] if r and r[0] not in models]
    with open(HERE / "results.csv", "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(header)
        w.writerows(previous + rows)
    (HERE / "answers.json").write_text(json.dumps(answers, ensure_ascii=False, indent=1))

    with open(HERE / "answers.md", "w") as fh:
        fh.write("# Test 3: local model answers (same prompts, same instructions as Mist)\n\n")
        for name, by_model in answers.items():
            fh.write(f"## {name}\n\n**Prompt:**\n\n```\n{PROMPTS[name]}\n```\n\n")
            for model, text in by_model.items():
                fh.write(f"### {model}\n\n{text}\n\n")
    print(f"\nWrote {HERE / 'results.csv'} and {HERE / 'answers.md'}")


if __name__ == "__main__":
    main(sys.argv[1:])
