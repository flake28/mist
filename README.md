# Mist

A study buddy that lives inside macOS. Select text anywhere, click the small cloud that appears, and ask about it,
without switching apps.

- **Works in any app.** Mist reads the screen (Apple Vision OCR plus the image of the selected area), so it doesn't
  depend on each app exposing its text.
- **Never steals focus.** The panel is a non-activating floating window, so your selection stays put.
- **Three ways in:** select text and click the cloud; **Ctrl+Option+X** to drag a box over anything (text, maths,
  diagrams); **Ctrl+Option+Space** for a general question.
- **Answers:** Enter asks Gemini Flash. 🌐 or Cmd+Enter searches the web (Exa, with Wikipedia as a fallback) and
  answers with a local model, citing sources.
- **Verified maths solver (experimental, `solver/`):** a local model writes SymPy code, a sandbox runs it, and an
  independent checker verifies every result. It answers only when the checks pass, otherwise it says it couldn't
  solve the question.

## Requirements

- macOS 14+ on Apple Silicon, with the Xcode command-line tools (`xcode-select --install`)
- Permissions for the app you run Mist from (System Settings → Privacy & Security): **Accessibility** and
  **Screen Recording**
- A **Gemini API key** (free tier works): https://aistudio.google.com/apikey
- Optional: an **Exa API key** for web search (https://exa.ai), and **LM Studio** (https://lmstudio.ai) with a
  small model such as Qwen 3.5 4B (MLX) for search answers and the solver

## Setup

API keys are read from your home folder or the environment, never from this repository:

```sh
mkdir -p ~/.config/mist && chmod 700 ~/.config/mist
printf '%s' 'YOUR_GEMINI_KEY' > ~/.config/mist/gemini_key   # or export GEMINI_API_KEY=...
printf '%s' 'YOUR_EXA_KEY'    > ~/.config/mist/exa_key      # optional, or export EXA_API_KEY=...
chmod 600 ~/.config/mist/*
```

Build and run:

```sh
cd app && ./build.sh && ./mist
```

For local answers, start LM Studio's server (`lms server start`) and load a model. `MIST_LOCAL_MODEL` picks the
model (default `qwen/qwen3.5-4b`), and `MIST_MODEL` puts a Gemini model first in line.

### Maths solver

```sh
cd solver
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/python -I solve.py "Find the general solution of y'' + 9y = sin(3x)."
```

Model-written code runs under `sandbox-exec` with no network access and can only write to `/private/tmp/mist-solver`.
`solver/eval/run.py <model>` runs the sample questions in `solver/eval/items.json`.

## Privacy

- Nothing you select is read until you click the cloud.
- Screenshots are kept in memory only and dropped when the panel closes. Region captures are written to a temp
  file by macOS and deleted immediately.
- `timings.csv` and `errors.log` (created next to the app) record timings, the app name and error text. They never
  record your question or the selected text.
- Questions you send go to the provider you chose (Gemini, Exa, or your local model). Gemini's free tier may use
  requests to improve Google's products.

## Layout

```
app/Sources/   the macOS app (Swift, AppKit)
solver/        verified maths solver (Python, SymPy)
probes/        small experiments used while building: text-capture probe, local-model benchmark
```
