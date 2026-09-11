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
            answerPanel
                .frame(height: answerHeight)
                .offset(y: height - progress * answerHeight)
                .opacity(progress < 0.02 ? 0 : 1)
        }
        .frame(height: height)
        .clipped()
        .contentShape(Rectangle())
    }

    private var questionBlock: some View {
        VStack(spacing: 14) {
            Spacer()
            if !card.reading.isEmpty {
                Text(card.reading).font(.footnote).foregroundStyle(Theme.gray1)
            }
            HStack(alignment: .center, spacing: 10) {
                Text(card.word)
                    .font(.system(size: card.word.count > 14 ? 30 : 40, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.6)
                if !card.wordAudio.isEmpty && interactive {
                    playButton { onPlay(card.questionAudio) }
                }
            }
            if !card.example.isEmpty {
                VStack(spacing: 8) {
                    Text(card.example)
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
                        Text(m)
                            .font(.title2.weight(.semibold))
                            .lineSpacing(3)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .multilineTextAlignment(.center)
                    }
                    if !card.exampleMeaning.isEmpty {
                        Text(card.exampleMeaning)
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
                                Text(pair.1).font(.footnote).lineSpacing(2)
                            }
                        }
                    }
                    if !memo.isEmpty {
                        Divider().padding(.vertical, 2)
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "note.text").font(.caption).foregroundStyle(Theme.gray1).padding(.top, 2)
                            Text(memo).font(.footnote)
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
