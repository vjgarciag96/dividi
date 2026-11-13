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

extension TestMPEG2Video {
  /// Turns progressive 23.976 fps film into a 29.97 fps interlaced sequence by soft telecine, as
  /// DVD authoring does: each picture is flagged to be shown for 3, 2, 3, 2 … fields in display
  /// order, alternating which field comes first, without touching the coded pictures.
  static func softTelecine(_ film: Data) -> Data {
    var bytes = [UInt8](film)
    var groupStart = 0
    var groupLength = 0
    var displayIndex = 0
    var index = 0
    while index + 8 < bytes.count {
      guard bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 else {
        index += 1
        continue
      }
      switch (bytes[index + 3], bytes[index + 4] >> 4) {
      case (0xB3, _):  // sequence header: frame rate code 4, 29.97 fps
        bytes[index + 7] = bytes[index + 7] & 0xF0 | 4
      case (0xB8, _):  // group of pictures
        groupStart += groupLength
        groupLength = 0
      case (0x00, _):  // picture header: temporal reference
        let temporalReference = Int(bytes[index + 4]) << 2 | Int(bytes[index + 5] >> 6)
        groupLength = max(groupLength, temporalReference + 1)
        displayIndex = groupStart + temporalReference
      case (0xB5, 1):  // sequence extension: not a progressive sequence
        bytes[index + 5] &= ~0x08
      case (0xB5, 8):  // picture coding extension: top field first, repeat first field
        let (topFieldFirst, repeatFirstField) = [
          (true, true), (false, false), (false, true), (true, false),
        ][
          displayIndex % 4]
        bytes[index + 7] =
          bytes[index + 7] & ~0x82 | (topFieldFirst ? 0x80 : 0) | (repeatFirstField ? 0x02 : 0)
        bytes[index + 8] |= 0x80  // progressive frame
      default:
        break
      }
      index += 3
    }
    return Data(bytes)
  }
}

extension PESPacket {
  static func video(_ payload: Data, presentation: Int? = nil) -> PESPacket {
    PESPacket(stream: .video, presentation: presentation, decoding: nil, payload: payload)
  }
}
