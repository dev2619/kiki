import XCTest
import AVFoundation
@testable import KikiAudio

final class AudioResamplerTests: XCTestCase {
    /// Buffer estéreo 48 kHz con una senoidal de 440 Hz en ambos canales.
    private func makeStereo48kBuffer(frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let data = buffer.floatChannelData!
        for frame in 0..<Int(frames) {
            let value = sinf(2 * .pi * 440 * Float(frame) / 48_000)
            data[0][frame] = value
            data[1][frame] = value
        }
        return buffer
    }

    func test_resamples48kStereoTo16kMono() {
        let buffer = makeStereo48kBuffer(frames: 4_800) // 0.1 s
        let samples = AudioResampler.resampleTo16kMono(buffer)
        // 0.1 s a 16 kHz ≈ 1600 muestras (tolerancia por primado del converter)
        XCTAssertGreaterThan(samples.count, 1_400)
        XCTAssertLessThanOrEqual(samples.count, 1_700)
    }

    func test_resampledSignalKeepsEnergy() {
        let buffer = makeStereo48kBuffer(frames: 4_800)
        let samples = AudioResampler.resampleTo16kMono(buffer)
        // La senoidal de amplitud 1.0 tiene RMS ≈ 0.707; tras resamplear debe conservarse aproximadamente.
        let rms = AudioResampler.rms(samples)
        XCTAssertGreaterThan(rms, 0.5)
        XCTAssertLessThan(rms, 0.9)
    }

    func test_passthroughWhenAlready16kMono() {
        let format = AudioResampler.targetFormat
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600)!
        buffer.frameLength = 1_600
        for frame in 0..<1_600 { buffer.floatChannelData![0][frame] = 0.25 }
        let samples = AudioResampler.resampleTo16kMono(buffer)
        XCTAssertEqual(samples.count, 1_600)
        XCTAssertEqual(samples[0], 0.25, accuracy: 0.001)
    }

    func test_rmsOfSilenceIsZero() {
        XCTAssertEqual(AudioResampler.rms(Array(repeating: 0, count: 100)), 0, accuracy: 0.0001)
    }

    func test_rmsOfEmptyIsZero() {
        XCTAssertEqual(AudioResampler.rms([]), 0)
    }
}
