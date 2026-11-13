import Foundation

/// Turns a Title's Sectors into the MKV writer's input.
public enum Demuxer {
  /// Demuxes a Title's MPEG-2 video and its first AC-3 Track, playing its Cells in order.
  ///
  /// Timestamps start at zero and run on across Cells, even where the Disc's own jump, reset or
  /// wrap: each Cell's pictures start where the previous Cell's ended, and its audio keeps its
  /// place against them. An audio frame cut off where a Cell ends is finished by the next Cell
  /// when that Cell follows it on the Disc. Navigation, subtitles and other audio Tracks are
  /// left out.
  public static func streams(of title: Title, from source: some SectorSource) throws -> (
    video: MKV.Video, audio: MKV.Audio
  ) {
    if let reason = title.unsupportedReason { throw DemuxError.unsupportedTitle(reason) }
    guard let track = title.audioTracks.first(where: { $0.codec == .ac3 }) else {
      throw DemuxError.noAC3Track
    }
    var vobs = TitleSetVOBs(titleSet: title.titleSet, source: source)

    var videoFormat: MPEG2Video.Format?
    var audioFormat: AC3.Format?
    // Frames on the Title's timeline, in ticks.
    var videoFrames: [CodedFrame] = []
    var audioFrames: [CodedFrame] = []
    var cellStart = 0
    var audioEnd = Int.min
    var unfinishedAudio: (after: Cell, packet: PESPacket)?
    for cell in title.cells {
      let packets = try packets(of: cell, from: &vobs)
      var audioPackets = packets.filter { $0.stream == .ac3(track.substream) }
      if let unfinishedAudio,
        unfinishedAudio.after.sectors.upperBound + 1 == cell.sectors.lowerBound
      {
        audioPackets.insert(unfinishedAudio.packet, at: 0)
      }
      let video = try MPEG2Video.frames(in: packets.filter { $0.stream == .video })
      let audio = AC3.frames(in: audioPackets)
      unfinishedAudio = (
        cell,
        PESPacket(
          stream: .ac3(track.substream), presentation: nil, decoding: nil,
          payload: audio.unfinished)
      )
      videoFormat = videoFormat ?? video.format
      audioFormat = audioFormat ?? audio.format

      // The Cell's own clock, read against its first frame so a wrap inside it runs on. Its
      // pictures, or its audio when it has none, place it on the Title's timeline.
      let timed = video.frames.isEmpty ? audio.frames : video.frames
      guard let reference = timed.first?.presentation else { continue }
      func clock(_ frame: CodedFrame) -> Int { unwrapped(frame.presentation - reference) }
      let first = timed.map(clock).min()!
      let end = timed.map { clock($0) + $0.duration }.max()!
      let offset = cellStart - first
      videoFrames += video.frames.map { $0.at(clock($0) + offset) }
      for frame in audio.frames {
        let presentation = clock(frame) + offset
        // Where the Disc jumps, a Cell's first audio can start under audio already placed.
        guard presentation + frame.duration / 2 >= audioEnd else { continue }
        audioFrames.append(frame.at(presentation))
        audioEnd = presentation + frame.duration
      }
      cellStart += end - first
    }

    guard let videoFormat else { throw DemuxError.missingSequenceHeader }
    guard let audioFormat else { throw DemuxError.noAudioFrames }
    let start = (videoFrames + audioFrames).map(\.presentation).min() ?? 0
    func packet(_ frame: CodedFrame) -> MKV.Packet {
      MKV.Packet(
        bytes: frame.bytes, presentation: duration(frame.presentation - start),
        duration: duration(frame.duration), isKeyframe: frame.isKeyframe)
    }
    return (
      MKV.Video(
        width: videoFormat.width, height: videoFormat.height,
        displayAspect: videoFormat.displayAspect, packets: videoFrames.map(packet)),
      MKV.Audio(
        sampleRate: audioFormat.sampleRate, channels: audioFormat.channels,
        packets: audioFrames.map(packet))
    )
  }

  /// The PES packets of a Cell's Sectors, read a piece at a time.
  private static func packets(of cell: Cell, from vobs: inout TitleSetVOBs) throws -> [PESPacket] {
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
    return packets
  }

  /// A difference between two 33-bit timestamps, taking the shorter way round.
  private static func unwrapped(_ ticks: Int) -> Int {
    let period = 1 << 33
    return ((ticks + period / 2) % period + period) % period - period / 2
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

extension DemuxError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .unsupportedTitle(.multiAngle): "the Title uses multiple angles, which isn't supported"
    case .unsupportedTitle(.seamlessBranching):
      "the Title uses seamless branching, which isn't supported"
    case .noAC3Track: "the Title has no AC-3 audio Track"
    case .noAudioFrames: "the Title's AC-3 Track has no audio in it"
    case .invalidPack: "a Sector of the Title isn't a valid MPEG-2 program stream pack"
    case .missingSequenceHeader: "the Title's video has no sequence header"
    case .unsupportedAspectRatio: "the Title's video is neither 4:3 nor 16:9"
    case .unsupportedFrameRate: "the Title's video has an unknown frame rate"
    }
  }
}

/// One coded picture or audio frame cut out of an elementary stream, timed in 90 kHz ticks.
struct CodedFrame: Equatable {
  let bytes: Data
  let presentation: Int
  let duration: Int
  let isKeyframe: Bool

  /// The same frame, presented at another time.
  func at(_ presentation: Int) -> CodedFrame {
    CodedFrame(bytes: bytes, presentation: presentation, duration: duration, isKeyframe: isKeyframe)
  }
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
