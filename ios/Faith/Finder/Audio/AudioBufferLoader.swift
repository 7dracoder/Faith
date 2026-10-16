import AVFoundation

/// Loads bundled sounds into memory in ONE fixed format per player, so the
/// engine graph never has to be reconnected when a sound is swapped. A cue that
/// is not mono would silently lose spatialization, and a buffer whose channel
/// count differs from the player's connection crashes, so everything is
/// converted here instead of trusting the files.
enum AudioBufferLoader {
    static let sampleRate: Double = 48_000
    /// Cues are brought to this peak (about -3 dBFS) so every candidate plays
    /// at a comparable level and overlapping pulses keep some headroom.
    static let cuePeakAmplitude: Float = 0.7
    /// Tried in this order when looking a sound up by name.
    static let supportedExtensions = ["wav", "mp3"]

    /// Loads the file behind a cue as mono 48 kHz, peak normalized. Mono is what
    /// makes the environment node spatialize it.
    static func loadCue(_ id: CueSoundID, bundle: Bundle = .main) throws -> AVAudioPCMBuffer {
        let name = CueSoundCatalog.resourceName(for: id)
        let buffer = try loadBuffer(named: name, channelCount: 1, bundle: bundle)
        normalizePeak(of: buffer, to: cuePeakAmplitude)
        return buffer
    }

    /// Loads `<name>.wav` (or `.mp3`) from the bundle as Float32 at 48 kHz with `channelCount` channels.
    static func loadBuffer(
        named name: String,
        channelCount: AVAudioChannelCount,
        bundle: Bundle = .main
    ) throws -> AVAudioPCMBuffer {
        guard let url = resourceURL(named: name, bundle: bundle) else {
            throw FinderError.audioEngineFailed("Sound \(name) is missing from the bundle")
        }

        let file = try AVAudioFile(forReading: url)
        let fileFormat = file.processingFormat
        let frameCapacity = AVAudioFrameCount(file.length)

        guard let fileBuffer = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: frameCapacity) else {
            throw FinderError.audioEngineFailed("Could not allocate a buffer for \(name).wav")
        }
        try file.read(into: fileBuffer)

        let remapped = try remapChannels(fileBuffer, channelCount: channelCount)
        return try resample(remapped, sampleRate: sampleRate)
    }

    /// Scales the buffer in place so its loudest sample has `peakAmplitude`. Silence is left alone.
    static func normalizePeak(of buffer: AVAudioPCMBuffer, to peakAmplitude: Float) {
        guard let data = buffer.floatChannelData else {
            return
        }
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)

        var currentPeak: Float = 0
        for channel in 0..<channelCount {
            for frame in 0..<frameCount {
                currentPeak = max(currentPeak, abs(data[channel][frame]))
            }
        }
        if currentPeak < 1e-6 {
            return
        }

        let scale = peakAmplitude / currentPeak
        for channel in 0..<channelCount {
            for frame in 0..<frameCount {
                data[channel][frame] *= scale
            }
        }
    }

    /// Mono -> N copies the signal to every channel. N -> mono averages. Same count is returned as is.
    static func remapChannels(
        _ source: AVAudioPCMBuffer,
        channelCount: AVAudioChannelCount
    ) throws -> AVAudioPCMBuffer {
        let sourceChannelCount = source.format.channelCount
        if sourceChannelCount == channelCount {
            return source
        }

        guard let sourceData = source.floatChannelData else {
            throw FinderError.audioEngineFailed("Sound is not Float32 PCM")
        }
        guard let targetFormat = AVAudioFormat(
            standardFormatWithSampleRate: source.format.sampleRate,
            channels: channelCount
        ) else {
            throw FinderError.audioEngineFailed("Unsupported channel count \(channelCount)")
        }
        guard let target = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: source.frameLength) else {
            throw FinderError.audioEngineFailed("Could not allocate a remap buffer")
        }
        guard let targetData = target.floatChannelData else {
            throw FinderError.audioEngineFailed("Remap buffer is not Float32 PCM")
        }
        target.frameLength = source.frameLength

        let frameCount = Int(source.frameLength)
        let sourceChannels = Int(sourceChannelCount)
        let targetChannels = Int(channelCount)

        for frame in 0..<frameCount {
            var sum: Float = 0
            for channel in 0..<sourceChannels {
                sum += sourceData[channel][frame]
            }
            let mono = sum / Float(sourceChannels)

            for channel in 0..<targetChannels {
                targetData[channel][frame] = mono
            }
        }
        return target
    }

    /// Sample-rate conversion only. The channel count is kept.
    static func resample(_ source: AVAudioPCMBuffer, sampleRate: Double) throws -> AVAudioPCMBuffer {
        let sourceFormat = source.format
        if sourceFormat.sampleRate == sampleRate {
            return source
        }

        guard let targetFormat = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: sourceFormat.channelCount
        ) else {
            throw FinderError.audioEngineFailed("Unsupported sample rate \(sampleRate)")
        }
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw FinderError.audioEngineFailed("No converter from \(sourceFormat.sampleRate) Hz to \(sampleRate) Hz")
        }

        let ratio = sampleRate / sourceFormat.sampleRate
        let estimatedFrames = (Double(source.frameLength) * ratio).rounded(.up)
        let capacity = AVAudioFrameCount(estimatedFrames) + 64

        guard let target = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            throw FinderError.audioEngineFailed("Could not allocate a resample buffer")
        }

        var didProvideInput = false
        var conversionError: NSError?
        let status = converter.convert(to: target, error: &conversionError) { _, inputStatus in
            if didProvideInput {
                inputStatus.pointee = .endOfStream
                return nil
            }
            didProvideInput = true
            inputStatus.pointee = .haveData
            return source
        }

        if status == .error {
            let reason = conversionError?.localizedDescription ?? "unknown error"
            throw FinderError.audioEngineFailed("Resampling failed: \(reason)")
        }
        return target
    }

    private static func resourceURL(named name: String, bundle: Bundle) -> URL? {
        for fileExtension in supportedExtensions {
            if let flatURL = bundle.url(forResource: name, withExtension: fileExtension) {
                return flatURL
            }
            if let nestedURL = bundle.url(forResource: name, withExtension: fileExtension, subdirectory: "Sounds") {
                return nestedURL
            }
        }
        return nil
    }
}
