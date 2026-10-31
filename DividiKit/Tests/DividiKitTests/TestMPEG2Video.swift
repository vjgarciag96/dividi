import Foundation

@testable import DividiKit

/// Builds the headers of a synthetic MPEG-2 video elementary stream, laid out as MPEG-2 Video
/// specifies, without sharing any code with the demuxer. Slices are filler bytes.
enum TestMPEG2Video {
  /// Aspect code 2 is 4:3 and 3 is 16:9; frame rate code 3 is 25 fps and 4 is 29.97 fps.
  static func sequenceHeader(
    width: Int = 720, height: Int = 576, aspect: Int = 2, rate: Int = 3, progressive: Bool = true
  ) -> Data {
    var bytes: [UInt8] = [0x00, 0x00, 0x01, 0xB3]
    bytes += [UInt8(width >> 4), UInt8(width & 0x0F) << 4 | UInt8(height >> 8)]
    bytes += [UInt8(height & 0xFF), UInt8(aspect << 4 | rate)]
    bytes += [0xFF, 0xFF, 0xE0, 0x00]  // bit rate, marker, buffer size, flags
    bytes += [0x00, 0x00, 0x01, 0xB5, 0x14, progressive ? 0x8A : 0x82]  // sequence extension
    bytes += [0x00, 0x01, 0x00, 0x00]
    return Data(bytes)
  }

  static func groupOfPictures() -> Data {
    Data([0x00, 0x00, 0x01, 0xB8, 0x00, 0x08, 0x00, 0x00])
  }

  struct Coding {
    /// 1 is a top field, 2 a bottom field and 3 a frame.
    var structure = 3
    var topFieldFirst = true
    var repeatFirstField = false
  }

  /// Coding type 1 is I, 2 is P and 3 is B.
  static func picture(
    temporalReference: Int, type: Int, coding: Coding? = nil, filler: UInt8 = 0xAA
  ) -> Data {
    var bytes: [UInt8] = [0x00, 0x00, 0x01, 0x00]
    bytes += [
      UInt8(temporalReference >> 2), UInt8(temporalReference & 0x03) << 6 | UInt8(type << 3),
    ]
    bytes += [0xFF, 0xF8]  // VBV delay, then the vector codes
    if let coding {
      bytes += [0x00, 0x00, 0x01, 0xB5, 0x8F, 0xFF]  // extension id, then motion vector codes
      bytes += [0xF0 | UInt8(coding.structure)]  // motion vector codes, DC precision, structure
      bytes += [
        (coding.topFieldFirst ? 0x80 : 0) | (coding.repeatFirstField ? 0x02 : 0) | 0x01 as UInt8,
        0x80,  // progressive frame
      ]
    }
    bytes += [0x00, 0x00, 0x01, 0x01]  // slice 1
    bytes += Array(repeating: filler, count: 8)
    return Data(bytes)
  }
}

extension PESPacket {
  static func video(_ payload: Data, presentation: Int? = nil) -> PESPacket {
    PESPacket(stream: .video, presentation: presentation, decoding: nil, payload: payload)
  }
}
