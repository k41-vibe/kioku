import NaturalLanguage
import SwiftUI

/// One reel page laid out natively: the question block (word / reading /
/// example / audio) fills the screen; the answer panel slides up from the
/// bottom following the finger (`progress` 0...1), then stays open.
struct NativeCardPage: View {
    let card: NativeCard
    let memo: String
    let height: CGFloat
    var progress: CGFloat            // 0 = question only, 1 = answer open
    var interactive: Bool = true
    var onPlay: ([Anki_CardRendering_AVTag]) -> Void = { _ in }

    private var answerHeight: CGFloat { height * 0.62 }
    private var questionLift: CGFloat { height * 0.36 }

    var body: some View {
        ZStack(alignment: .top) {
            questionBlock
                .frame(width: nil, height: height)
                .offset(y: -progress * questionLift)
            // The question slides up behind the toolbar when the answer opens, so
            // cover the strip it travels into. Painted over the block rather than
            // masked: a mask also removes hit testing, which fed drags straight to
            // the pager and skipped cards.
            topFade
                .frame(height: height * 0.13)
                .allowsHitTesting(false)
            answerPanel
                .frame(height: answerHeight)
                .offset(y: height - progress * answerHeight)
                .opacity(progress < 0.02 ? 0 : 1)
        }
        .frame(height: height)
        .clipped()
        .contentShape(Rectangle())
    }

    /// Page colour at the top, transparent below, so text sliding up dissolves
    /// before it reaches the toolbar.
    private var topFade: some View {
        LinearGradient(stops: [
            .init(color: Theme.paper, location: 0),
            .init(color: Theme.paper, location: 0.55),
            .init(color: Theme.paper.opacity(0), location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }

    private var questionBlock: some View {
        VStack(spacing: 14) {
            Spacer()
            if !card.reading.isEmpty {
                Text(LineBreak.keepingWords(card.reading)).font(.footnote).foregroundStyle(Theme.gray1)
            }
            HStack(alignment: .center, spacing: 10) {
                Text(card.word)
                    .font(.system(size: card.word.count > 14 ? 30 : 40, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .lineLimit(1)                 // shrink to fit rather than split the word
                    .minimumScaleFactor(0.4)
                if !card.wordAudio.isEmpty && interactive {
                    playButton { onPlay(card.questionAudio) }
                }
            }
            if !card.example.isEmpty {
                VStack(spacing: 8) {
                    Text(LineBreak.keepingWords(card.example))
                        .font(.title3)
                        .foregroundStyle(Theme.ink.opacity(0.9))
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .minimumScaleFactor(0.75)
                        .lineLimit(6)
                    if !card.exampleAudio.isEmpty && interactive {
                        playButton(small: true) { onPlay(card.answerAudio) }
                    }
                }
                .padding(.top, 6)
            }
            Spacer()
            Spacer().frame(height: 40)
        }
        .padding(.leading, 20)
        .padding(.trailing, 96)
        .frame(maxWidth: .infinity)
    }

    private var answerPanel: some View {
        VStack(spacing: 0) {
            Capsule().fill(Theme.gray2).frame(width: 36, height: 4).padding(.top, 8).padding(.bottom, 10)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(card.meaning.enumerated()), id: \.offset) { _, m in
                        Text(LineBreak.keepingWords(m))
                            .font(.title2.weight(.semibold))
                            .lineSpacing(3)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .multilineTextAlignment(.center)
                    }
                    if !card.exampleMeaning.isEmpty {
                        Text(LineBreak.keepingWords(card.exampleMeaning))
                            .font(.body)
                            .foregroundStyle(Theme.ink.opacity(0.85))
                            .lineSpacing(3)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .multilineTextAlignment(.center)
                    }
                    if !card.extras.isEmpty {
                        Divider().padding(.vertical, 2)
                        ForEach(Array(card.extras.enumerated()), id: \.offset) { _, pair in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pair.0).font(.caption2).foregroundStyle(Theme.gray1)
                                Text(LineBreak.keepingWords(pair.1)).font(.footnote).lineSpacing(2)
                            }
                        }
                    }
                    if !memo.isEmpty {
                        Divider().padding(.vertical, 2)
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "note.text").font(.caption).foregroundStyle(Theme.gray1).padding(.top, 2)
                            Text(LineBreak.keepingWords(memo)).font(.footnote)
                        }
                    }
                    Spacer().frame(height: 60)
                }
                .padding(.horizontal, 22)
                .padding(.trailing, 74)
            }
            .scrollDisabled(progress < 0.99)
        }
        .frame(maxWidth: .infinity)
        .background(
            Theme.paper2
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 22, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 22))
                .shadow(color: .black.opacity(0.08), radius: 12, y: -4)
        )
    }

    private func playButton(small: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "speaker.wave.2.fill")
                .font(small ? .footnote : .body)
                .frame(width: small ? 30 : 38, height: small ? 30 : 38)
                .background(Theme.paper2, in: Circle())
                .overlay(Circle().stroke(Theme.gray3))
                .foregroundStyle(Theme.ink)
        }
        .buttonStyle(.plain)
    }
}

/// Japanese has no spaces, so the line breaker may wrap between any two
/// characters and splits words ("健康" became 健 / 康). Glue the characters of
/// each word, and attach hiragana runs (particles, verb endings) to the word
/// before them, so lines break only between phrases. Text without Japanese is
/// returned unchanged.
enum LineBreak {
    /// U+2060 WORD JOINER: zero width, forbids a break at its position.
    static let joiner = "\u{2060}"

    static func keepingWords(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: isJapanese) else { return s }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = s
        tokenizer.setLanguage(.japanese)
        var out = ""
        var cursor = s.startIndex
        var afterWord = false
        tokenizer.enumerateTokens(in: s.startIndex..<s.endIndex) { range, _ in
            let gap = s[cursor..<range.lowerBound]
            let word = s[range]
            out += gap
            // A particle directly after a word stays on that word's line.
            if gap.isEmpty, afterWord, word.unicodeScalars.allSatisfy(isHiragana) {
                out += joiner
            }
            out += word.map(String.init).joined(separator: joiner)
            cursor = range.upperBound
            afterWord = true
            return true
        }
        out += s[cursor...]
        return out
    }

    private static func isHiragana(_ u: Unicode.Scalar) -> Bool { (0x3040...0x309F).contains(u.value) }

    private static func isJapanese(_ u: Unicode.Scalar) -> Bool {
        (0x3040...0x30FF).contains(u.value) || (0x4E00...0x9FFF).contains(u.value)
    }
}
