# Phase 0: Model Benchmark

Tests how well Gemma 4 (or Whisper + a local LLM) works on your own voice before
building the Mac app. Everything runs locally and offline.

## Requirements

- `ffmpeg` (`brew install ffmpeg`)
- Ollama running, with `gemma4:e2b` pulled (`ollama pull gemma4:e2b`)
- Optional, only to compare against Whisper: `brew install whisper-cpp` and
  `./download_models.sh`

## Steps

```bash
cd bench
python3 bench.py record urdu1       # speak, press Enter to stop
python3 bench.py record english1
python3 bench.py record mix1
python3 bench.py run                # opens results/report.html
```

By default Gemma 4 listens to the audio itself, then rewrites the transcript into
English and Roman Urdu (two steps were more accurate than one in early tests).

Useful options:

- `python3 bench.py run --asr whisper` lets Whisper listen instead of Gemma 4
- `python3 bench.py run --asr whisper --lang ur` forces Urdu in Whisper
- `python3 bench.py run --models gemma3:4b` rewrites with another model
- `python3 bench.py record name --device 1` records from a specific mic (default: the input selected in System Settings > Sound)

The first time you record, macOS asks for microphone permission for the terminal.

## Suggested samples

Record 10 to 20 short samples (5 to 15 seconds each):

- Pure Urdu, everyday sentences
- Pure English
- Mixed Urdu and English, the way you normally talk
- Names, numbers, dates and technical words you use often
