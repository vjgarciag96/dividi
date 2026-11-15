import Foundation

/// Takes the packets the demuxer hands over, each track's in decode order.
protocol PacketSink {
  mutating func append(_ packet: MKV.Packet, to stream: MKVError.Stream) throws
}

extension MKV.Writer: PacketSink {}

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
    var formats: (video: MKV.VideoFormat, audio: MKV.AudioFormat)?
    let collected = try demux(title, from: source) { video, audio in
      formats = (video, audio)
      return Collector()
    }
    let (video, audio) = formats!
    return (
      MKV.Video(
        width: video.width, height: video.height, displayAspect: video.displayAspect,
        packets: collected.video),
      MKV.Audio(sampleRate: audio.sampleRate, channels: audio.channels, packets: collected.audio)
    )
  }

  /// Demuxes a Title as `streams(of:from:)` does, handing its packets over as it reads them.
  ///
  /// A Cell is read in pieces of at least `minimumPieceBytes` of payload, cut where a group of
  /// pictures starts a stamped video packet, so each piece's pictures cut and time on their own.
  /// Once both tracks have a frame, `start` gets their formats and makes the sink; from then on
  /// each piece's packets go to the sink before the next piece is read. `progress` gets the
  /// fraction of the Title's Sectors read after each read.
  static func demux<Sink: PacketSink>(
    _ title: Title, from source: some SectorSource, minimumPieceBytes: Int = pieceBytes,
    progress: (Double) -> Void = { _ in },
    into start: (MKV.VideoFormat, MKV.AudioFormat) throws -> Sink
  ) throws -> Sink {
    if let reason = title.unsupportedReason { throw DemuxError.unsupportedTitle(reason) }
    guard let track = title.audioTracks.first(where: { $0.codec == .ac3 }) else {
      throw DemuxError.noAC3Track
    }
    var vobs = TitleSetVOBs(titleSet: title.titleSet, source: source)
    let titleSectors = title.cells.reduce(0) { $0 + $1.sectors.count }
    var sectorsRead = 0

    var videoFormat: MPEG2Video.Format?
    var audioFormat: AC3.Format?
    var sink: Sink?
    // Frames on the Title's timeline, in ticks, held until both tracks have one, so the
    // earliest of them can be made zero.
    var held: [(stream: MKVError.Stream, frame: CodedFrame)] = []
    var heldTracks: Set<MKVError.Stream> = []
    var zero = 0

    func makeSink() throws {
      guard let videoFormat else { throw DemuxError.missingSequenceHeader }
      guard let audioFormat else { throw DemuxError.noAudioFrames }
      zero = held.map(\.frame.presentation).min() ?? 0
      var made = try start(
        MKV.VideoFormat(
          width: videoFormat.width, height: videoFormat.height,
          displayAspect: videoFormat.displayAspect),
        MKV.AudioFormat(sampleRate: audioFormat.sampleRate, channels: audioFormat.channels))
      for (stream, frame) in held { try made.append(packet(frame), to: stream) }
      held = []
      sink = made
    }
    func place(_ frame: CodedFrame, on stream: MKVError.Stream) throws {
      if sink != nil {
        try sink!.append(packet(frame), to: stream)
        return
      }
      held.append((stream, frame))
      heldTracks.insert(stream)
      if heldTracks.count == 2 { try makeSink() }
    }
    func packet(_ frame: CodedFrame) -> MKV.Packet {
      MKV.Packet(
        bytes: frame.bytes, presentation: duration(frame.presentation - zero),
        duration: duration(frame.duration), isKeyframe: frame.isKeyframe)
    }

    func count(_ sectors: Int) {
      sectorsRead += sectors
      progress(Double(sectorsRead) / Double(max(titleSectors, 1)))
    }

    var cellStart = 0
    var audioEnd = Int.min
    var unfinishedAudio: (after: Cell, bytes: Data)?
    for cell in title.cells {
      var carriedAudio = Data()
      if let unfinishedAudio,
        unfinishedAudio.after.sectors.upperBound + 1 == cell.sectors.lowerBound
      {
        carriedAudio = unfinishedAudio.bytes
      }
      // The Cell's own clock, read against its first frame so a wrap inside it runs on. Its
      // pictures, or its audio when it has none, place it on the Title's timeline.
      var clock: (reference: Int, first: Int, byVideo: Bool)?
      var end = Int.min
      try forEachPiece(of: cell, from: &vobs, minimumPieceBytes: minimumPieceBytes, read: count) {
        packets in
        var audioPackets = packets.filter { $0.stream == .ac3(track.substream) }
        if !carriedAudio.isEmpty {
          audioPackets.insert(
            PESPacket(
              stream: .ac3(track.substream), presentation: nil, decoding: nil,
              payload: carriedAudio), at: 0)
        }
        let video = try MPEG2Video.frames(in: packets.filter { $0.stream == .video })
        let audio = AC3.frames(in: audioPackets)
        carriedAudio = audio.unfinished
        videoFormat = videoFormat ?? video.format
        audioFormat = audioFormat ?? audio.format

        if clock == nil {
          let byVideo = !video.frames.isEmpty
          let timed = byVideo ? video.frames : audio.frames
          guard let reference = timed.first?.presentation else { return }
          let first = timed.map { unwrapped($0.presentation - reference) }.min()!
          clock = (reference, first, byVideo)
        }
        let (reference, first, byVideo) = clock!
        func time(_ frame: CodedFrame) -> Int { unwrapped(frame.presentation - reference) }
        let offset = cellStart - first
        for frame in byVideo ? video.frames : audio.frames {
          end = max(end, time(frame) + frame.duration)
        }
        for frame in video.frames { try place(frame.at(time(frame) + offset), on: .video) }
        for frame in audio.frames {
          let presentation = time(frame) + offset
          // Where the Disc jumps, a Cell's first audio can start under audio already placed.
          guard presentation + frame.duration / 2 >= audioEnd else { continue }
          try place(frame.at(presentation), on: .audio)
          audioEnd = presentation + frame.duration
        }
      }
      unfinishedAudio = (cell, carriedAudio)
      if let clock { cellStart += end - clock.first }
    }

    if sink == nil { try makeSink() }
    return sink!
  }

  /// A Cell's PES packets, a piece at a time.
  ///
  /// A piece ends once it holds `minimumPieceBytes` of payload and has started a group of
  /// pictures, just before the next group starts, so no picture or group is split. A Cell whose
  /// groups don't start packets is one piece. `read` gets the number of Sectors read each time.
  private static func forEachPiece(
    of cell: Cell, from vobs: inout TitleSetVOBs, minimumPieceBytes: Int,
    read: (Int) -> Void, _ body: ([PESPacket]) throws -> Void
  ) throws {
    var piece: [PESPacket] = []
    var pieceBytes = 0
    var pieceStartsGroup = false
    for first in stride(
      from: cell.sectors.lowerBound, through: cell.sectors.upperBound, by: sectorsPerRead)
    {
      let sectors = first...min(first + sectorsPerRead - 1, cell.sectors.upperBound)
      let data = try vobs.readSectors(sectors)
      read(sectors.count)
      for pack in stride(from: 0, to: data.count, by: Sector.size) {
        for packet in try ProgramStream.packets(inPack: data.subdata(in: pack..<pack + Sector.size))
        {
          let startsGroup = startsGroupOfPictures(packet)
          if startsGroup, pieceStartsGroup, pieceBytes >= minimumPieceBytes {
            try body(piece)
            piece = []
            pieceBytes = 0
          }
          piece.append(packet)
          pieceBytes += packet.payload.count
          pieceStartsGroup = pieceStartsGroup || startsGroup
        }
      }
    }
    try body(piece)
  }

  /// Whether a video packet starts with a sequence header and has a presentation time, as each
  /// DVD video object unit's first video packet does.
  private static func startsGroupOfPictures(_ packet: PESPacket) -> Bool {
    packet.stream == .video && packet.presentation != nil
      && packet.payload.starts(with: [0x00, 0x00, 0x01, 0xB3])
  }

  /// A difference between two 33-bit timestamps, taking the shorter way round.
  private static func unwrapped(_ ticks: Int) -> Int {
    let period = 1 << 33
    return ((ticks + period / 2) % period + period) % period - period / 2
  }

  /// How many Sectors a Cell is read in at a time, so a whole Cell is never held twice.
  private static let sectorsPerRead = 512

  /// The least payload a piece of a Cell holds before it's demuxed, about 1 MB: a second or two
  /// of DVD video, a few groups of pictures.
  static let pieceBytes = 1 << 20

  /// 90 kHz ticks as a `Duration`.
  private static func duration(_ ticks: Int) -> Duration {
    .microseconds(ticks * 100) / 9
  }

  /// Keeps every packet, for `streams(of:from:)`.
  private struct Collector: PacketSink {
    var video: [MKV.Packet] = []
    var audio: [MKV.Packet] = []

    mutating func append(_ packet: MKV.Packet, to stream: MKVError.Stream) {
      switch stream {
      case .video: video.append(packet)
      case .audio: audio.append(packet)
      }
    }
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
  /// A Cell runs past the end of its Title Set's last VOB, at this Sector of the Title Set:
  /// the IFO is broken or the copy is truncated.
  case pastEndOfTitleSet(titleSet: Int, sector: Int)
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
    case .pastEndOfTitleSet(let titleSet, let sector):
      "the Title runs past the end of Title Set \(titleSet)'s VOB files, at Sector \(sector); "
        + "the copy may be incomplete"
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
