#!/usr/bin/env python3
"""Phase 0 model benchmark: compare Whisper + local LLMs on your own voice.

Commands:
  python3 bench.py record <name>   Record a sample from the mic (press Enter to stop).
  python3 bench.py run             Transcribe every sample, run each Ollama model in
                                   English and Roman Urdu modes, write results/report.html.

Uses only the Python standard library, plus ffmpeg, whisper-cli and Ollama.
"""

import argparse
import base64
import html
import json
import re
import subprocess
import sys
import time
import urllib.request
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SAMPLES = ROOT / "samples"
MODELS = ROOT / "models"
RESULTS = ROOT / "results"
OLLAMA = "http://localhost:11434"

PROMPTS = {
    "english": (
        "You are a dictation assistant. The user message is a raw speech transcript. "
        "It may be in Urdu (written in Urdu script or in Hindi Devanagari script), in "
        "English, or a mix of both. Rewrite it as natural, fluent English with correct "
        "punctuation, keeping the original meaning. Output only the final text: no "
        "explanations, no quotes, no labels."
    ),
    "roman": (
        "You are a dictation assistant. The user message is a raw speech transcript. "
        "It may be in Urdu (written in Urdu script or in Hindi Devanagari script), in "
        "English, or a mix of both. Rewrite it in Roman Urdu: Urdu written with the English "
        "alphabet, the way people in Pakistan type casually on WhatsApp, with the usual "
        "phonetic spellings. Never use Urdu script or Hindi script. The output must ALWAYS "
        "be Roman Urdu, even when the input is entirely in English: then translate it into "
        "Urdu and write that Urdu in English letters. Common English words people normally "
        "use (meeting, laptop, office) stay in English. Output only the final text: no "
        "explanations, no quotes, no labels."
    ),
}

TRANSCRIBE_PROMPT = (
    "Transcribe this audio exactly as spoken. The speaker may use Urdu, English, or a "
    "mix. Write Urdu in Urdu script and English words in English. Output only the "
    "transcript: no explanations, no labels."
)


def record(name: str, device: str) -> None:
    SAMPLES.mkdir(exist_ok=True)
    out = SAMPLES / f"{name}.wav"
    cmd = [
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        "-f", "avfoundation", "-i", f":{device}",
        "-ar", "16000", "-ac", "1", str(out),
    ]
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE)
    input("Recording... speak now, then press Enter to stop. ")
    # ffmpeg stops cleanly and finalizes the file when it receives 'q'.
    proc.communicate(b"q")
    if proc.returncode != 0 or not out.exists():
        sys.exit("Recording failed. Check that the terminal has microphone permission.")
    print(f"Saved {out.relative_to(ROOT)}")


def find_whisper_model() -> Path:
    found = sorted(MODELS.glob("ggml-*.bin"), key=lambda p: p.stat().st_size, reverse=True)
    if not found:
        sys.exit("No Whisper model found. Run ./download_models.sh first.")
    return found[0]  # the largest model is the most accurate one available


def transcribe(model: Path, wav: Path, lang: str) -> tuple[str, float]:
    start = time.time()
    res = subprocess.run(
        ["whisper-cli", "-m", str(model), "-f", str(wav), "-l", lang, "-nt", "-np"],
        capture_output=True, text=True,
    )
    if res.returncode != 0:
        sys.exit(f"whisper-cli failed:\n{res.stderr}")
    return " ".join(res.stdout.split()), time.time() - start


def ollama_models() -> list[str]:
    with urllib.request.urlopen(f"{OLLAMA}/api/tags") as r:
        return sorted(m["name"] for m in json.load(r)["models"])


def load_vocab() -> list[tuple[str, list[str]]]:
    """Read vocab.txt: 'Word' or 'Word = wrong1, wrong2' per line."""
    path = ROOT / "vocab.txt"
    if not path.exists():
        return []
    entries = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        word, _, wrong = line.partition("=")
        entries.append((word.strip(), [w.strip() for w in wrong.split(",") if w.strip()]))
    return entries


def vocab_hint() -> str:
    words = [w for w, _ in load_vocab()]
    if not words:
        return ""
    return (
        " These names and words may appear. Whenever one appears, or something that "
        "sounds like it, spell it exactly like this: " + ", ".join(words) + "."
    )


def apply_replacements(text: str) -> str:
    """Fix known wrong spellings. The model does not always follow the hint, this always works."""
    for word, wrong in load_vocab():
        for w in sorted(wrong, key=len, reverse=True):  # longer phrases first
            text = re.sub(rf"(?<!\w){re.escape(w)}(?!\w)", word, text, flags=re.I)
    return text


def transcribe_audio_llm(model: str, wav: Path) -> tuple[str, float]:
    """Let an audio-capable Ollama model (e.g. Gemma 4) listen to the file directly."""
    audio = base64.b64encode(wav.read_bytes()).decode()
    return ask(model, None, TRANSCRIBE_PROMPT + vocab_hint(), audio)


def ask(model: str, system: str | None, text: str, audio: str | None = None) -> tuple[str, float]:
    user = {"role": "user", "content": text}
    if audio:
        user["images"] = [audio]  # Ollama takes audio through the same field as images
    messages = ([{"role": "system", "content": system}] if system else []) + [user]
    body = {
        "model": model,
        "messages": messages,
        "stream": False,
        "think": False,  # Qwen3 would otherwise spend seconds "thinking" first
        "options": {"temperature": 0},
    }
    req = urllib.request.Request(
        f"{OLLAMA}/api/chat", data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    start = time.time()
    try:
        with urllib.request.urlopen(req, timeout=300) as r:
            answer = json.load(r)["message"]["content"]
    except urllib.error.HTTPError as e:
        # Models without thinking support may reject the "think" field; retry without it.
        if body.pop("think", None) is None:
            raise
        req.data = json.dumps(body).encode()
        with urllib.request.urlopen(req, timeout=300) as r:
            answer = json.load(r)["message"]["content"]
    answer = re.sub(r"<think>.*?</think>", "", answer, flags=re.S).strip()
    return answer, time.time() - start


def run(asr: str, lang: str, only: list[str] | None) -> None:
    wavs = sorted(SAMPLES.glob("*.wav"))
    if not wavs:
        sys.exit("No samples yet. Record one with: python3 bench.py record <name>")
    try:
        installed = ollama_models()
    except OSError:
        sys.exit("Ollama is not running. Start the Ollama app or run: ollama serve")

    if asr == "whisper":
        wmodel = find_whisper_model()
        asr_name = wmodel.name
        llms = only or installed
    else:
        if asr not in installed:
            sys.exit(f"{asr} is not installed. Run: ollama pull {asr}")
        asr_name = asr
        llms = only or [asr]  # one model does both listening and rewriting

    print(f"Listening: {asr_name}   Rewriting: {', '.join(llms)}\n")
    rows = []
    for wav in wavs:
        if asr == "whisper":
            text, t = transcribe(wmodel, wav, lang)
        else:
            text, t = transcribe_audio_llm(asr, wav)
        print(f"== {wav.name}  (listening {t:.1f}s)\n   {text}")
        row = {"sample": wav.name, "transcript": text, "whisper_s": t, "outputs": {}}
        for llm in llms:
            for mode, system in PROMPTS.items():
                out, t = ask(llm, system + vocab_hint(), text)
                out = apply_replacements(out)
                row["outputs"][(llm, mode)] = (out, t)
                print(f"   [{llm} / {mode} {t:.1f}s] {out}")
        print()
        rows.append(row)

    RESULTS.mkdir(exist_ok=True)
    report = RESULTS / "report.html"
    report.write_text(render(rows, asr_name, llms), encoding="utf-8")
    print(f"Report: {report}")
    subprocess.run(["open", str(report)])


def render(rows: list[dict], wmodel: str, llms: list[str]) -> str:
    e = html.escape
    head = "".join(f"<th>{e(m)}</th>" for m in llms)
    body = []
    for r in rows:
        body.append(
            f'<tr class="sample"><td colspan="{len(llms) + 1}"><b>{e(r["sample"])}</b> '
            f'<span class="t">listening {r["whisper_s"]:.1f}s</span>'
            f'<div class="tr">{e(r["transcript"])}</div></td></tr>'
        )
        for mode, label in (("english", "Fn + E → English"), ("roman", "Fn + U → Roman Urdu")):
            cells = "".join(
                f'<td>{e(r["outputs"][(m, mode)][0])}'
                f'<span class="t">{r["outputs"][(m, mode)][1]:.1f}s</span></td>'
                for m in llms
            )
            body.append(f"<tr><th class='mode'>{label}</th>{cells}</tr>")
    return f"""<!doctype html><meta charset="utf-8"><title>Model Benchmark</title>
<style>
:root {{ --bg:#fafaf9; --fg:#1c1917; --muted:#78716c; --line:#e7e5e4; --band:#f5f5f4; }}
@media (prefers-color-scheme: dark) {{
  :root {{ --bg:#1c1917; --fg:#f5f5f4; --muted:#a8a29e; --line:#44403c; --band:#292524; }} }}
body {{ background:var(--bg); color:var(--fg); font:15px/1.5 -apple-system, system-ui, sans-serif;
  margin:0; padding:24px 16px; }}
h1 {{ font-size:20px; margin:0 0 4px; }} p {{ color:var(--muted); margin:0 0 20px; }}
table {{ border-collapse:collapse; width:100%; }}
th, td {{ border:1px solid var(--line); padding:10px; text-align:left; vertical-align:top; }}
tr.sample td {{ background:var(--band); }}
.tr {{ font-size:17px; margin-top:6px; }}
.mode {{ white-space:nowrap; width:1%; font-weight:600; }}
.t {{ display:block; color:var(--muted); font-size:12px; margin-top:4px; }}
</style>
<h1>Model Benchmark</h1>
<p>Listening model: {e(wmodel)} · {datetime.now():%Y-%m-%d %H:%M}</p>
<table><tr><th></th>{head}</tr>{''.join(body)}</table>"""


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    rec = sub.add_parser("record", help="record a sample from the microphone")
    rec.add_argument("name", help="file name for the sample, e.g. urdu1")
    rec.add_argument("--device", default="default",
                     help="audio input: 'default' follows System Settings > Sound > Input, "
                          "or an index from: ffmpeg -f avfoundation -list_devices true -i ''")
    r = sub.add_parser("run", help="run the benchmark on all samples")
    r.add_argument("--asr", default="gemma4:e2b",
                   help="who listens to the audio: an audio-capable Ollama model "
                        "(default gemma4:e2b) or 'whisper'")
    r.add_argument("--lang", default="auto", help="Whisper language: auto, ur, hi, en")
    r.add_argument("--models", nargs="+", help="only these Ollama models (default: all installed)")
    args = ap.parse_args()

    if args.cmd == "record":
        record(args.name, args.device)
    else:
        run(args.asr, args.lang, args.models)


if __name__ == "__main__":
    main()
