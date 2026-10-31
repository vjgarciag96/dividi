import Foundation

/// Turns a Title's Sectors into the MKV writer's input.
public enum Demuxer {
  /// Demuxes a Title's MPEG-2 video and its first AC-3 Track, playing its Cells in order.
  ///
  /// Timestamps start at zero and run on across Cells, even where the Disc's own jump or reset:
  /// each Cell starts where the one before ended. Navigation, subtitles and other audio Tracks
  /// are left out.
  public static func streams(of title: Title, from source: some SectorSource) throws -> (
    video: MKV.Video, audio: MKV.Audio
  ) {
    if let reason = title.unsupportedReason { throw DemuxError.unsupportedTitle(reason) }
    guard let track = title.audioTracks.first(where: { $0.codec == .ac3 }) else {
      throw DemuxError.noAC3Track
    }
    let vobs = TitleSetVOBs(titleSet: title.titleSet, source: source)

    var videoFormat: MPEG2Video.Format?
    var audioFormat: AC3.Format?
    var videoPackets: [MKV.Packet] = []
    var audioPackets: [MKV.Packet] = []
    var cellStart = 0
    for cell in title.cells {
      var packets: [PESPacket] = []
      for first in stride(
        from: cell.sectors.lowerBound, through: cell.sectors.upperBound, by: sectorsPerRead)
      {
        let sectors = first...min(first + sectorsPerRead - 1, cell.sectors.upperBound)
        let data = try vobs.readSectors(sectors)
        for pack in stride(from: 0, to: data.count, by: Sector.size) {
          packets += try ProgramStream.packets(inPack: data.subdata(in: pack..<pack + Sector.size))
        }
      }
      let video = try MPEG2Video.frames(in: packets.filter { $0.stream == .video })
      let audio = AC3.frames(in: packets.filter { $0.stream == .ac3(track.substream) })
      videoFormat = videoFormat ?? video.format
      audioFormat = audioFormat ?? audio.format

      // The Cell's own clock, from its earliest frame to the end of its latest.
      let frames = video.frames + audio.frames
      guard let first = frames.map(\.presentation).min(),
        let end = frames.map({ $0.presentation + $0.duration }).max()
      else { continue }
      func packet(_ frame: CodedFrame) -> MKV.Packet {
        MKV.Packet(
          bytes: frame.bytes, presentation: duration(cellStart + frame.presentation - first),
          duration: duration(frame.duration), isKeyframe: frame.isKeyframe)
      }
      videoPackets += video.frames.map(packet)
      audioPackets += audio.frames.map(packet)
      cellStart += end - first
    }

    guard let videoFormat else { throw DemuxError.missingSequenceHeader }
    guard let audioFormat else { throw DemuxError.noAudioFrames }
    return (
      MKV.Video(
        width: videoFormat.width, height: videoFormat.height,
        displayAspect: videoFormat.displayAspect, packets: videoPackets),
      MKV.Audio(
        sampleRate: audioFormat.sampleRate, channels: audioFormat.channels, packets: audioPackets)
    )
  }

  /// How many Sectors a Cell is read in at a time, so a whole Cell is never held twice.
  private static let sectorsPerRead = 512

  /// 90 kHz ticks as a `Duration`.
  private static func duration(_ ticks: Int) -> Duration {
    .microseconds(ticks * 100) / 9
  }
}

/// Why a Title's Sectors couldn't be demuxed into video and audio packets.
public enum DemuxError: Error, Equatable, Sendable {
  /// The Title is an Unsupported Title.
  case unsupportedTitle(UnsupportedReason)
  /// The Title has no AC-3 audio Track.
  case noAC3Track
  /// The Title's AC-3 Track has no whole sync frames.
  case noAudioFrames
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
