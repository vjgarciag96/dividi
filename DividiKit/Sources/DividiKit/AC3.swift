import Foundation

// Format-level view of an AC-3 elementary stream, as laid out by ATSC A/52.
//
// The stream is a run of sync frames, each 1536 samples, starting:
//
//   0x00  u16       sync word 0B 77
//   0x02  u16       CRC
//   0x04  u8        bits 7–6 sample rate code: 0 48 kHz, 1 44.1 kHz, 2 32 kHz
//                   bits 5–0 frame size code
//   0x05  u8        bits 7–3 bitstream id, 8 or less for AC-3
//   0x06  3 bits    coding mode: which channels are present
//         0–6 bits  mix levels and surround mode, depending on the coding mode
//         1 bit     LFE channel present

/// Cuts AC-3 audio into one frame per sync frame.
enum AC3 {
  /// What the first sync frame says about the audio.
  struct Format: Equatable {
    let sampleRate: Int
    /// Number of channels, counting the LFE channel.
    let channels: Int
  }

  /// Joins the packets' payloads and cuts them into frames.
  ///
  /// Bytes that aren't a whole sync frame, such as the tail of a frame cut off at the start,
  /// are dropped. A frame whose sync word starts in a packet with a presentation time takes it;
  /// others follow on from the frame before, or count back from the frame after. The format is
  /// `nil` when there are no frames.
  static func frames(in packets: [PESPacket]) -> (format: Format?, frames: [CodedFrame]) {
    let (stream, packetStarts) = joinedPayloads(of: packets)

    var format: Format?
    var frames: [(bytes: ArraySlice<UInt8>, header: Header)] = []
    var offset = 0
    while offset + 7 <= stream.count {
      guard let header = Header(stream, at: offset), offset + header.size <= stream.count else {
        offset += 1
        continue
      }
      format = format ?? Format(sampleRate: header.sampleRate, channels: header.channels)
      frames.append((stream[offset..<offset + header.size], header))
      offset += header.size
    }

    let stamped = stamps(at: frames.map(\.bytes.startIndex), packetStarts: packetStarts)
    var times: [Int] = []
    for (index, stamp) in stamped.enumerated() {
      let afterPrevious = index == 0 ? 0 : times[index - 1] + frames[index - 1].header.duration
      times.append(stamp ?? afterPrevious)
    }
    // Frames before the first stamped one count back from it.
    if let first = stamped.firstIndex(where: { $0 != nil }) {
      for index in stride(from: first - 1, through: 0, by: -1) {
        times[index] = times[index + 1] - frames[index].header.duration
      }
    }

    let coded = zip(frames, times).map { frame, time in
      CodedFrame(
        bytes: Data(frame.bytes), presentation: time, duration: frame.header.duration,
        isKeyframe: true)
    }
    return (format, coded)
  }

  private struct Header {
    let sampleRate: Int
    let channels: Int
    /// Bytes in the whole sync frame.
    let size: Int
    /// 1536 samples, in 90 kHz ticks.
    var duration: Int { (1536 * 90_000 + sampleRate / 2) / sampleRate }

    init?(_ stream: [UInt8], at offset: Int) {
      guard stream[offset] == 0x0B, stream[offset + 1] == 0x77, stream[offset + 5] >> 3 <= 8
      else { return nil }
      let frameSizeCode = Int(stream[offset + 4] & 0x3F)
      // The nominal bit rate, in kbps, for each pair of frame size codes.
      let bitRates = [
        32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 448, 512, 576, 640,
      ]
      guard frameSizeCode / 2 < bitRates.count else { return nil }
      let bitRate = bitRates[frameSizeCode / 2]
      // A frame is 1536 samples, so its size in 16-bit words follows from the bit rate. At
      // 44.1 kHz that isn't whole, so odd frame size codes round up.
      let words: Int
      switch stream[offset + 4] >> 6 {
      case 0:
        sampleRate = 48_000
        words = bitRate * 2
      case 1:
        sampleRate = 44_100
        words = bitRate * 2 * 48_000 / 44_100 + (frameSizeCode & 1)
      case 2:
        sampleRate = 32_000
        words = bitRate * 3
      default:
        return nil
      }
      size = 2 * words

      let codingMode = Int(stream[offset + 6] >> 5)
      var mixBits = 0
      if codingMode & 1 != 0 && codingMode != 1 { mixBits += 2 }  // centre mix level
      if codingMode & 4 != 0 { mixBits += 2 }  // surround mix level
      if codingMode == 2 { mixBits += 2 }  // Dolby Surround mode
      let lfe = Int(stream[offset + 6] >> (4 - mixBits) & 1)
      channels = [2, 1, 2, 3, 3, 4, 4, 5][codingMode] + lfe
    }
  }
}
