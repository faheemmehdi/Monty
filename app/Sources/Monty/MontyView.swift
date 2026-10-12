import SwiftUI

/// What Monty is doing. Each app state maps to one of these.
enum MontyMood: Equatable {
    case awake      // idle: breathing, blinking, an ear flick now and then
    case listening  // nods along, ears twitch to the voice, mouth moves with it, sound waves
    case nibbling   // processing: munches a piece of cheese
    case party      // done: jumps for joy, confetti
    case happy      // copied: a small happy hop
    case confused   // did not hear anything, or an error: shakes his head, "?"
    case wink       // the language was switched
    case sleeping
}

/// Monty the mouse, square variant, drawn from the Figma design
/// (file O5pyjTNzHrCUD6PHPXoOHu, page "Monty Mascot"). Drawing units are 0...200,
/// scaled to `size`, so the numbers below match the Figma layers.
///
/// Every movement is a function of `time` (seconds since the mood started), so the
/// view is driven by a TimelineView and never needs its own animation state.
struct MontyView: View {
    var mood: MontyMood
    var size: CGFloat
    /// Seconds since this mood started.
    var time: Double = 0
    /// Voice level from 0 to 1, used while listening.
    var level: CGFloat = 0

    private static let body = Color(red: 1, green: 0.851, blue: 0.749)        // #FFD9BF
    private static let innerEar = Color(red: 1, green: 0.616, blue: 0.706)    // #FF9DB4
    private static let nose = Color(red: 1, green: 0.478, blue: 0.604)        // #FF7A9A
    private static let cheek = Color(red: 1, green: 0.702, blue: 0.769)       // #FFB3C4
    private static let ink = Color(red: 0.106, green: 0.106, blue: 0.122)     // #1B1B1F
    private static let cheese = Color(red: 1, green: 0.788, blue: 0.235)      // #FFC93C
    private static let cheeseHole = Color(red: 0.961, green: 0.616, blue: 0.137)
    private static let confetti: [Color] = [
        Color(red: 1, green: 0.616, blue: 0.706), Color(red: 1, green: 0.788, blue: 0.235),
        Color(red: 0.4, green: 0.86, blue: 0.62), Color(red: 0.45, green: 0.7, blue: 1),
    ]

    var body: some View {
        let s = size / 200
        // At notch size the Figma line widths would be a fraction of a point; keep them visible.
        let line = max(5, 1.5 / s)
        let thin = max(3.5, 1.1 / s)
        let m = motion

        ZStack(alignment: .topLeading) {
            if mood == .party { confettiBurst }
            ear(x: 14, innerX: 30).rotationEffect(.degrees(m.leftEar), anchor: UnitPoint(x: 0.42, y: 0.41))
            ear(x: 116, innerX: 132).rotationEffect(.degrees(m.rightEar), anchor: UnitPoint(x: 0.58, y: 0.41))
            box(22, 52, 156, 132, 46, Self.body)
            box(40, 130, 24, 13, 6.5, Self.cheek.opacity(m.cheekOpacity))
                .scaleEffect(m.cheekPuff, anchor: UnitPoint(x: 0.26, y: 0.68))
            box(136, 130, 24, 13, 6.5, Self.cheek.opacity(m.cheekOpacity))
                .scaleEffect(m.cheekPuff, anchor: UnitPoint(x: 0.74, y: 0.68))
            eyes(line: line, blink: m.blink, look: m.look)
            box(91, 124, 18, 12, 6, Self.nose)
            mouth(line: thin)
            if mood == .nibbling { cheeseInPaws }
            // Beside the notch the voice meter already shows the sound; waves only on a bigger Monty.
            if mood == .listening, size >= 40 { soundWaves(line: line) }
            if mood == .confused { questionMark }
        }
        .frame(width: 200, height: 200)
        .scaleEffect(x: m.stretchX, y: m.stretchY, anchor: .bottom)
        .rotationEffect(.degrees(m.tilt), anchor: .bottom)
        .offset(y: m.lift)
        .scaleEffect(s)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    // MARK: Motion

    private struct Motion {
        var leftEar = 0.0, rightEar = 0.0, tilt = 0.0
        var lift: CGFloat = 0, stretchX: CGFloat = 1, stretchY: CGFloat = 1
        var cheekPuff: CGFloat = 1, cheekOpacity = 0.8
        var blink = false
        var look = CGSize.zero
    }

    private var motion: Motion {
        let t = time
        var m = Motion()
        // Gentle breathing in every awake mood.
        let breathe = CGFloat(sin(t * 2.2)) * 0.012
        m.stretchY = 1 + breathe
        // A quick blink every 3.4 seconds.
        m.blink = t.truncatingRemainder(dividingBy: 3.4) > 3.27

        switch mood {
        case .awake:
            // An ear flick every 5 seconds.
            let flick = t.truncatingRemainder(dividingBy: 5) < 0.35 ? sin(t * 40) * 9 : 0
            m.leftEar = -flick
        case .listening:
            let l = Double(level)
            m.tilt = sin(t * 5.5) * 3 + l * 3                // nodding along
            m.leftEar = -(l * 14 + sin(t * 9) * 3)
            m.rightEar = 9 + l * 10 + sin(t * 9 + 1) * 3     // leaning toward the sound
            m.stretchY = 1 + breathe + level * 0.05
        case .nibbling:
            let chew = abs(sin(t * 9))
            m.tilt = sin(t * 2.5) * 3
            m.cheekPuff = 1 + CGFloat(chew) * 0.22
            m.cheekOpacity = 0.95
            m.look = CGSize(width: 0, height: 5)              // eyes on the cheese
            m.lift = CGFloat(-chew * 3)
            m.blink = false
        case .party:
            // One big jump, a squash when he lands, then a happy bounce.
            if t < 0.45 {
                let p = t / 0.45
                m.lift = CGFloat(-sin(p * .pi) * 34)
                m.stretchY = 1 + CGFloat(sin(p * .pi)) * 0.06
                m.stretchX = 1 - CGFloat(sin(p * .pi)) * 0.04
            } else if t < 0.62 {
                let p = (t - 0.45) / 0.17
                m.stretchY = 1 - CGFloat(sin(p * .pi)) * 0.12
                m.stretchX = 1 + CGFloat(sin(p * .pi)) * 0.08
            } else {
                m.lift = CGFloat(-abs(sin((t - 0.62) * 7)) * 6 * max(0, 1 - (t - 0.62)))
            }
            m.leftEar = -10 * sin(min(t, 0.45) / 0.45 * .pi)
            m.rightEar = 10 * sin(min(t, 0.45) / 0.45 * .pi)
            m.cheekOpacity = 1
        case .happy:
            m.lift = CGFloat(-abs(sin(t * 8)) * 10 * max(0, 1 - t / 0.8))
            m.cheekOpacity = 1
        case .confused:
            m.tilt = sin(t * 18) * 8 * max(0, 1 - t / 0.9)    // shaking his head
            m.leftEar = -6; m.rightEar = 6
        case .wink:
            m.tilt = -7 * min(1, t / 0.15) * max(0, 1 - max(0, t - 0.7) / 0.3)
        case .sleeping:
            m.blink = false
        }
        return m
    }

    // MARK: Parts

    private func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat, _ color: Color) -> some View {
        RoundedRectangle(cornerRadius: r, style: .continuous)
            .fill(color)
            .frame(width: w, height: h)
            .offset(x: x, y: y)
    }

    private func ear(x: CGFloat, innerX: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            box(x, 12, 70, 70, 22, Self.body)
            box(innerX, 28, 38, 38, 12, Self.innerEar)
        }
        .frame(width: 200, height: 200, alignment: .topLeading)
    }

    @ViewBuilder private func eyes(line: CGFloat, blink: Bool, look: CGSize) -> some View {
        switch mood {
        case .sleeping:
            arc(73, 108, down: true, line: line); arc(127, 108, down: true, line: line)
        case .party, .happy:
            arc(73, 112, down: false, line: line); arc(127, 112, down: false, line: line)
        case .confused:
            flat(73, 109, line: line); flat(127, 109, line: line)
        case .wink:
            openEye(73, blink: false, look: .zero)
            if time < 0.75 { arc(127, 112, down: false, line: line) } else { openEye(127, blink: false, look: .zero) }
        case .awake, .listening, .nibbling:
            openEye(73, blink: blink, look: look); openEye(127, blink: blink, look: look)
        }
    }

    private func openEye(_ cx: CGFloat, blink: Bool, look: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            box(cx - 8, 96, 16, 24, 8, Self.ink)
            box(cx - 4, 100, 6, 6, 3, .white).opacity(blink ? 0 : 1)
        }
        .frame(width: 200, height: 200, alignment: .topLeading)
        .offset(look)
        // A blink squashes the eye flat around its center.
        .scaleEffect(x: 1, y: blink ? 0.12 : 1, anchor: UnitPoint(x: cx / 200, y: 108 / 200))
    }

    /// A curved closed eye: `down` is a sleepy smile shape, otherwise a happy arch.
    private func arc(_ cx: CGFloat, _ y: CGFloat, down: Bool, line: CGFloat) -> some View {
        stroke(line: line) { p in
            p.move(to: CGPoint(x: cx - 13, y: y))
            p.addQuadCurve(to: CGPoint(x: cx + 13, y: y), control: CGPoint(x: cx, y: y + (down ? 10 : -12)))
        }
    }

    private func flat(_ cx: CGFloat, _ y: CGFloat, line: CGFloat) -> some View {
        stroke(line: line) { p in
            p.move(to: CGPoint(x: cx - 11, y: y))
            p.addLine(to: CGPoint(x: cx + 11, y: y))
        }
    }

    @ViewBuilder private func mouth(line: CGFloat) -> some View {
        switch mood {
        case .listening:
            // Opens and closes with the voice, so Monty looks like he is repeating you.
            Ellipse()
                .fill(Self.ink)
                .frame(width: 12, height: 4 + level * 16)
                .offset(x: 94, y: 140)
        case .party, .happy:
            stroke(line: line) { p in
                p.move(to: CGPoint(x: 86, y: 138))
                p.addQuadCurve(to: CGPoint(x: 114, y: 138), control: CGPoint(x: 100, y: 156))
            }
        case .confused:
            stroke(line: line) { p in
                p.move(to: CGPoint(x: 88, y: 144))
                p.addQuadCurve(to: CGPoint(x: 100, y: 144), control: CGPoint(x: 94, y: 138))
                p.addQuadCurve(to: CGPoint(x: 112, y: 144), control: CGPoint(x: 106, y: 150))
            }
        case .nibbling:
            // Chomping: the mouth opens and closes behind the cheese.
            Ellipse()
                .fill(Self.ink)
                .frame(width: 14, height: 3 + abs(sin(time * 9)) * 8)
                .offset(x: 93, y: 139)
        default:
            stroke(line: line) { p in
                p.move(to: CGPoint(x: 88, y: 140))
                p.addQuadCurve(to: CGPoint(x: 100, y: 140), control: CGPoint(x: 94, y: 147))
                p.addQuadCurve(to: CGPoint(x: 112, y: 140), control: CGPoint(x: 106, y: 147))
            }
        }
    }

    /// A wedge of cheese held up to the mouth, bobbing with each bite, with crumbs falling.
    private var cheeseInPaws: some View {
        let bite = CGFloat(abs(sin(time * 9))) * 4
        return ZStack(alignment: .topLeading) {
            Path { p in
                p.move(to: CGPoint(x: 78, y: 176))
                p.addLine(to: CGPoint(x: 124, y: 176))
                p.addLine(to: CGPoint(x: 124, y: 150))
                p.closeSubpath()
            }
            .fill(Self.cheese)
            .frame(width: 200, height: 200)
            Circle().fill(Self.cheeseHole).frame(width: 8, height: 8).offset(x: 108, y: 162)
            Circle().fill(Self.cheeseHole).frame(width: 6, height: 6).offset(x: 96, y: 168)
            // Crumbs fall every half second.
            ForEach(0..<2) { i in
                let phase = (time * 2 + Double(i) * 0.5).truncatingRemainder(dividingBy: 1)
                Circle()
                    .fill(Self.cheese)
                    .frame(width: 6, height: 6)
                    .offset(x: 86 + CGFloat(i) * 26, y: 178 + CGFloat(phase) * 26)
                    .opacity(1 - phase)
            }
        }
        .frame(width: 200, height: 200, alignment: .topLeading)
        .offset(y: -bite)
    }

    private func soundWaves(line: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<3) { i in
                // Each wave moves outward and fades, louder voice makes them brighter.
                let phase = (time * 1.6 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                let x = 184 + CGFloat(phase) * 26
                stroke(line: line, color: Self.innerEar) { p in
                    p.move(to: CGPoint(x: x, y: 64))
                    p.addQuadCurve(to: CGPoint(x: x, y: 104), control: CGPoint(x: x + 14, y: 84))
                }
                .opacity((1 - phase) * (0.35 + Double(level) * 0.65))
            }
        }
        .frame(width: 200, height: 200, alignment: .topLeading)
    }

    private var questionMark: some View {
        Text("?")
            .font(.system(size: 64, weight: .heavy, design: .rounded))
            .foregroundStyle(Self.innerEar)
            .offset(x: 160, y: -6 + CGFloat(sin(time * 6)) * 4)
            .opacity(min(1, time / 0.2))
    }

    private var confettiBurst: some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<10) { i in
                let angle = Double(i) / 10 * 2 * .pi + 0.3
                let p = min(1, time / 1.0)
                let distance = CGFloat(p) * 170
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Self.confetti[i % Self.confetti.count])
                    .frame(width: 24, height: 24)
                    .rotationEffect(.degrees(Double(i) * 37 + p * 360))
                    .offset(x: 93 + cos(angle) * distance, y: 100 + sin(angle) * distance + CGFloat(p * p) * 40)
                    .opacity(1 - p)
            }
        }
        .frame(width: 200, height: 200, alignment: .topLeading)
    }

    private func stroke(line: CGFloat, color: Color = MontyView.ink, _ build: @escaping (inout Path) -> Void) -> some View {
        Path { p in build(&p) }
            .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
            .frame(width: 200, height: 200)
    }
}

/// Monty animated: redraws at 30 frames a second while on screen.
struct AnimatedMonty: View {
    var mood: MontyMood
    var size: CGFloat
    /// When the current mood started, so its animation plays from the beginning.
    var since: Date
    var level: CGFloat = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            MontyView(mood: mood, size: size, time: max(0, context.date.timeIntervalSince(since)), level: level)
        }
        .frame(width: size, height: size)
    }
}
