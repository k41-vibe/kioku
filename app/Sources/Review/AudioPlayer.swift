import Foundation
import AVFoundation

/// Plays `[sound:...]` files sequentially and speaks `{{tts}}` tags.
final class CardAudioPlayer: NSObject, AVAudioPlayerDelegate {
    private var queue: [Anki_CardRendering_AVTag] = []
    private var player: AVAudioPlayer?
    private var avPlayer: AVPlayer?
    private var endObserver: Any?
    private let synth = AVSpeechSynthesizer()
    private let mediaFolder: URL
    private var sessionReady = false
    var onError: ((String) -> Void)?

    init(mediaFolder: URL) {
        self.mediaFolder = mediaFolder
        super.init()
    }

    private func prepareSession() {
        guard !sessionReady else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.duckOthers])
            try session.setActive(true)
            sessionReady = true
        } catch {
            onError?("オーディオセッション: \(error.localizedDescription)")
        }
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
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        avPlayer?.pause()
        avPlayer = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
    }

    private func playNext() {
        guard !queue.isEmpty else { return }
        let tag = queue.removeFirst()
        switch tag.value {
        case .soundOrVideo(let rawName):
            prepareSession()
            let name = rawName.removingPercentEncoding ?? rawName
            let url = mediaFolder.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                onError?("音声ファイルが見つかりません: \(name)")
                playNext()
                return
            }
            do {
                let p = try AVAudioPlayer(contentsOf: url)
                player = p
                p.delegate = self
                p.prepareToPlay()
                if !p.play() {
                    onError?("再生を開始できません: \(name)")
                    playNext()
                }
            } catch {
                // AVAudioPlayer rejects some containers; try AVPlayer before giving up.
                let item = AVPlayerItem(url: url)
                let ap = AVPlayer(playerItem: item)
                avPlayer = ap
                endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                    self?.playNext()
                }
                ap.play()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    if let err = item.error {
                        self?.onError?("再生できません: \(name) (\(err.localizedDescription); AVAudioPlayer: \(error.localizedDescription))")
                        self?.playNext()
                    }
                }
            }
        case .tts(let tts):
            let utterance = AVSpeechUtterance(string: tts.fieldText)
            let lang = tts.lang.replacingOccurrences(of: "_", with: "-")
            utterance.voice = AVSpeechSynthesisVoice(language: lang) ?? AVSpeechSynthesisVoice(language: "en-US")
            if tts.speed > 0 {
                utterance.rate = min(max(AVSpeechUtteranceDefaultSpeechRate * tts.speed, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
            }
            prepareSession()
            synth.speak(utterance)
            waitForSpeech()
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

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        onError?("デコードエラー: \(error?.localizedDescription ?? "?")")
        playNext()
    }
}
