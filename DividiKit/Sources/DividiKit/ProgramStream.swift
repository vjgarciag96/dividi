import Foundation

// Format-level view of the MPEG-2 program stream inside VOB files, as laid out by MPEG-2
// Systems and narrowed by DVD-Video: every pack fills exactly one Sector.

/// One PES packet's payload, with the timestamps its header carries.
struct PESPacket: Equatable {
  /// The elementary streams dividi demuxes.
  enum Stream: Hashable {
    case video
    /// An AC-3 audio stream, by its sub-stream number (0–7).
    case ac3(Int)
  }

  let stream: Stream
  /// Presentation time in 90 kHz ticks.
  let presentation: Int?
  /// Decoding time in 90 kHz ticks, present only when it differs from the presentation time.
  let decoding: Int?
  let payload: Data
}

enum ProgramStream {
  // Pack header:
  //
  //   0x00  4 bytes   00 00 01 BA
  //   0x04  6 bytes   '01' marker, then the system clock reference
  //   0x0A  3 bytes   mux rate
  //   0x0D  u8        bits 2–0 stuffing length
  //
  // Then packets until the pack ends, each:
  //
  //   0x00  3 bytes   00 00 01
  //   0x03  u8        stream id
  //   0x04  u16       length of the rest of the packet
  //
  // Stream ids: BB system header, BE padding, BF private stream 2 (navigation),
  // BD private stream 1 (AC-3, DTS, LPCM, subtitles), C0–C7 MPEG audio, E0 MPEG video.

  /// Splits one pack into the PES packets of the streams dividi demuxes, skipping navigation,
  /// padding and every other stream.
  static func packets(inPack pack: Data) throws(DemuxError) -> [PESPacket] {
    let bytes = [UInt8](pack)
    guard bytes.count >= 14, bytes[0...3] == [0x00, 0x00, 0x01, 0xBA], bytes[4] >> 6 == 0b01
    else { throw .invalidPack }

    var packets: [PESPacket] = []
    var offset = 14 + Int(bytes[13] & 0x07)
    while offset < bytes.count {
      guard offset + 6 <= bytes.count, bytes[offset..<offset + 3] == [0x00, 0x00, 0x01]
      else { throw .invalidPack }
      let end = offset + 6 + (Int(bytes[offset + 4]) << 8 | Int(bytes[offset + 5]))
      guard end <= bytes.count else { throw .invalidPack }
      switch bytes[offset + 3] {
      case 0xE0:
        let packet = try pesPacket(bytes[offset..<end])
        packets.append(
          PESPacket(
            stream: .video, presentation: packet.presentation, decoding: packet.decoding,
            payload: packet.payload))
      case 0xBD:
        if let packet = try privateStream1(pesPacket(bytes[offset..<end])) {
          packets.append(packet)
        }
      default:
        break
      }
      offset = end
    }
    return packets
  }

  // PES packet header, after the stream id and length:
  //
  //   0x06  u8        '10' marker, then flags
  //   0x07  u8        bits 7–6: 10 PTS only, 11 PTS and DTS
  //   0x08  u8        length of the optional fields that follow
  //   0x09  5 bytes   PTS, when present
  //   0x0E  5 bytes   DTS, when present
  //
  // The payload starts after the optional fields.
  private static func pesPacket(_ bytes: ArraySlice<UInt8>) throws(DemuxError) -> (
    presentation: Int?, decoding: Int?, payload: Data
  ) {
    let start = bytes.startIndex
    guard bytes.count >= 9, bytes[start + 6] >> 6 == 0b10 else { throw .invalidPack }
    let flags = bytes[start + 7] >> 6
    let hasPresentation = flags & 0b10 != 0
    let hasDecoding = flags == 0b11
    let payloadStart = start + 9 + Int(bytes[start + 8])
    let timestampsEnd = start + 9 + (hasPresentation ? 5 : 0) + (hasDecoding ? 5 : 0)
    guard timestampsEnd <= payloadStart, payloadStart <= bytes.endIndex else {
      throw .invalidPack
    }
    return (
      presentation: hasPresentation ? timestamp(bytes, at: start + 9) : nil,
      decoding: hasDecoding ? timestamp(bytes, at: start + 14) : nil,
      payload: Data(bytes[payloadStart...])
    )
  }

  // Private stream 1 payload:
  //
  //   0x00  u8        sub-stream: 20–3F subtitles, 80–87 AC-3, 88–8F DTS, A0–A7 LPCM
  //   0x01  u8        number of audio frames starting in this packet
  //   0x02  u16       offset of the first of them, from the byte after this field
  //
  // Only the AC-3 sub-streams are kept, without these 4 bytes.
  private static func privateStream1(
    _ packet: (presentation: Int?, decoding: Int?, payload: Data)
  ) -> PESPacket? {
    guard let substream = packet.payload.first, (0x80...0x87).contains(substream),
      packet.payload.count >= 4
    else { return nil }
    return PESPacket(
      stream: .ac3(Int(substream) - 0x80), presentation: packet.presentation,
      decoding: packet.decoding, payload: Data(packet.payload.dropFirst(4)))
  }

  /// A 33-bit timestamp in 5 bytes: a 4-bit marker, then 3, 15 and 15 bits each followed by a
  /// marker bit.
  private static func timestamp(_ bytes: ArraySlice<UInt8>, at offset: Int) -> Int {
    Int(bytes[offset] >> 1 & 0x07) << 30 | Int(bytes[offset + 1]) << 22
      | Int(bytes[offset + 2] >> 1) << 15 | Int(bytes[offset + 3]) << 7
      | Int(bytes[offset + 4] >> 1)
  }
}
