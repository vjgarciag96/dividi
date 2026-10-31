import DividiKit
import Foundation

/// Builds the packs of a synthetic DVD program stream, one Sector each, laid out as
/// MPEG-2 Systems and DVD-Video specify, without sharing any code with the demuxer.
enum TestPack {
  /// A pack holding the PES packets, padded to a whole Sector.
  static func pack(_ packets: [TestPES]) -> Data {
    var pack = header()
    for packet in packets { pack += packet.bytes() }
    precondition(pack.count + 6 <= Sector.size, "the PES packets don't fit in one pack")
    pack += pes(streamID: 0xBE, header: [], payload: Data(count: Sector.size - pack.count - 6))
    return pack
  }

  /// A navigation pack: a system header, then the PCI and DSI private stream 2 packets.
  static func navigation() -> Data {
    var pack = header()
    pack += pes(streamID: 0xBB, header: [], payload: Data(count: 18))  // system header
    pack += pes(streamID: 0xBF, header: [], payload: Data([0x00]) + Data(count: 979))  // PCI
    pack += pes(streamID: 0xBF, header: [], payload: Data([0x01]) + Data(count: 1017))  // DSI
    precondition(pack.count == Sector.size)
    return pack
  }

  private static func header() -> Data {
    var header = Data([0x00, 0x00, 0x01, 0xBA])  // pack start code
    header += [0x44, 0x00, 0x04, 0x00, 0x04, 0x01]  // '01' marker, SCR 0
    header += [0x01, 0x89, 0xC3]  // mux rate
    header += [0xF8]  // reserved | no stuffing
    return header
  }
}

/// A PES packet inside a pack.
struct TestPES {
  /// 0xE0 MPEG video, 0xBD private stream 1, 0xC0 MPEG audio.
  var streamID: UInt8 = 0xE0
  /// For private stream 1: 0x80–0x87 AC-3, 0x20–0x3F subtitles.
  var substream: UInt8? = nil
  /// In 90 kHz ticks.
  var presentation: Int? = nil
  var decoding: Int? = nil
  var payload = Data()

  fileprivate func bytes() -> Data {
    var header: [UInt8] = []
    if let presentation {
      header += timestamp(presentation, marker: decoding == nil ? 0b0010 : 0b0011)
    }
    if let decoding { header += timestamp(decoding, marker: 0b0001) }
    var body = Data()
    if let substream {
      body += [substream, 0x01, 0x00, 0x01]  // substream | frame count | first access unit
    }
    body += payload
    let flags: UInt8 = presentation == nil ? 0 : decoding == nil ? 0x80 : 0xC0
    return pes(
      streamID: streamID, header: [0x81, flags, UInt8(header.count)] + header, payload: body)
  }

  /// A 33-bit timestamp in 5 bytes: a 4-bit marker, then 3, 15 and 15 bits each followed by 1.
  private func timestamp(_ ticks: Int, marker: UInt8) -> [UInt8] {
    [
      marker << 4 | UInt8(ticks >> 29 & 0x0E) | 1,
      UInt8(ticks >> 22 & 0xFF),
      UInt8(ticks >> 14 & 0xFE) | 1,
      UInt8(ticks >> 7 & 0xFF),
      UInt8(ticks << 1 & 0xFE) | 1,
    ]
  }
}

/// A packet with a start code, stream id and length, followed by its header and payload.
private func pes(streamID: UInt8, header: [UInt8], payload: Data) -> Data {
  let length = header.count + payload.count
  return Data([0x00, 0x00, 0x01, streamID, UInt8(length >> 8), UInt8(length & 0xFF)]) + header
    + payload
}
