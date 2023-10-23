import Accelerate
import AVFoundation

private let kIOAudioResampler_frameCapacity: AVAudioFrameCount = 1024
private let kIOAudioResampler_sampleTime: AVAudioFramePosition = 0

protocol IOAudioResamplerDelegate: AnyObject {
    func resampler(_ resampler: IOAudioResampler<Self>, didOutput audioFormat: AVAudioFormat)
    func resampler(_ resampler: IOAudioResampler<Self>, didOutput audioPCMBuffer: AVAudioPCMBuffer, when: AVAudioTime)
    func resampler(_ resampler: IOAudioResampler<Self>, errorOccurred error: AudioCodec.Error)
}

struct IOAudioResamplerSettings {
    let sampleRate: Float64
    let channels: UInt32
    let downmix: Bool
    let channelMap: [NSNumber]?

    init(sampleRate: Float64 = 0, channels: UInt32 = 0, downmix: Bool = false, channelMap: [NSNumber]? = nil) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.downmix = downmix
        self.channelMap = channelMap
    }

    func invalidate(_ oldValue: IOAudioResamplerSettings) -> Bool {
        return !(sampleRate == oldValue.sampleRate &&
                    channels == oldValue.channels)
    }

    func apply(_ converter: AVAudioConverter?, oldValue: IOAudioResamplerSettings?) {
        guard let converter else {
            return
        }
        if converter.downmix != downmix {
            converter.downmix = downmix
        }
        if let channelMap {
            converter.channelMap = channelMap
        } else {
            switch converter.outputFormat.channelCount {
            case 1:
                converter.channelMap = [0]
            case 2:
                converter.channelMap = (converter.inputFormat.channelCount == 1) ? [0, 0] : [0, 1]
            default:
                logger.error("channelCount must be 2 or less.")
            }
        }
    }

    func makeOutputFormat(_ inputFormat: AVAudioFormat?) -> AVAudioFormat? {
        guard let inputFormat else {
            return nil
        }
        return .init(
            commonFormat: inputFormat.commonFormat,
            sampleRate: min(sampleRate == 0 ? inputFormat.sampleRate : sampleRate, AudioCodecSettings.mamimumSampleRate),
            channels: min(channels == 0 ? inputFormat.channelCount : channels, AudioCodecSettings.maximumNumberOfChannels),
            interleaved: inputFormat.isInterleaved
        )
    }
}

final class IOAudioResampler<T: IOAudioResamplerDelegate> {
    var settings: IOAudioResamplerSettings = .init() {
        didSet {
            if settings.invalidate(oldValue) {
                if var inSourceFormat {
                    setUp(&inSourceFormat)
                }
            } else {
                settings.apply(audioConverter, oldValue: oldValue)
            }
        }
    }
    weak var delegate: T?

    var inputFormat: AVAudioFormat? {
        return audioConverter?.inputFormat
    }

    var outputFormat: AVAudioFormat? {
        return audioConverter?.outputFormat
    }

    private var inSourceFormat: AudioStreamBasicDescription? {
        didSet {
            guard var inSourceFormat, inSourceFormat != oldValue else {
                return
            }
            setUp(&inSourceFormat)
        }
    }
    private var ringBuffer: IOAudioRingBuffer?
    private var inputBuffer: AVAudioPCMBuffer?
    private var outputBuffer: AVAudioPCMBuffer?
    private var audioConverter: AVAudioConverter? {
        didSet {
            guard let audioConverter else {
                return
            }
            settings.apply(audioConverter, oldValue: nil)
            audioConverter.primeMethod = .normal
            delegate?.resampler(self, didOutput: audioConverter.outputFormat)
        }
    }
    private var sampleTime: AVAudioFramePosition = kIOAudioResampler_sampleTime

    func appendSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        inSourceFormat = sampleBuffer.formatDescription?.audioStreamBasicDescription
        if sampleTime == kIOAudioResampler_sampleTime {
            sampleTime = sampleBuffer.presentationTimeStamp.value
        }
        ringBuffer?.appendSampleBuffer(sampleBuffer)
        resample()
    }

    func appendAudioPCMBuffer(_ audioBuffer: AVAudioPCMBuffer, when: AVAudioTime) {
        inSourceFormat = audioBuffer.format.formatDescription.audioStreamBasicDescription
        if sampleTime == kIOAudioResampler_sampleTime {
            sampleTime = when.sampleTime
        }
        ringBuffer?.appendAudioPCMBuffer(audioBuffer, when: when)
        resample()
    }

    @inline(__always)
    private func resample() {
        guard let outputBuffer, let inputBuffer, let ringBuffer else {
            return
        }
        var status: AVAudioConverterOutputStatus? = .endOfStream
        repeat {
            var error: NSError?
            status = audioConverter?.convert(to: outputBuffer, error: &error) { inNumberFrames, status in
                if inNumberFrames <= ringBuffer.counts {
                    _ = ringBuffer.render(inNumberFrames, ioData: inputBuffer.mutableAudioBufferList)
                    inputBuffer.frameLength = inNumberFrames
                    status.pointee = .haveData
                    return inputBuffer
                } else {
                    status.pointee = .noDataNow
                    return nil
                }
            }
            switch status {
            case .haveData:
                delegate?.resampler(self, didOutput: outputBuffer, when: .init(sampleTime: sampleTime, atRate: outputBuffer.format.sampleRate))
                sampleTime += 1024
            case .error:
                if let error {
                    delegate?.resampler(self, errorOccurred: .failedToConvert(error: error))
                }
            default:
                break
            }
        } while(status == .haveData)
    }

    private func setUp(_ inSourceFormat: inout AudioStreamBasicDescription) {
        let inputFormat = AVAudioFormatFactory.makeAudioFormat(&inSourceFormat)
        let outputFormat = settings.makeOutputFormat(inputFormat) ?? inputFormat
        if let inputFormat {
            inputBuffer = .init(pcmFormat: inputFormat, frameCapacity: 1024 * 4)
            ringBuffer = .init(inputFormat)
        }
        if let outputFormat {
            outputBuffer = .init(pcmFormat: outputFormat, frameCapacity: kIOAudioResampler_frameCapacity)
        }
        if let inputFormat, let outputFormat {
            if logger.isEnabledFor(level: .info) {
                logger.info("inputFormat:", inputFormat, ",outputFormat:", outputFormat)
            }
            sampleTime = kIOAudioResampler_sampleTime
            audioConverter = .init(from: inputFormat, to: outputFormat)
        } else {
            delegate?.resampler(self, errorOccurred: .failedToCreate(from: inputFormat, to: outputFormat))
        }
    }
}
