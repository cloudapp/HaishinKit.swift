import Foundation

/**
 - seealso: https://tools.ietf.org/html/draft-pantos-http-live-streaming-19
 */
public struct M3U {
    public static let header: String = "#EXTM3U"
    public static let defaultVersion: Int = 3
    
    var version: Int = M3U.defaultVersion
    var mediaList: [M3UMediaInfo] = []
    public  var mediaSequence: Int = 0
    public var targetDuration: Double = 5
    public init() {
        
    }
}

extension M3U: CustomStringConvertible {
    // MARK: CustomStringConvertible
   public var description: String {
        var lines: [String] = [
            "#EXTM3U",
            "#EXT-X-VERSION:\(version)",
            "#EXT-X-MEDIA-SEQUENCE:\(mediaSequence)",
            "#EXT-X-TARGETDURATION:\(Int(targetDuration))"
        ]
        for info in mediaList {
          if info.isSkipped ?? false {
                  continue
                }
                if info.isDiscontinuous {
                  lines.append("#EXT-X-DISCONTINUITY")
                }
                      lines.append("#EXTINF:\(info.duration),")
                      lines.append(info.url.pathComponents.last!)
          
        }
        return lines.joined(separator: "\r\n")
    }
}

// MARK: -
struct M3UMediaInfo {
    let url: URL
    let duration: Double
    var isDiscontinuous: Bool
    var isSkipped: Bool?
}
