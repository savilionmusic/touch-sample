import AVFoundation
import Foundation

/// Plays the upstream emulator's unchanged S16_LE stereo / 44.1 kHz PCM stream
/// through CoreAudio. WebKit remains the display; it never opens a second PCM client.
final class NativeAudio {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
    private let queue = DispatchQueue(label: "touchsample.audio", qos: .userInitiated)
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var timer: DispatchSourceTimer?
    private var active = false
    private var generation = 0
    private var queued = 0
    private var pending = Data()
    private var framesReceived = 0
    private var peak: Float = 0
    private var underruns = 0
    private var targetFrames = 2048
    // The guest's audio clock and the Apollo's differ slightly (measured ~140 ppm fast), so the
    // queue drifts once there are no xruns to reset it. Outside this band each packet is resampled
    // by one frame (~0.4 %, linear) until the queue is back near target.
    private var correcting = 0          // -1 shrinking, +1 stretching, 0 none
    private var trimmed = 0, stretched = 0
    var log: (String) -> Void = { _ in }

    func start() throws {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1
        try engine.start()
        let output = engine.outputNode.outputFormat(forBus: 0)
        log("NATIVE AUDIO CoreAudio output \(output.sampleRate) Hz / \(output.channelCount) channels; PCM 44100 Hz stereo")
        queue.sync {
            active = true
            session = URLSession(configuration: .ephemeral)
            connect()
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 2, repeating: 2)
            t.setEventHandler { [weak self] in
                guard let self else { return }
                self.log("NATIVE AUDIO received=\(self.framesReceived) frames queued=\(self.queued) peak=\(self.peak) playing=\(self.player.isPlaying) target=\(self.targetFrames) underruns=\(self.underruns) trimmed=\(self.trimmed) stretched=\(self.stretched)")
                self.peak = 0
            }
            timer = t; t.resume()
        }
    }
    private func connect() {
        guard active else { return }
        generation += 1
        let token = generation
        let task = session!.webSocketTask(with: URL(string: "ws://127.0.0.1:5557")!)
        socket = task; task.resume(); receive(task, token)
    }
    private func receive(_ task: URLSessionWebSocketTask, _ token: Int) {
        task.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard self.active, token == self.generation else { return }
                switch result {
                case .success(let message):
                    if case .data(let data) = message { self.enqueue(data, token) }
                    self.receive(task, token)
                case .failure(let error):
                    self.log("NATIVE AUDIO connection: \(error.localizedDescription)")
                    self.generation += 1; self.player.stop(); self.queued = 0; self.pending.removeAll()
                    self.queue.asyncAfter(deadline: .now() + 1) { self.connect() }
                }
            }
        }
    }
    static func decode(_ data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = data.count / 4
        guard frames > 0, data.count % 4 == 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { bytes in
            for i in 0..<frames {
                channels[0][i] = Float(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: i * 4, as: Int16.self))) / 32768
                channels[1][i] = Float(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: i * 4 + 2, as: Int16.self))) / 32768
            }
        }
        return buffer
    }
    /// Linear resample of a whole packet to `frames` frames (used for one-frame drift steps).
    static func resample(_ input: AVAudioPCMBuffer, to frames: Int, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let n = Int(input.frameLength)
        guard n > 1, frames > 1, let src = input.floatChannelData,
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let dst = out.floatChannelData else { return nil }
        out.frameLength = AVAudioFrameCount(frames)
        let step = Double(n - 1) / Double(frames - 1)
        for i in 0..<frames {
            let x = Double(i) * step, j = min(Int(x), n - 2), f = Float(x - Double(j))
            for c in 0..<2 { dst[c][i] = src[c][j] + (src[c][j + 1] - src[c][j]) * f }
        }
        return out
    }
    private func enqueue(_ data: Data, _ token: Int) {
        pending.append(data)
        let count = pending.count / 4 * 4
        guard count > 0 else { return }
        let packet = Data(pending.prefix(count)); pending = Data(pending.dropFirst(count))
        // Bound latency after host stalls; don't accumulate seconds of stale sound.
        guard queued < 16384, var buffer = Self.decode(packet, format: format) else { return }
        if player.isPlaying {
            if queued > targetFrames + 1024 { correcting = -1 } else if queued < targetFrames - 1024 { correcting = 1 }
            else if (correcting < 0 && queued <= targetFrames + 512) || (correcting > 0 && queued >= targetFrames - 512) { correcting = 0 }
            let n = Int(buffer.frameLength)
            if correcting != 0, n > 64, let r = Self.resample(buffer, to: n + correcting, format: format) {
                buffer = r
                if correcting < 0 { trimmed += 1 } else { stretched += 1 }
            }
        } else { correcting = 0 }
        let frames = Int(buffer.frameLength)
        framesReceived += frames
        if let channels = buffer.floatChannelData {
            for i in 0..<frames { peak = max(peak, abs(channels[0][i]), abs(channels[1][i])) }
        }
        queued += frames
        player.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                guard self.active, token == self.generation else { return }
                self.queued = max(0, self.queued - frames)
                if self.queued == 0, self.player.isPlaying { self.underruns += 1 }
            }
        }
        if !player.isPlaying, queued >= targetFrames { player.play() }
    }
    func stop() {
        queue.sync {
            active = false; generation += 1; timer?.cancel(); timer = nil
            socket?.cancel(with: .goingAway, reason: nil); socket = nil
            session?.invalidateAndCancel(); session = nil
            player.stop(); engine.stop(); queued = 0; pending.removeAll()
        }
    }
    static func selfTest() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let buffer = decode(Data([0x00,0x80,0xFF,0x7F,0x00,0x40,0x00,0xC0]), format: format)!
        precondition(buffer.frameLength == 2)
        precondition(buffer.floatChannelData![0][0] == -1)
        precondition(abs(buffer.floatChannelData![1][0] - 32767.0 / 32768) < 0.00001)
        precondition(buffer.floatChannelData![0][1] == 0.5 && buffer.floatChannelData![1][1] == -0.5)
        precondition(decode(Data([1,2,3]), format: format) == nil)
        let ramp = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256)!; ramp.frameLength = 256
        for i in 0..<256 { ramp.floatChannelData![0][i] = Float(i); ramp.floatChannelData![1][i] = -Float(i) }
        for size in [255, 257] {
            let r = resample(ramp, to: size, format: format)!
            precondition(Int(r.frameLength) == size)
            precondition(r.floatChannelData![0][0] == 0 && abs(r.floatChannelData![0][size - 1] - 255) < 0.001)
            precondition(abs(r.floatChannelData![1][size / 2] + r.floatChannelData![0][size / 2]) < 0.001)
        }
        print("Native PCM stereo, endianness, signed amplitude and malformed-frame and drift-resample checks passed (no audio device opened)")
    }
}
