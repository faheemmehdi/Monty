<p align="center">
  <img src="docs/icon.png" width="128" alt="Monty">
</p>

<h1 align="center">Monty</h1>

<p align="center">
  A tiny mouse who lives in your MacBook's notch and types what you say.<br>
  Offline voice dictation in 20+ languages, powered by Gemma 4.
</p>

---

> **Work in progress.** Monty works day to day, but it is not packaged for easy install yet.
> Ideas and feedback are very welcome in Issues.

## What it does

Hold **fn**, speak, let go. Monty writes your words wherever the cursor is, in any app.
Speak in one language and get the text in another: talk in Urdu and get English, or talk
in English and get Roman Urdu, Spanish, Arabic, and more.

- 🎙 **Hold fn** to dictate into any app
- 🔒 **Tap fn twice** for hands-free, fn again to finish, Esc to cancel
- 🌐 **fn + ⇧** switches between your two languages (A and B)
- 📋 No text field selected? The text goes to your clipboard
- 📖 Custom dictionary for names and words, with automatic fixes for wrong spellings
- 📝 **Meeting notes**: when a Zoom, Google Meet, Teams or FaceTime call starts, Monty asks on the notch whether to take notes, in the language you pick. Your voice and the other people are kept apart, and you get a title, summary, key points, decisions and action items, saved as Markdown in `Documents/Monty Data/Meeting Notes`
- 🐭 Monty lives in the notch: he listens, munches cheese while he thinks, and throws confetti when he is done
- 🔐 Everything runs on your Mac. No account, no cloud, nothing leaves the computer

## Languages

English, Roman Urdu, Urdu (اردو), Hinglish, Arabic, Czech, Danish, Dutch, French, German,
Hindi, Indonesian, Japanese, Korean, Portuguese, Russian, Spanish, Swedish, Thai, Turkish
and Vietnamese, plus "As Spoken" (clean up without translating).

Every language in the list passed three checks: Monty heard a spoken sentence correctly,
translated it to English without losing a detail, and wrote English speech correctly in
that language. More languages will be added as they pass. Ask for yours in Issues.

## Requirements

- A Mac with Apple silicon and macOS 14.2 or later (the notch is optional)
- [Ollama](https://ollama.com) with the Gemma 4 model: `ollama pull gemma4:e2b` (about 4.6 GB)

The plan is to bundle the model runtime inside the app, so it works right after download.

## Build and run

```bash
cd app
./setup-signing.sh   # once: a local signing certificate, so permissions survive rebuilds
./build.sh run       # builds, installs into /Applications and starts Monty
```

On first launch, allow Monty under **System Settings › Privacy & Security** for
**Accessibility** (to listen for fn and type) and **Microphone**. For meeting notes, also
allow **System Audio Recording** (to hear the other people in the call). In **System Settings ›
Keyboard**, set **Press 🌐 key to** to **Do Nothing**, so fn does not open the emoji picker.

Open Monty from Launchpad or Spotlight for its settings: languages, microphone, model
memory and the dictionary.

## Where Monty keeps things

Everything is in one folder, **Documents › Monty Data**:

- `Meeting Notes/` one Markdown file per meeting
- `History.json` recent dictations and the totals shown in the window
- `Dictionary.txt` your custom dictionary
- `Logs/` a debug log and the latest recording

Settings live where macOS keeps app settings, and the Gemma model stays with Ollama.
Nothing is sent anywhere.

## How it works

1. While fn is held, Monty records from the microphone.
2. Gemma 4 (e2b) listens to the audio and writes down what was said.
3. Gemma then rewrites it in the chosen language, fixes punctuation, removes "umm",
   and writes numbers as digits.
4. Monty pastes the result into the focused text field and puts your clipboard back.

Native Swift and SwiftUI, no Electron. The app itself uses about 30 MB of memory; Gemma
uses 2 to 4 GB while loaded and can be unloaded after a few minutes.

## Project layout

- `app/` the Mac app (Swift Package, built with `build.sh`, no Xcode needed)
- `bench/` scripts used to compare speech models on recorded samples

## License

MIT, see [LICENSE](LICENSE).
