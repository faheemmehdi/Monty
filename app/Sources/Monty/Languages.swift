import Foundation

/// A language Monty can type in. The user keeps two of them in slots A and B and
/// switches with Fn + Shift. Monty understands speech in any language; this is only
/// the language the text comes out in.
struct OutputLanguage: Hashable, Identifiable {
    enum Style: Hashable {
        /// No translation: clean up the words in whatever language they were spoken.
        case asSpoken
        /// Translate into this language, named the way the model should see it.
        case translate(String)
        /// A hand-written instruction, for languages with special rules.
        case custom(String)
    }

    let id: String
    let label: String
    /// Two or three letters for the notch.
    let shortLabel: String
    /// Checked against recorded speech. The others work, but have not been verified yet.
    let tested: Bool
    let style: Style

    var menuTitle: String { tested ? label : "\(label)  (experimental)" }

    /// How a notes prompt should name this language.
    var notesLanguageName: String {
        switch style {
        case .asSpoken: return "the main language spoken in the meeting"
        case .translate(let name): return name
        case .custom:
            switch id {
            case "roman": return "Roman Urdu (Urdu written with Latin letters, as typed on WhatsApp)"
            case "hinglish": return "Hinglish (Hindi written with Latin letters)"
            case "urdu": return "Urdu, in Urdu script"
            default: return label
            }
        }
    }

    /// What the rewrite step should do with the transcript.
    var rewriteInstruction: String {
        switch style {
        case .asSpoken:
            return "Rewrite it as clean text in the same language it was spoken in, written in that "
                + "language's usual script, with correct punctuation. Do not translate. If two "
                + "languages are mixed, keep the mix as spoken."
        case .translate(let name):
            return "The output must ALWAYS be in \(name). Rewrite it in natural, fluent \(name), in the usual \(name) script, with correct "
                + "punctuation. If it was spoken in another language, translate the meaning, not word "
                + "by word. Keep every detail: names, negations, days and times exactly as said."
        case .custom(let text):
            return text
        }
    }

    static func with(id: String) -> OutputLanguage? { all.first { $0.id == id } }

    // MARK: The list

    static let asSpoken = OutputLanguage(
        id: "as-spoken", label: "As Spoken (no translation)", shortLabel: "AUTO", tested: true, style: .asSpoken)

    // The ids "english" and "roman" match what earlier versions saved.
    static let english = OutputLanguage(
        id: "english", label: "English", shortLabel: "EN", tested: true,
        style: .custom(
            "The output must ALWAYS be in English: if the transcript is in another language, translate "
            + "all of it, every word. Rewrite it as natural, fluent English with correct punctuation. Keep every detail of the "
            + "meaning: never drop words like tomorrow, not, or a day of the week. Translate the meaning, "
            + "not word by word: a casual Urdu question that literally asks 'what is the work?' means "
            + "'What do you need?'. Keep days and times exactly as said: Urdu and Hindi use one word for "
            + "both tomorrow and yesterday, so decide from context, and their word for the day after "
            + "tomorrow means the day after tomorrow, never a weekday."))

    static let romanUrdu = OutputLanguage(
        id: "roman", label: "Roman Urdu", shortLabel: "UR", tested: true,
        style: .custom(
            // Worded like the other translated languages. The older wording ("give only that one
            // version; never add a second version", "an English sentence must never come back
            // unchanged") made the model write the text twice in about half of all tests.
            // "Entirely" and the last sentence matter: without them, speech that starts with
            // English words ("I think ...") came back translated into English.
            "The output must ALWAYS be in Urdu, written in English letters (Roman Urdu). If it was "
            + "spoken entirely in another language, such as English, translate the meaning into Urdu, "
            + "not word by word. Roman Urdu is Urdu written with the English alphabet, the way people "
            + "in Pakistan type casually on WhatsApp, with the usual phonetic spellings. Never use Urdu "
            + "script or Hindi script. Common English words people normally use (meeting, laptop, "
            + "office, file) stay in English. Speech that mixes Urdu and English is Urdu: keep its "
            + "English words in English and write the rest in Roman Urdu, never as English."))

    static let urdu = OutputLanguage(
        id: "urdu", label: "Urdu (اردو)", shortLabel: "اردو", tested: true,
        style: .custom(
            "Rewrite it in Urdu written in Urdu script (the Nastaliq / Perso-Arabic alphabet), with "
            + "correct punctuation. If it was spoken in Roman Urdu, Hindi script or another language, "
            + "write it in Urdu script. Keep names, days and times exactly as said."))

    static let hinglish = OutputLanguage(
        id: "hinglish", label: "Hinglish (Roman Hindi)", shortLabel: "HG", tested: true,
        style: .custom(
            // Worded like Roman Urdu above, for the same reason.
            "The output must ALWAYS be in Hindi, written in English letters (Hinglish). If it was "
            + "spoken entirely in another language, such as English, translate the meaning into "
            + "Hindi, not word by word. Hinglish is Hindi written with the English alphabet, the way "
            + "people in India type casually on WhatsApp, with the usual phonetic spellings. Never use "
            + "Devanagari or Urdu script. Common English words people normally use (meeting, laptop, "
            + "office, file) stay in English. Speech that mixes Hindi and English is Hindi: keep its "
            + "English words in English and write the rest in Hinglish, never as English."))

    private static func plain(_ id: String, _ label: String, _ short: String, tested: Bool, model: String? = nil) -> OutputLanguage {
        OutputLanguage(id: id, label: label, shortLabel: short, tested: tested, style: .translate(model ?? label))
    }

    /// Order of the menu: the special ones first, then the rest by name.
    ///
    /// Only languages that passed testing are listed: Monty heard a recorded sentence
    /// correctly, translated it to English without losing a detail, and wrote English
    /// speech correctly in that language (2026-10-12, macOS voices). Failed for now and
    /// left out: Bulgarian, Catalan, Croatian, Finnish, Italian, Malay, Norwegian, Polish,
    /// Slovak, Slovenian, Ukrainian, Bengali, Greek, Hebrew, Kannada, Kazakh, Lithuanian,
    /// Romanian, Tamil, Telugu, Chinese. Add more as they are tested.
    static let all: [OutputLanguage] = [asSpoken, english, romanUrdu, urdu, hinglish] + [
        plain("ar", "Arabic", "AR", tested: true),
        plain("cs", "Czech", "CS", tested: true),
        plain("da", "Danish", "DA", tested: true),
        plain("de", "German", "DE", tested: true),
        plain("es", "Spanish", "ES", tested: true),
        plain("fr", "French", "FR", tested: true),
        plain("hi", "Hindi", "HI", tested: true, model: "Hindi (Devanagari script)"),
        plain("id", "Indonesian", "ID", tested: true),
        plain("ja", "Japanese", "JA", tested: true),
        plain("ko", "Korean", "KO", tested: true),
        plain("nl", "Dutch", "NL", tested: true),
        plain("pt", "Portuguese", "PT", tested: true),
        plain("ru", "Russian", "RU", tested: true),
        plain("sv", "Swedish", "SV", tested: true),
        plain("th", "Thai", "TH", tested: true),
        plain("tr", "Turkish", "TR", tested: true),
        plain("vi", "Vietnamese", "VI", tested: true),
    ].sorted { $0.label < $1.label }
}
