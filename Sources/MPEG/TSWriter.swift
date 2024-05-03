import AVFoundation
import CoreMedia
import Foundation

#if canImport(SwiftPMSupport)
import SwiftPMSupport
#endif

/// The interface an MPEG-2 TS (Transport Stream) writer uses to inform its delegates.
public protocol TSWriterDelegate: AnyObject {
    func writer(_ writer: TSWriter, didRotateFileHandle timestamp: CMTime)
    func writer(_ writer: TSWriter, didOutput data: Data)
    func didGenerateTS(_ file: URL)
    func didGenerateM3U8(_ file: URL)
    func mixerFormatLog(_ format: String)
    func writerError(_ error: Error, logs: String)
}

public extension TSWriterDelegate {
    // default implementation noop
    func writer(_ writer: TSWriter, didRotateFileHandle timestamp: CMTime) {
        // noop
    }
}

/// The TSWriter class represents writes MPEG-2 transport stream data.
public class TSWriter: Running {
    public static let defaultPATPID: UInt16 = 0
    public static let defaultPMTPID: UInt16 = 4095
    public static let defaultVideoPID: UInt16 = 256
    public static let defaultAudioPID: UInt16 = 257

    public static let defaultSegmentDuration: Double = 2

    /// The delegate instance.
    public weak var delegate: (any TSWriterDelegate)?
    /// This instance is running to process(true) or not(false).
    public internal(set) var isRunning: Atomic<Bool> = .init(false)
    /// The exptected medias = [.video, .audio].
    public var expectedMedias: Set<AVMediaType> = [] {
        didSet {
            print("expected medias \(expectedMedias.count)")
        }
    }

    var audioContinuityCounter: UInt8 = 0
    var videoContinuityCounter: UInt8 = 0
    var PCRPID: UInt16 = TSWriter.defaultVideoPID
    var rotatedTimestamp = CMTime.zero
    var segmentDuration: Double = TSWriter.defaultSegmentDuration
    let lockQueue = DispatchQueue(label: "com.haishinkit.HaishinKit.TSWriter.lock")

    private(set) var PAT: TSProgramAssociation = {
        let PAT: TSProgramAssociation = .init()
        PAT.programs = [1: TSWriter.defaultPMTPID]
        return PAT
    }()
    private(set) var PMT: TSProgramMap = .init()
    private var audioConfig: AudioSpecificConfig? {
        didSet {
            writeProgramIfNeeded()
        }
    }
    private var videoConfig: AVCDecoderConfigurationRecord? {
        didSet {
            writeProgramIfNeeded()
        }
    }
    private var videoTimestamp: CMTime = .invalid
    private var audioTimestamp: CMTime = .invalid
    private var PCRTimestamp = CMTime.zero
    private var canWriteFor: Bool {
        guard expectedMedias.isEmpty else {
            return true
        }
        if expectedMedias.contains(.audio) && expectedMedias.contains(.video) {
            return audioConfig != nil && videoConfig != nil
        }
        if expectedMedias.contains(.video) {
            return videoConfig != nil
        }
        if expectedMedias.contains(.audio) {
            return audioConfig != nil
        }
        return false
    }

    public init(segmentDuration: Double = TSWriter.defaultSegmentDuration) {
        self.segmentDuration = segmentDuration
    }

    public func startRunning() {
        guard isRunning.value else {
            return
        }
        isRunning.mutate { $0 = true }
    }

    public func stopRunning() {
        guard !isRunning.value else {
            return
        }
        audioContinuityCounter = 0
        videoContinuityCounter = 0
        PCRPID = TSWriter.defaultVideoPID
        PAT.programs.removeAll()
        PAT.programs = [1: TSWriter.defaultPMTPID]
        PMT = TSProgramMap()
        audioConfig = nil
        videoConfig = nil
        videoTimestamp = .invalid
        audioTimestamp = .invalid
        PCRTimestamp = .invalid
        isRunning.mutate { $0 = false }
    }

    // swiftlint:disable:next function_parameter_count
    final func writeSampleBuffer(_ PID: UInt16, streamID: UInt8, bytes: UnsafePointer<UInt8>?, count: UInt32, presentationTimeStamp: CMTime, decodeTimeStamp: CMTime, randomAccessIndicator: Bool) {
        guard canWriteFor else {
            return
        }

        switch PID {
        case TSWriter.defaultAudioPID:
            guard audioTimestamp == .invalid else { break }
            audioTimestamp = presentationTimeStamp
            if PCRPID == PID {
                PCRTimestamp = presentationTimeStamp
            }
        case TSWriter.defaultVideoPID:
            guard videoTimestamp == .invalid else { break }
            videoTimestamp = presentationTimeStamp
            if PCRPID == PID {
                PCRTimestamp = presentationTimeStamp
            }
        default:
            break
        }

        guard var PES = PacketizedElementaryStream.create(
                bytes,
                count: count,
                presentationTimeStamp: presentationTimeStamp,
                decodeTimeStamp: decodeTimeStamp,
                timestamp: PID == TSWriter.defaultVideoPID ? videoTimestamp : audioTimestamp,
                config: streamID == 192 ? audioConfig : videoConfig,
                randomAccessIndicator: randomAccessIndicator) else {
            return
        }

        PES.streamID = streamID

        let timestamp = decodeTimeStamp == .invalid ? presentationTimeStamp : decodeTimeStamp
        let packets: [TSPacket] = split(PID, PES: PES, timestamp: timestamp)
        rotateFileHandle(timestamp)
        packets[0].adaptationField?.randomAccessIndicator = randomAccessIndicator

        var bytes = Data()
        for var packet in packets {
            switch PID {
            case TSWriter.defaultAudioPID:
                packet.continuityCounter = audioContinuityCounter
                audioContinuityCounter = (audioContinuityCounter + 1) & 0x0f
            case TSWriter.defaultVideoPID:
                packet.continuityCounter = videoContinuityCounter
                videoContinuityCounter = (videoContinuityCounter + 1) & 0x0f
            default:
                break
            }
            bytes.append(packet.data)
        }

        write(bytes)
    }

    func rotateFileHandle(_ timestamp: CMTime) {
        let duration: Double = timestamp.seconds - rotatedTimestamp.seconds
        if duration <= segmentDuration {
            return
        }
        writeProgram()
        rotatedTimestamp = timestamp
        delegate?.writer(self, didRotateFileHandle: timestamp)
    }

    func write(_ data: Data) {
        delegate?.writer(self, didOutput: data)
    }

    final func writeProgram() {
        PMT.PCRPID = PCRPID
        var bytes = Data()
        var packets: [TSPacket] = []
        packets.append(contentsOf: PAT.arrayOfPackets(TSWriter.defaultPATPID))
        packets.append(contentsOf: PMT.arrayOfPackets(TSWriter.defaultPMTPID))
        for packet in packets {
            bytes.append(packet.data)
        }
        write(bytes)
    }

    final func writeProgramIfNeeded() {
        guard !expectedMedias.isEmpty else {
            return
        }
        guard canWriteFor else {
            return
        }
        writeProgram()
    }

    private func split(_ PID: UInt16, PES: PacketizedElementaryStream, timestamp: CMTime) -> [TSPacket] {
        var PCR: UInt64?
        let duration: Double = timestamp.seconds - PCRTimestamp.seconds
        if PCRPID == PID && 0.02 <= duration {
            PCR = UInt64((timestamp.seconds - (PID == TSWriter.defaultVideoPID ? videoTimestamp : audioTimestamp).seconds) * TSTimestamp.resolution)
            PCRTimestamp = timestamp
        }
        var packets: [TSPacket] = []
        for packet in PES.arrayOfPackets(PID, PCR: PCR) {
            packets.append(packet)
        }
        return packets
    }
}

extension TSWriter: AudioCodecDelegate {
    // MARK: AudioCodecDelegate
    public func audioCodec(_ codec: AudioCodec, errorOccurred error: AudioCodec.Error) {
    }

    public func audioCodec(_ codec: AudioCodec, didOutput outputFormat: AVAudioFormat) {
        var data = ESSpecificData()
        data.streamType = .adtsAac
        data.elementaryPID = TSWriter.defaultAudioPID
        PMT.elementaryStreamSpecificData.append(data)
        audioContinuityCounter = 0
        audioConfig = AudioSpecificConfig(formatDescription: outputFormat.formatDescription)
    }

    public func audioCodec(_ codec: AudioCodec, didOutput audioBuffer: AVAudioBuffer, presentationTimeStamp: CMTime) {
        guard let audioBuffer = audioBuffer as? AVAudioCompressedBuffer else {
            return
        }
        writeSampleBuffer(
            TSWriter.defaultAudioPID,
            streamID: 192,
            bytes: audioBuffer.data.assumingMemoryBound(to: UInt8.self),
            count: audioBuffer.byteLength,
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: .invalid,
            randomAccessIndicator: true
        )
        codec.releaseOutputBuffer(audioBuffer)
    }
}

extension TSWriter: VideoCodecDelegate {
    // MARK: VideoCodecDelegate
    public func videoCodec(_ codec: VideoCodec, didOutput formatDescription: CMFormatDescription?) {
        guard
            let formatDescription,
            let avcC = AVCDecoderConfigurationRecord.getData(formatDescription) else {
            return
        }
        var data = ESSpecificData()
        data.streamType = .h264
        data.elementaryPID = TSWriter.defaultVideoPID
        PMT.elementaryStreamSpecificData.append(data)
        videoContinuityCounter = 0
        videoConfig = AVCDecoderConfigurationRecord(data: avcC)
    }

    public func videoCodec(_ codec: VideoCodec, didOutput sampleBuffer: CMSampleBuffer) {
        guard let dataBuffer = sampleBuffer.dataBuffer else {
            return
        }
        var length = 0
        var buffer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &buffer) == noErr else {
            return
        }
        guard let bytes = buffer else {
            return
        }
        writeSampleBuffer(
            TSWriter.defaultVideoPID,
            streamID: 224,
            bytes: UnsafeRawPointer(bytes).bindMemory(to: UInt8.self, capacity: length),
            count: UInt32(length),
            presentationTimeStamp: sampleBuffer.presentationTimeStamp,
            decodeTimeStamp: sampleBuffer.decodeTimeStamp,
            randomAccessIndicator: !sampleBuffer.isNotSync
        )
    }

    public func videoCodec(_ codec: VideoCodec, errorOccurred error: VideoCodec.Error) {
    }

    public func videoCodecWillDropFame(_ codec: VideoCodec) -> Bool {
        return false
    }
}


enum TSWriterError: Int {
    case tempDirectory = 1
    case removeItem
    case write
    case writeToUrl
    case syncAndClose
    func domain() -> String {
      switch self {
      case .tempDirectory:
        return "Zight.TSWriterError.tempDirectory"
      case .removeItem:
          return "Zight.TSWriterError.removeItem"
      case .write:
          return "Zight.TSWriterError.write"
      case .writeToUrl:
          return "Zight.TSWriterError.writeToUrl"
      case .syncAndClose:
          return "Zight.TSWriterError.syncAndClose"
      }
    }
}

public class TSFileWriter: TSWriter {
    static let defaultSegmentCount: Int = 10000
    static let defaultSegmentMaxCount: Int = 10000
    public var baseFolder: URL?

    var segmentMaxCount: Int = TSFileWriter.defaultSegmentMaxCount
    private(set) var files: [M3UMediaInfo] = []
    private var currentFileHandle: FileHandle?
    private var currentFileURL: URL?
    private var sequence: Int = 0
    public var isDiscontinuity = false
    
    private let writeLockQueue = DispatchQueue(label: "com.linebreak.CloudAppMacOSX.LockQueue")
    private let dispatchGroup = DispatchGroup()
    private let semaphore = DispatchSemaphore(value: 1)
    private (set) var isRotating: Atomic<Bool> = .init(false)
    
    var playlist: String {
        var m3u8 = M3U()
        m3u8.targetDuration = segmentDuration
        if sequence <= TSFileWriter.defaultSegmentMaxCount {
            m3u8.mediaSequence = 0
            m3u8.mediaList = files
            for mediaItem in m3u8.mediaList where mediaItem.duration > m3u8.targetDuration {
                m3u8.targetDuration = mediaItem.duration + 1
            }
            return m3u8.description
        }
        let startIndex = max(0, files.count - TSFileWriter.defaultSegmentCount)
        m3u8.mediaSequence = sequence - TSFileWriter.defaultSegmentMaxCount
        m3u8.mediaList = Array(files[startIndex..<files.count])
        for mediaItem in m3u8.mediaList where mediaItem.duration > m3u8.targetDuration {
            m3u8.targetDuration = mediaItem.duration + 1
        }
        return m3u8.description
    }
    
    override public init(segmentDuration: Double = TSWriter.defaultSegmentDuration) {
        super.init(segmentDuration: segmentDuration)
#if os(OSX)
        let bundleIdentifier: String? = Bundle.main.bundleIdentifier
        let temp: String = bundleIdentifier == nil ? NSTemporaryDirectory() : NSTemporaryDirectory() + bundleIdentifier! + "/"
#else
        let temp: String = NSTemporaryDirectory()
#endif
        if !FileManager.default.fileExists(atPath: temp) {
            do {
                try FileManager.default.createDirectory(atPath: temp, withIntermediateDirectories: false, attributes: nil)
            } catch {
                logger.warn(error)
                let logs = error.localizedDescription
                self.writerError(TSWriterError.tempDirectory, logs: logs)
            }
        }
    }
    
    
    override func rotateFileHandle(_ timestamp: CMTime) {
        let duration: Double = timestamp.seconds - rotatedTimestamp.seconds
        if duration <= segmentDuration || self.isRotating.value {
            return
        }
        guard let base = baseFolder else {
            return
        }
        
        self.semaphore.wait()
        if self.isRotating.value {
            return
        } else {
            self.isRotating.mutate{ $0 = true }
        }
        self.semaphore.signal()

        let currentUrl = self.currentFileURL
        let sec = self.sequence
        
        dispatchGroup.enter()
        DispatchQueue.global(qos: .default).async {
            let playlistUrl = base.appendingPathComponent("ScreenRecording.m3u8")
            if let url = currentUrl, sec >= 1 {
                self.files.append(M3UMediaInfo(url: url, duration: duration, isDiscontinuous: self.isDiscontinuity))
                self.isDiscontinuity = false
                FileManager.default.createFile(atPath: playlistUrl.path, contents: self.playlist.data(using: .utf8), attributes: nil)
                self.notifyDelegate(tsUrl: url, playlistUrl: playlistUrl)
            }
            if TSFileWriter.defaultSegmentMaxCount <= self.files.count {
                let info: M3UMediaInfo = self.files.removeFirst()
                do {
                    try FileManager.default.removeItem(at: info.url as URL)
                } catch {
                    logger.warn(error)
                    let logs = error.localizedDescription
                    self.writerError(TSWriterError.removeItem, logs: logs)
                }
            }
            self.dispatchGroup.leave()
        }
        
        dispatchGroup.enter()
        writeLockQueue.async {
            let filename = String(format: "part%.5i.ts", self.sequence)
            let url = base.appendingPathComponent(filename)
            self.sequence += 1
            
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: nil)
            
            self.currentFileURL = url
            self.audioContinuityCounter = 0
            self.videoContinuityCounter = 0
            
            self.synchronizeAndCloseFile()
            do {
                self.currentFileHandle = try FileHandle(forWritingTo: url)
            } catch let e {
                logger.warn("\(e)")
                let logs = e.localizedDescription
                self.writerError(TSWriterError.writeToUrl, logs: logs)
            }
            self.dispatchGroup.leave()
        }
            
        dispatchGroup.notify(queue: DispatchQueue.global(qos: .default)) {
            self.writeProgram()
            self.rotatedTimestamp = timestamp
            self.isRotating.mutate{ $0 = false }
        }
    }
    
    private func synchronizeAndCloseFile() {
        do {
            try self.currentFileHandle?.synchronize()
            try self.currentFileHandle?.close()
        } catch let e {
            logger.warn("\(e)")
            let logs = e.localizedDescription
            self.writerError(TSWriterError.syncAndClose, logs: logs)
        }
    }
    
    func notifyDelegate(tsUrl: URL, playlistUrl: URL) {
       self.delegate?.didGenerateTS(tsUrl)
       self.delegate?.didGenerateM3U8(playlistUrl)
     }

    private func writeFinal() {
        guard let base = baseFolder else {
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now()+(TSWriter.defaultSegmentDuration+1)) {
            if let currentUrl = self.currentFileURL {
                let playlistUrl = base.appendingPathComponent("ScreenRecording.m3u8")
                self.files.append(M3UMediaInfo(url: currentUrl, duration: TSWriter.defaultSegmentDuration,  isDiscontinuous: false))
                FileManager.default.createFile(atPath: playlistUrl.path, contents: self.playlist.data(using: .utf8), attributes: nil)
                self.notifyDelegate(tsUrl: currentUrl, playlistUrl: playlistUrl)
            }
            self.currentFileURL = nil
            super.stopRunning()
        }
    }
    
    override func write(_ data: Data) {
        writeLockQueue.async {
            nstry({
                self.currentFileHandle?.write(data)
            }, { exception in
                logger.warn("\(exception)")
                let logs = exception.description
                self.writerError(TSWriterError.write, logs: logs)
            })
            super.write(data)
        }
    }

    public override func stopRunning() {
        guard !isRunning.value else {
            return
        }
        
        writeLockQueue.async {
            self.synchronizeAndCloseFile()
            self.currentFileHandle = nil
        }
        
        writeFinal()
    }

    func getFilePath(_ fileName: String) -> String? {
        files.first { $0.url.absoluteString.contains(fileName) }?.url.path
    }

    private func removeFiles() {
        for info in files {
            do {
                try FileManager.default.removeItem(at: info.url as URL)
            } catch {
                logger.warn(error)
                let logs = error.localizedDescription
                writerError(TSWriterError.removeItem, logs: logs)
            }
        }
        files.removeAll()
    }

    func mixerFormatLog(_ format: String) {
        self.delegate?.mixerFormatLog(format)
    }
    
    func writerError(_ error: TSWriterError, logs: String) {
        let error = NSError(domain: error.domain(), code: error.rawValue)
        self.delegate?.writerError(error, logs: logs)
    }
    
}
