import AVFoundation
import Foundation

/// Conversión de buffers PCM de cualquier formato al formato canónico
/// del pipeline: 16 kHz, mono, Float32 no intercalado.
public enum AudioResampler {
    /// AVAudioConverter emits slightly more frames than the exact resampling ratio; reserve this padding.
    private static let converterPrimingPadding: AVAudioFrameCount = 64

    public static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    public static func resampleTo16kMono(_ buffer: AVAudioPCMBuffer) -> [Float] {
        if buffer.format == targetFormat {
            return samples(from: buffer)
        }
        guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat) else {
            NSLog("kiki audio: no se pudo crear AVAudioConverter desde %@", buffer.format.description)
            return []
        }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + converterPrimingPadding
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return []
        }
        var inputConsumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        if status == .error || conversionError != nil {
            NSLog("kiki audio: conversión falló: %@", conversionError?.localizedDescription ?? "status .error")
            return []
        }
        return samples(from: output)
    }

    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumOfSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return sqrtf(sumOfSquares / Float(samples.count))
    }

    private static func samples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let data = buffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
    }
}
