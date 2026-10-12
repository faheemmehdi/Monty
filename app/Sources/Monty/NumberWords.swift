import Foundation

/// Turns English number words into digits: "thirty-nine" is 39, "two thousand five
/// hundred" is 2500. The model is asked to do this, but in Roman Urdu it often keeps the
/// words. Numbers below ten stay words ("one of them"), the way people write them.
enum NumberWords {
    private static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    private static let scales: [String: Int] = ["hundred": 100, "thousand": 1_000, "million": 1_000_000]

    static func digits(in text: String) -> String {
        // Words, hyphens and spaces; a run of number words becomes one number.
        let pattern = "\\b(?:(?:zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|thousand|million|and)(?:[ -]+|\\b))+"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return text }
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let run = String(result[range])
            let trailing = String(run.reversed().prefix { $0 == " " || $0 == "-" }.reversed())
            guard let value = parse(run), value >= 10 else { continue }
            result.replaceSubrange(range, with: "\(value)" + trailing)
        }
        return result
    }

    private static func parse(_ run: String) -> Int? {
        let words = run.lowercased().split { $0 == " " || $0 == "-" }.map(String.init)
        guard words.first != "and", words.last != "and" else { return nil }
        var total = 0, current = 0, sawNumber = false
        for word in words {
            if word == "and" { continue }
            if let n = units[word] ?? tens[word] {
                current += n
                sawNumber = true
            } else if let scale = scales[word] {
                guard sawNumber else { return nil }
                if scale == 100 {
                    current *= 100
                } else {
                    total += max(current, 1) * scale
                    current = 0
                }
            }
        }
        return sawNumber ? total + current : nil
    }
}
