import Foundation

// The MKV for one Extraction. EBML element ids stay in this file so a demuxer
// cannot write a second container. ByteReader stays the IFO reader.

/// One Extraction's MPEG-2 video and AC-3 audio, remuxed into an MKV.
///
/// `data(video:audio:)` is pure. The same inputs return the same bytes. Payloads
/// are copied. The caller keeps any file path.
public enum MKV: Sendable {
  /// Elementary-stream bytes and the time they are presented, counted from the
  /// start of the Extraction. The same `Duration` a Title uses.
  public struct Packet: Equatable, Sendable {
    public let bytes: Data
    /// Presentation time from the start of the Extraction.
    public let presentation: Duration
  }

  /// MPEG-2 elementary stream for one Extraction.
  public struct Video: Equatable, Sendable {
    /// Coded width, in pixels.
    public let width: Int
    /// Coded height, in pixels.
    public let height: Int
    public let displayAspect: DisplayAspect
    public let packets: [Packet]

    /// Display aspect stored as Matroska DisplayWidth and DisplayHeight.
    public enum DisplayAspect: Equatable, Sendable {
      case fourByThree
      case sixteenByNine

      /// Numerator and denominator written with DisplayUnit set to aspect ratio.
      fileprivate var ratio: (width: Int, height: Int) {
        switch self {
        case .fourByThree: (4, 3)
        case .sixteenByNine: (16, 9)
        }
      }
    }
  }

  /// AC-3 elementary stream for one Extraction.
  ///
  /// An `AudioTrack` is a stream the Disc offers. The caller has already chosen
  /// one and split its packets into this value.
  public struct Audio: Equatable, Sendable {
    public let sampleRate: Int
    public let channels: Int
    public let packets: [Packet]
  }

  /// Remuxes one video stream and one audio stream into MKV bytes.
  public static func data(video: Video, audio: Audio) throws(MKVError) -> Data {
    let timeline = try Timeline.make(video: video, audio: audio)
    return EBML.encode(timeline)
  }
}

/// Why an Extraction could not be written as an MKV.
public enum MKVError: Error, Equatable, Sendable {
  /// Which input failed.
  public enum Stream: Equatable, Sendable {
    case video
    case audio
  }

  /// A width, height, sample rate, or channel count.
  public enum Field: Equatable, Sendable {
    case width
    case height
    case sampleRate
    case channels
  }

  /// That input has no packets.
  case emptyPackets(Stream)
  /// A packet's presentation time is negative.
  case negativePresentation(Stream)
  /// A packet's presentation time is earlier than the previous packet of that input.
  case backwardsPresentation(Stream)
  /// That field is zero or negative.
  case nonPositive(Field)
}

extension MKVError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .emptyPackets(.video): "the video has no packets"
    case .emptyPackets(.audio): "the audio has no packets"
    case .negativePresentation(.video): "a video packet's presentation time is negative"
    case .negativePresentation(.audio): "an audio packet's presentation time is negative"
    case .backwardsPresentation(.video): "a video packet's presentation time moves backwards"
    case .backwardsPresentation(.audio): "an audio packet's presentation time moves backwards"
    case .nonPositive(.width): "the picture width is zero or negative"
    case .nonPositive(.height): "the picture height is zero or negative"
    case .nonPositive(.sampleRate): "the sample rate is zero or negative"
    case .nonPositive(.channels): "the channel count is zero or negative"
    }
  }
}

private enum TimestampScale {
  static let nanoseconds: UInt64 = 1_000_000
  static let maxRelativeTick: UInt64 = 32_767
}

private enum StreamSlot {
  case video
  case audio

  var trackNumber: UInt64 {
    switch self {
    case .video: 1
    case .audio: 2
    }
  }

  var trackType: UInt64 {
    switch self {
    case .video: 1
    case .audio: 2
    }
  }

  var codecID: String {
    switch self {
    case .video: "V_MPEG2"
    case .audio: "A_AC3"
    }
  }
}

private enum Container {
  static let docType = "matroska"
  static let docTypeVersion: UInt64 = 2
  static let docTypeReadVersion: UInt64 = 2
  /// DisplayUnit 3 means DisplayWidth and DisplayHeight are an aspect ratio.
  static let displayUnitAspectRatio: UInt64 = 3
  static let writerName = "dividi"
}

/// SimpleBlock flag byte. Bit 7 is the keyframe. Every block sets it because
/// payloads are copied and this writer does not look for an MPEG-2 I-frame.
private enum SimpleBlockHeader {
  static let flags: UInt8 = 0x80
}

private struct Timeline {
  var width: Int
  var height: Int
  var displayAspect: MKV.Video.DisplayAspect
  var sampleRate: Int
  var channels: Int
  var clusters: [Cluster]
  var durationTicks: UInt64

  private struct Pending {
    var slot: StreamSlot
    var tick: UInt64
    var bytes: Data
  }

  static func make(video: MKV.Video, audio: MKV.Audio) throws(MKVError) -> Timeline {
    guard video.width > 0 else { throw .nonPositive(.width) }
    guard video.height > 0 else { throw .nonPositive(.height) }
    guard audio.sampleRate > 0 else { throw .nonPositive(.sampleRate) }
    guard audio.channels > 0 else { throw .nonPositive(.channels) }
    guard !video.packets.isEmpty else { throw .emptyPackets(.video) }
    guard !audio.packets.isEmpty else { throw .emptyPackets(.audio) }

    let videoPackets = try timed(video.packets, slot: .video, stream: .video)
    let audioPackets = try timed(audio.packets, slot: .audio, stream: .audio)
    let merged = merge(video: videoPackets, audio: audioPackets)
    return Timeline(
      width: video.width,
      height: video.height,
      displayAspect: video.displayAspect,
      sampleRate: audio.sampleRate,
      channels: audio.channels,
      clusters: clusters(merged),
      durationTicks: merged[merged.count - 1].tick)
  }

  private static func timed(
    _ packets: [MKV.Packet], slot: StreamSlot, stream: MKVError.Stream
  ) throws(MKVError) -> [Pending] {
    var previous: Duration?
    var pending: [Pending] = []
    pending.reserveCapacity(packets.count)
    for packet in packets {
      if packet.presentation < .zero {
        throw .negativePresentation(stream)
      }
      if let previous, packet.presentation < previous {
        throw .backwardsPresentation(stream)
      }
      pending.append(
        Pending(slot: slot, tick: ticks(packet.presentation), bytes: packet.bytes))
      previous = packet.presentation
    }
    return pending
  }

  private static func ticks(_ presentation: Duration) -> UInt64 {
    let (seconds, attoseconds) = presentation.components
    // seconds * 1_000, not seconds * 10^18. Multiplying by 10^18 overflows Int64 past 9 seconds.
    let whole = UInt64(seconds) * 1_000
    let fraction = attoseconds / 1_000_000_000_000_000
    var ticks = whole + UInt64(fraction)
    if attoseconds % 1_000_000_000_000_000 >= 500_000_000_000_000 {
      ticks += 1
    }
    return ticks
  }

  private static func merge(video: [Pending], audio: [Pending]) -> [Pending] {
    var merged: [Pending] = []
    merged.reserveCapacity(video.count + audio.count)
    var videoIndex = 0
    var audioIndex = 0
    while videoIndex < video.count && audioIndex < audio.count {
      if video[videoIndex].tick <= audio[audioIndex].tick {
        merged.append(video[videoIndex])
        videoIndex += 1
      } else {
        merged.append(audio[audioIndex])
        audioIndex += 1
      }
    }
    merged.append(contentsOf: video[videoIndex...])
    merged.append(contentsOf: audio[audioIndex...])
    return merged
  }

  private static func clusters(_ packets: [Pending]) -> [Cluster] {
    var clusters: [Cluster] = []
    var timestamp = packets[0].tick
    var blocks: [Block] = []
    for packet in packets {
      if packet.tick - timestamp > TimestampScale.maxRelativeTick {
        clusters.append(Cluster(timestampTicks: timestamp, blocks: blocks))
        timestamp = packet.tick
        blocks = []
      }
      let relative = packet.tick - timestamp
      blocks.append(Block(slot: packet.slot, relativeTicks: Int16(relative), bytes: packet.bytes))
    }
    clusters.append(Cluster(timestampTicks: timestamp, blocks: blocks))
    return clusters
  }
}

private struct Cluster {
  var timestampTicks: UInt64
  var blocks: [Block]
}

private struct Block {
  var slot: StreamSlot
  var relativeTicks: Int16
  var bytes: Data
}

private enum ElementID {
  static let ebml: [UInt8] = [0x1A, 0x45, 0xDF, 0xA3]
  static let ebmlVersion: [UInt8] = [0x42, 0x86]
  static let ebmlReadVersion: [UInt8] = [0x42, 0xF7]
  static let ebmlMaxIDLength: [UInt8] = [0x42, 0xF2]
  static let ebmlMaxSizeLength: [UInt8] = [0x42, 0xF3]
  static let docType: [UInt8] = [0x42, 0x82]
  static let docTypeVersion: [UInt8] = [0x42, 0x87]
  static let docTypeReadVersion: [UInt8] = [0x42, 0x85]
  static let segment: [UInt8] = [0x18, 0x53, 0x80, 0x67]
  static let info: [UInt8] = [0x15, 0x49, 0xA9, 0x66]
  static let timestampScale: [UInt8] = [0x2A, 0xD7, 0xB1]
  static let duration: [UInt8] = [0x44, 0x89]
  static let muxingApp: [UInt8] = [0x4D, 0x80]
  static let writingApp: [UInt8] = [0x57, 0x41]
  static let tracks: [UInt8] = [0x16, 0x54, 0xAE, 0x6B]
  static let trackEntry: [UInt8] = [0xAE]
  static let trackNumber: [UInt8] = [0xD7]
  static let trackUID: [UInt8] = [0x73, 0xC5]
  static let trackType: [UInt8] = [0x83]
  static let flagLacing: [UInt8] = [0x9C]
  static let codecID: [UInt8] = [0x86]
  static let video: [UInt8] = [0xE0]
  static let pixelWidth: [UInt8] = [0xB0]
  static let pixelHeight: [UInt8] = [0xBA]
  static let displayWidth: [UInt8] = [0x54, 0xB0]
  static let displayHeight: [UInt8] = [0x54, 0xBA]
  static let displayUnit: [UInt8] = [0x54, 0xB2]
  static let audio: [UInt8] = [0xE1]
  static let samplingFrequency: [UInt8] = [0xB5]
  static let channels: [UInt8] = [0x9F]
  static let cluster: [UInt8] = [0x1F, 0x43, 0xB6, 0x75]
  static let timestamp: [UInt8] = [0xE7]
  static let simpleBlock: [UInt8] = [0xA3]
}

private enum EBML {
  static func encode(_ timeline: Timeline) -> Data {
    var buffer = Buffer()
    buffer.master(ElementID.ebml) { header in
      header.uint(ElementID.ebmlVersion, 1)
      header.uint(ElementID.ebmlReadVersion, 1)
      header.uint(ElementID.ebmlMaxIDLength, 4)
      header.uint(ElementID.ebmlMaxSizeLength, 8)
      header.string(ElementID.docType, Container.docType)
      header.uint(ElementID.docTypeVersion, Container.docTypeVersion)
      header.uint(ElementID.docTypeReadVersion, Container.docTypeReadVersion)
    }
    buffer.master(ElementID.segment) { segment in
      segment.master(ElementID.info) { info in
        info.uint(ElementID.timestampScale, TimestampScale.nanoseconds)
        info.float(ElementID.duration, Double(timeline.durationTicks))
        info.string(ElementID.muxingApp, Container.writerName)
        info.string(ElementID.writingApp, Container.writerName)
      }
      segment.master(ElementID.tracks) { tracks in
        tracks.master(ElementID.trackEntry) { entry in
          entry.uint(ElementID.trackNumber, StreamSlot.video.trackNumber)
          entry.uint(ElementID.trackUID, StreamSlot.video.trackNumber)
          entry.uint(ElementID.trackType, StreamSlot.video.trackType)
          entry.uint(ElementID.flagLacing, 0)
          entry.string(ElementID.codecID, StreamSlot.video.codecID)
          entry.master(ElementID.video) { video in
            video.uint(ElementID.pixelWidth, UInt64(timeline.width))
            video.uint(ElementID.pixelHeight, UInt64(timeline.height))
            let ratio = timeline.displayAspect.ratio
            video.uint(ElementID.displayWidth, UInt64(ratio.width))
            video.uint(ElementID.displayHeight, UInt64(ratio.height))
            video.uint(ElementID.displayUnit, Container.displayUnitAspectRatio)
          }
        }
        tracks.master(ElementID.trackEntry) { entry in
          entry.uint(ElementID.trackNumber, StreamSlot.audio.trackNumber)
          entry.uint(ElementID.trackUID, StreamSlot.audio.trackNumber)
          entry.uint(ElementID.trackType, StreamSlot.audio.trackType)
          entry.uint(ElementID.flagLacing, 0)
          entry.string(ElementID.codecID, StreamSlot.audio.codecID)
          entry.master(ElementID.audio) { audio in
            audio.float(ElementID.samplingFrequency, Double(timeline.sampleRate))
            audio.uint(ElementID.channels, UInt64(timeline.channels))
          }
        }
      }
      for cluster in timeline.clusters {
        segment.master(ElementID.cluster) { body in
          body.uint(ElementID.timestamp, cluster.timestampTicks)
          for block in cluster.blocks {
            body.simpleBlock(block)
          }
        }
      }
    }
    return buffer.data
  }

  private struct Buffer {
    var data = Data()

    mutating func master(_ id: [UInt8], _ build: (inout Buffer) -> Void) {
      var child = Buffer()
      build(&child)
      element(id, child.data)
    }

    mutating func uint(_ id: [UInt8], _ value: UInt64) {
      element(id, Self.unsigned(value))
    }

    mutating func float(_ id: [UInt8], _ value: Double) {
      element(id, Self.float64(value))
    }

    mutating func string(_ id: [UInt8], _ value: String) {
      element(id, Data(value.utf8))
    }

    mutating func simpleBlock(_ block: Block) {
      var body = Data()
      body.append(contentsOf: Self.vint(block.slot.trackNumber))
      let relative = UInt16(bitPattern: block.relativeTicks)
      body.append(UInt8(relative >> 8))
      body.append(UInt8(truncatingIfNeeded: relative))
      body.append(SimpleBlockHeader.flags)
      body.append(block.bytes)
      element(ElementID.simpleBlock, body)
    }

    private mutating func element(_ id: [UInt8], _ body: Data) {
      data.append(contentsOf: id)
      data.append(contentsOf: Self.vint(UInt64(body.count)))
      data.append(body)
    }

    /// The all-ones vint is reserved for an unknown size, so width w stops at 2^(7w) - 2.
    private static func vint(_ value: UInt64) -> [UInt8] {
      var width = 1
      while value > (UInt64(1) << (7 * width)) - 2 {
        width += 1
      }
      var scratch = value
      var bytes = [UInt8](repeating: 0, count: width)
      for index in stride(from: width - 1, through: 0, by: -1) {
        bytes[index] = UInt8(truncatingIfNeeded: scratch)
        scratch >>= 8
      }
      bytes[0] |= 0x80 >> (width - 1)
      return bytes
    }

    private static func unsigned(_ value: UInt64) -> Data {
      if value == 0 { return Data([0x00]) }
      var scratch = value
      var bytes: [UInt8] = []
      while scratch > 0 {
        bytes.append(UInt8(truncatingIfNeeded: scratch))
        scratch >>= 8
      }
      bytes.reverse()
      return Data(bytes)
    }

    private static func float64(_ value: Double) -> Data {
      let bits = value.bitPattern
      var bytes: [UInt8] = []
      bytes.reserveCapacity(8)
      for shift in stride(from: 56, through: 0, by: -8) {
        bytes.append(UInt8(truncatingIfNeeded: bits >> shift))
      }
      return Data(bytes)
    }
  }
}
