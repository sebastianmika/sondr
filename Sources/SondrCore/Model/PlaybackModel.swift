import AVFoundation
import Foundation
import Observation

/// Plays one sample at a time through the default output.
@MainActor
@Observable
public final class PlaybackModel {
    public private(set) var playingID: Int64?
    public private(set) var isPlaying = false
    /// 0...1 position in the current sample, for the playhead.
    public private(set) var progress = 0.0
    public private(set) var errorMessage: String?
    /// Start playing as soon as a sample is selected.
    public var autoAudition = false

    private var player: AVAudioPlayer?
    private var timer: Timer?

    public init() {}

    /// Plays `row` from the start, or stops it if it is the one playing.
    public func toggle(_ row: SampleRow) {
        if playingID == row.id, isPlaying { stop() } else { play(row) }
    }

    public func play(_ row: SampleRow) {
        stop()
        errorMessage = nil
        let url = URL(fileURLWithPath: row.canonicalPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "\(row.filename) is not at \(url.deletingLastPathComponent().path) any more. Rescan the folder."
            return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            guard player.play() else {
                errorMessage = "Could not start playback of \(row.filename)."
                return
            }
            self.player = player
            playingID = row.id
            isPlaying = true
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        } catch {
            errorMessage = "Cannot play \(row.filename): \(error.localizedDescription)"
        }
    }

    /// Stops playback and forgets the position.
    public func stop() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
        isPlaying = false
        playingID = nil
        progress = 0
    }

    /// Called when the selection changes.
    public func selectionChanged(to row: SampleRow?) {
        if let row, autoAudition { play(row) } else { stop() }
    }

    private func tick() {
        guard let player else { return }
        if player.isPlaying, player.duration > 0 {
            progress = min(player.currentTime / player.duration, 1)
        } else {
            stop()
        }
    }
}
