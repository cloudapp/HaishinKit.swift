import Foundation
import XCTest
import AVFoundation

@testable import HaishinKit

final class AudioCodecTests: XCTestCase {
    func testEncoderCMSampleBuffer44100_1024() {
        let encoder = AudioCodec()
        encoder.startRunning()
        for _ in 0..<10 {
            if let sampleBuffer = CMAudioSampleBufferTestUtil.makeSinWave(44100, numSamples: 1024) {
                encoder.appendSampleBuffer(sampleBuffer)
            }
        }
    }

    func testEncoderCMSampleBuffer48000_1024() {
        let encoder = AudioCodec()
        encoder.startRunning()
        for _ in 0..<10 {
            if let sampleBuffer = CMAudioSampleBufferTestUtil.makeSinWave(48000.0, numSamples: 1024) {
                encoder.appendSampleBuffer(sampleBuffer)
            }
        }
    }

    func testEncoderCMSampleBuffer24000_1024() {
        let encoder = AudioCodec()
        encoder.startRunning()
        for _ in 0..<10 {
            if let sampleBuffer = CMAudioSampleBufferTestUtil.makeSinWave(24000.0, numSamples: 1024) {
                encoder.appendSampleBuffer(sampleBuffer)
            }
        }
    }

    func testEncoderCMSampleBuffer16000_1024() {
        let encoder = AudioCodec()
        encoder.startRunning()
        for _ in 0..<10 {
            if let sampleBuffer = CMAudioSampleBufferTestUtil.makeSinWave(16000.0, numSamples: 1024) {
                encoder.appendSampleBuffer(sampleBuffer)
            }
        }
    }

    func testEncoderCMSampleBuffer8000_256() {
        let encoder = AudioCodec()
        encoder.startRunning()
        for _ in 0..<10 {
            if let sampleBuffer = CMAudioSampleBufferTestUtil.makeSinWave(8000.0, numSamples: 256) {
                encoder.appendSampleBuffer(sampleBuffer)
            }
        }
    }

    func testEncoderCMSampleBuffer8000_960() {
        let encoder = AudioCodec()
        encoder.startRunning()
        for _ in 0..<10 {
            if let sampleBuffer = CMAudioSampleBufferTestUtil.makeSinWave(8000.0, numSamples: 960) {
                encoder.appendSampleBuffer(sampleBuffer)
            }
        }
    }

    func testEncoderCMSampleBuffer8000_1224() {
        let encoder = AudioCodec()
        encoder.startRunning()
        for _ in 0..<10 {
            if let sampleBuffer = CMAudioSampleBufferTestUtil.makeSinWave(44100.0, numSamples: 1224) {
                encoder.appendSampleBuffer(sampleBuffer)
            }
        }
    }

    func testEncoderCMSampleBuffer8000_numSamples() {
        let numSamples: [Int] = [1024, 1024, 1028, 1024, 1028, 1028, 962, 962, 960, 2237, 2236]
        let encoder = AudioCodec()
        encoder.startRunning()
        for numSample in numSamples {
            if let sampleBuffer = CMAudioSampleBufferTestUtil.makeSinWave(44100.0, numSamples: numSample) {
                encoder.appendSampleBuffer(sampleBuffer)
            }
        }
    }

    func test3Channel_withoutCrash() {
        let encoder = AudioCodec()
        encoder.startRunning()
        if let sampleBuffer = CMAudioSampleBufferTestUtil.makeSilence(44100, numSamples: 256, channels: 3) {
            encoder.appendSampleBuffer(sampleBuffer)
        }
    }
}

