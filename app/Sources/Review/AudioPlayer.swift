import Foundation
import AVFoundation

/// Plays `[sound:...]` files sequentially and speaks `{{tts}}` tags.
final class CardAudioPlayer: NSObject, AVAudioPlayerDelegate {
    private var queue: [Anki_CardRendering_AVTag] = []
    private var player: AVAudioPlayer?
    private let synth = AVSpeechSynthesizer()
    private let mediaFolder: URL

    init(mediaFolder: URL) {
        self.mediaFolder = mediaFolder
        super.init()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.duckOthers])
    }

    func play(_ tags: [Anki_CardRendering_AVTag]) {
        stop()
        queue = tags
        playNext()
    }

    func play(single tag: Anki_CardRendering_AVTag) {
        play([tag])
    }

    func stop() {
        queue.removeAll()
        player?.stop()
        player = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
    }

    private func playNext() {
        guard !queue.isEmpty else { return }
        let tag = queue.removeFirst()
        switch tag.value {
        case .soundOrVideo(let name):
            let url = mediaFolder.appendingPathComponent(name)
            try? AVAudioSession.sharedInstance().setActive(true)
            if let p = try? AVAudioPlayer(contentsOf: url) {
                player = p
                p.delegate = self
                p.play()
            } else {
                playNext()
            }
        case .tts(let tts):
            let utterance = AVSpeechUtterance(string: tts.fieldText)
            let lang = tts.lang.replacingOccurrences(of: "_", with: "-")
            utterance.voice = AVSpeechSynthesisVoice(language: lang) ?? AVSpeechSynthesisVoice(language: "en-US")
            if tts.speed > 0 { utterance.rate = min(max(AVSpeechUtteranceDefaultSpeechRate * tts.speed, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate) }
            synth.speak(utterance)
            // AVSpeechSynthesizer has its own delegate; keep it simple and continue with files after speech.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                if !self.synth.isSpeaking { self.playNext() }
                else {
                    // poll until done
                    self.waitForSpeech()
                }
            }
        case .none:
            playNext()
        }
    }

    private func waitForSpeech() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            if self.synth.isSpeaking { self.waitForSpeech() } else { self.playNext() }
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        playNext()
    }
}
