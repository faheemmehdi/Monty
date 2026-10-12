#!/bin/zsh
# Downloads the Whisper model(s) used by bench.py into bench/models.
# Usage:
#   ./download_models.sh          -> large-v3-turbo, 5-bit quantized (~550 MB, recommended)
#   ./download_models.sh tiny     -> tiny model (~30 MB, only for checking the setup works)
set -e
cd "$(dirname "$0")"
mkdir -p models

base="https://huggingface.co/ggerganov/whisper.cpp/resolve/main"
case "${1:-turbo}" in
  turbo) name="ggml-large-v3-turbo-q5_0.bin" ;;
  tiny)  name="ggml-tiny-q5_1.bin" ;;
  *) echo "Unknown model: $1 (use: turbo | tiny)"; exit 1 ;;
esac

if [[ -f "models/$name" ]]; then
  echo "Already downloaded: models/$name"
else
  # -C - resumes a partial download if it was interrupted.
  curl -L -C - --fail -o "models/$name" "$base/$name"
  echo "Saved: models/$name"
fi
