import Foundation

@testable import DividiKit

/// Builds synthetic AC-3 sync frames, laid out as ATSC A/52 specifies, without sharing any
/// code with the demuxer. Everything after the header is filler.
enum TestAC3 {
  /// A sync frame of `size` bytes, which the caller takes from A/52's frame size table for
  /// `sampleRateCode` (0 is 48 kHz, 2 is 32 kHz) and `frameSizeCode`. Coding mode 2 is stereo
  /// and 7 is 3 front and 2 surround channels.
  static func frame(
    sampleRateCode: Int = 0, frameSizeCode: Int, size: Int, codingMode: Int = 2,
    lfe: Bool = false, filler: UInt8 = 0xAA
  ) -> Data {
    // Mix levels and surround mode sit between the coding mode and the LFE bit.
    var mixBits = 0
    if codingMode & 1 != 0 && codingMode != 1 { mixBits += 2 }  // centre mix level
    if codingMode & 4 != 0 { mixBits += 2 }  // surround mix level
    if codingMode == 2 { mixBits += 2 }  // Dolby Surround mode
    var bytes: [UInt8] = [0x0B, 0x77, 0x00, 0x00]  // sync word, CRC
    bytes.append(UInt8(sampleRateCode << 6 | frameSizeCode))
    bytes.append(8 << 3)  // bitstream id 8, mode 0
    bytes.append(UInt8(codingMode << 5 | (lfe ? 1 : 0) << (4 - mixBits)))
    bytes += Array(repeating: filler, count: size - bytes.count)
    return Data(bytes)
  }
}

extension PESPacket {
  static func ac3(_ payload: Data, presentation: Int? = nil) -> PESPacket {
    PESPacket(stream: .ac3(0), presentation: presentation, decoding: nil, payload: payload)
  }
}
