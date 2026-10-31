import Foundation

/// Why a Title's Sectors couldn't be demuxed into video and audio packets.
public enum DemuxError: Error, Equatable, Sendable {
  /// A Sector isn't a well-formed MPEG-2 program stream pack.
  case invalidPack
  /// The video has no sequence header, so its picture size is unknown.
  case missingSequenceHeader
  /// The video's display aspect ratio is neither 4:3 nor 16:9.
  case unsupportedAspectRatio
  /// The video's frame rate code isn't one MPEG-2 defines.
  case unsupportedFrameRate
}

/// One coded picture or audio frame cut out of an elementary stream, timed in 90 kHz ticks.
struct CodedFrame: Equatable {
  let bytes: Data
  let presentation: Int
  let duration: Int
  let isKeyframe: Bool
}

/// Where a packet's payload starts in the joined payloads, and its presentation time.
typealias PacketStart = (offset: Int, presentation: Int?)

/// The packets' payloads back to back, and where each one starts.
func joinedPayloads(of packets: [PESPacket]) -> (stream: [UInt8], packetStarts: [PacketStart]) {
  var stream: [UInt8] = []
  var packetStarts: [PacketStart] = []
  for packet in packets {
    packetStarts.append((stream.count, packet.presentation))
    stream += packet.payload
  }
  return (stream, packetStarts)
}

/// The presentation time of each frame starting at `offsets`, in order.
///
/// A packet's presentation time belongs to the first frame starting in it. Frames starting in a
/// packet without one, or after the first, have none.
func stamps(at offsets: [Int], packetStarts: [PacketStart]) -> [Int?] {
  var stamps: [Int?] = []
  var packet = 0
  var usedPacket: Int?
  for offset in offsets {
    while packet + 1 < packetStarts.count, packetStarts[packet + 1].offset <= offset {
      packet += 1
    }
    if usedPacket != packet, let presentation = packetStarts[packet].presentation {
      stamps.append(presentation)
      usedPacket = packet
    } else {
      stamps.append(nil)
    }
  }
  return stamps
}
