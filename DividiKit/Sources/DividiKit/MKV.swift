import Foundation

// The MKV for one Extraction. EBML element ids stay in this file so a demuxer
// cannot write a second container. ByteReader stays the IFO reader.

/// One Extraction's MPEG-2 video and AC-3 audio, remuxed into an MKV.
///
/// `data(video:audio:)` is pure. The same inputs return the same bytes. Payloads
/// are copied. The caller keeps any file path.
public enum MKV: Sendable {
  /// One encoded video or audio frame and when it plays, counted from the start
  /// of the Extraction. The same `Duration` a Title uses.
  public struct Packet: Equatable, Sendable {
    public let bytes: Data
    /// When this frame starts playing, counted from the start of the Extraction.
    public let presentation: Duration
    /// How long this frame plays for.
    public let duration: Duration
    /// Whether a player can seek to this frame and decode from here without earlier frames.
    /// Ignored for audio: every AC-3 frame decodes on its own, so each one is a keyframe.
    public let isKeyframe: Bool

    public init(bytes: Data, presentation: Duration, duration: Duration, isKeyframe: Bool) {
      self.bytes = bytes
      self.presentation = presentation
      self.duration = duration
      self.isKeyframe = isKeyframe
    }
  }

  /// MPEG-2 video for one Extraction.
  public struct Video: Equatable, Sendable {
    /// Coded width, in pixels.
    public let width: Int
    /// Coded height, in pixels.
    public let height: Int
    public let displayAspect: DisplayAspect
    public let packets: [Packet]

    public init(width: Int, height: Int, displayAspect: DisplayAspect, packets: [Packet]) {
      self.width = width
      self.height = height
      self.displayAspect = displayAspect
      self.packets = packets
    }

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

  /// AC-3 audio for one Extraction.
  ///
  /// An `AudioTrack` is a stream the Disc offers. The caller has already chosen
  /// one and split its packets into this value.
  public struct Audio: Equatable, Sendable {
    public let sampleRate: Int
    /// Number of audio channels, e.g. 2 for stereo.
    public let channels: Int
    public let packets: [Packet]

    public init(sampleRate: Int, channels: Int, packets: [Packet]) {
      self.sampleRate = sampleRate
      self.channels = channels
      self.packets = packets
    }
  }

  /// What a video track's TrackEntry says about its pictures.
  public struct VideoFormat: Equatable, Sendable {
    /// Coded width, in pixels.
    public let width: Int
    /// Coded height, in pixels.
    public let height: Int
    public let displayAspect: Video.DisplayAspect

    public init(width: Int, height: Int, displayAspect: Video.DisplayAspect) {
      self.width = width
      self.height = height
      self.displayAspect = displayAspect
    }
  }

  /// What an audio track's TrackEntry says about its sound.
  public struct AudioFormat: Equatable, Sendable {
    public let sampleRate: Int
    /// Number of audio channels, e.g. 2 for stereo.
    public let channels: Int

    public init(sampleRate: Int, channels: Int) {
      self.sampleRate = sampleRate
      self.channels = channels
    }
  }

  /// Remuxes one video stream and one audio stream into MKV bytes.
  public static func data(video: Video, audio: Audio) throws -> Data {
    var writer = try Writer(
      output: DataOutput(),
      video: VideoFormat(
        width: video.width, height: video.height, displayAspect: video.displayAspect),
      audio: AudioFormat(sampleRate: audio.sampleRate, channels: audio.channels))
    guard !video.packets.isEmpty else { throw MKVError.emptyPackets(.video) }
    guard !audio.packets.isEmpty else { throw MKVError.emptyPackets(.audio) }
    for packet in video.packets { try writer.append(packet, to: .video) }
    for packet in audio.packets { try writer.append(packet, to: .audio) }
    try writer.finish()
    return writer.output.data
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
  /// A packet's duration is zero or negative.
  case nonPositiveDuration(Stream)
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
    case .nonPositiveDuration(.video): "a video packet duration is zero or negative"
    case .nonPositiveDuration(.audio): "an audio packet duration is zero or negative"
    case .nonPositive(.width): "the picture width is zero or negative"
    case .nonPositive(.height): "the picture height is zero or negative"
    case .nonPositive(.sampleRate): "the sample rate is zero or negative"
    case .nonPositive(.channels): "the channel count is zero or negative"
    }
  }
}

private enum TimestampScale {
  /// One Matroska tick equals this many nanoseconds, so each tick is one millisecond.
  static let nanoseconds: UInt64 = 1_000_000
  /// SimpleBlock relative timestamps are Int16, so +32_767 forward and −32_768 back.
  static let maxForwardRelativeTick = UInt64(Int16.max)
  static let maxBackwardRelativeTick = UInt64(Int16.max) + 1
}

extension MKVError.Stream {
  fileprivate var trackNumber: UInt64 {
    switch self {
    case .video: 1
    case .audio: 2
    }
  }

  fileprivate var trackType: UInt64 {
    switch self {
    case .video: 1
    case .audio: 2
    }
  }

  fileprivate var codecID: String {
    switch self {
    case .video: "V_MPEG2"
    case .audio: "A_AC3"
    }
  }

  /// The Video or Audio element that holds this track's settings.
  fileprivate var settingsID: [UInt8] {
    switch self {
    case .video: ElementID.video
    case .audio: ElementID.audio
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

/// Where a Writer puts the MKV's bytes.
protocol MKVOutput {
  /// How many bytes have been written so far.
  var count: Int { get }
  mutating func append(_ bytes: Data) throws
  /// Writes over bytes already written, at `offset` from the start.
  mutating func overwrite(_ bytes: Data, at offset: Int) throws
}

/// An MKV held in memory.
struct DataOutput: MKVOutput {
  private(set) var data = Data()

  var count: Int { data.count }

  mutating func append(_ bytes: Data) {
    data.append(bytes)
  }

  mutating func overwrite(_ bytes: Data, at offset: Int) {
    data.replaceSubrange(offset..<offset + bytes.count, with: bytes)
  }
}

/// An MKV written to a file as it goes, starting at the handle's current end.
///
/// Write errors name `file` rather than whatever the handle is open on, such as a temporary
/// file that only becomes `file` once complete.
struct FileOutput: MKVOutput {
  let handle: FileHandle
  let file: URL
  private(set) var count = 0

  init(_ handle: FileHandle, file: URL) {
    self.handle = handle
    self.file = file
  }

  mutating func append(_ bytes: Data) throws {
    try naming(file) { try handle.write(contentsOf: bytes) }
    count += bytes.count
  }

  func overwrite(_ bytes: Data, at offset: Int) throws {
    try naming(file) {
      try handle.seek(toOffset: UInt64(offset))
      try handle.write(contentsOf: bytes)
      try handle.seekToEnd()
    }
  }
}

/// Runs `body`, reporting a file system error it throws as being about `file`.
func naming<T>(_ file: URL, _ body: () throws -> T) throws -> T {
  do {
    return try body()
  } catch let error as CocoaError {
    throw CocoaError(error.code, userInfo: [NSURLErrorKey: file])
  }
}

extension MKV {
  /// Writes one Extraction's MKV a Cluster at a time, as its packets arrive.
  ///
  /// Each track's packets arrive in decode order. The Writer holds them only until the other
  /// track has caught up, then interleaves the two by presentation time, video first on a tie.
  /// Each video keyframe starts a Cluster, so a player can seek to it through the Cues written
  /// after the last Cluster. The Segment size, the Duration and where the Cues are aren't known
  /// until the last packet, so `finish()` writes them over placeholders.
  struct Writer<Output: MKVOutput> {
    private(set) var output: Output
    /// Where the Segment's 8-byte size goes, and where the Segment's body starts after it.
    private let segmentSize: Int
    /// Where the Segment's body starts; positions inside the Segment count from here.
    private let segmentStart: Int
    /// Where the Info's 8-byte Duration goes.
    private let durationAt: Int
    /// Where the SeekHead's entry for the Cues starts, and where its 8-byte position goes.
    private let cuesSeek: (start: Int, positionAt: Int)
    /// Each Cluster that starts with a video keyframe: the keyframe's tick and the Cluster's
    /// position in the Segment.
    private var cues: [(tick: UInt64, position: Int)] = []
    private var queues: [MKVError.Stream: Queue<Pending>] = [.video: Queue(), .audio: Queue()]
    private var appended: Set<MKVError.Stream> = []
    /// The Cluster being filled, until the next video keyframe or a block outside its timestamp
    /// range; `isCued` when it starts with a video keyframe.
    private var cluster: (timestampTicks: UInt64, body: EBML.Buffer, isCued: Bool)?
    /// End of the longest track so far, in Matroska ticks.
    private var durationTicks: UInt64 = 0

    private struct Pending {
      var stream: MKVError.Stream
      var tick: UInt64
      var bytes: Data
      var endTick: UInt64
      var isKeyframe: Bool
    }

    /// Writes the EBML header, the start of the Segment, the SeekHead, the Info and the Tracks.
    init(output: Output, video: VideoFormat, audio: AudioFormat) throws {
      guard video.width > 0 else { throw MKVError.nonPositive(.width) }
      guard video.height > 0 else { throw MKVError.nonPositive(.height) }
      guard audio.sampleRate > 0 else { throw MKVError.nonPositive(.sampleRate) }
      guard audio.channels > 0 else { throw MKVError.nonPositive(.channels) }
      self.output = output

      var head = EBML.Buffer()
      head.header()
      head.unknownSizeMaster(ElementID.segment)
      segmentSize = output.count + head.data.count - EBML.sizeWidth
      segmentStart = output.count + head.data.count

      var info = EBML.Buffer()
      var durationInInfo = 0
      info.info { durationInInfo = $0 }
      var tracks = EBML.Buffer()
      tracks.tracks(video: video, audio: audio)
      // The SeekHead's positions are written 8 bytes wide, so its size doesn't depend on them.
      let seekHeadSize = EBML.Buffer.seekHead(info: 0, tracks: 0).buffer.data.count
      let seekHead = EBML.Buffer.seekHead(
        info: seekHeadSize, tracks: seekHeadSize + info.data.count)
      cuesSeek = (segmentStart + seekHead.cues.start, segmentStart + seekHead.cues.positionAt)
      durationAt = segmentStart + seekHeadSize + durationInInfo
      head.data += seekHead.buffer.data + info.data + tracks.data
      try self.output.append(head.data)
    }

    /// Takes the next packet of one track, in that track's decode order.
    mutating func append(_ packet: Packet, to stream: MKVError.Stream) throws {
      guard packet.presentation >= .zero else { throw MKVError.negativePresentation(stream) }
      guard packet.duration > .zero else { throw MKVError.nonPositiveDuration(stream) }
      queues[stream]!.push(
        Pending(
          stream: stream, tick: ticks(packet.presentation), bytes: packet.bytes,
          endTick: ticks(packet.presentation + packet.duration),
          isKeyframe: stream == .audio || packet.isKeyframe))
      appended.insert(stream)
      try interleave(untilEmpty: false)
    }

    /// Writes whatever is held back and the Cues, then the Segment size and the Duration.
    mutating func finish() throws {
      guard appended.contains(.video) else { throw MKVError.emptyPackets(.video) }
      guard appended.contains(.audio) else { throw MKVError.emptyPackets(.audio) }
      try interleave(untilEmpty: true)
      try closeCluster()
      if cues.isEmpty {
        // Cues need a CuePoint, so with no video keyframe there are none, and the SeekHead's
        // entry for them becomes padding.
        try output.overwrite(
          EBML.void(size: cuesSeek.positionAt + 8 - cuesSeek.start), at: cuesSeek.start)
      } else {
        try output.overwrite(
          EBML.fixedUnsigned(UInt64(output.count - segmentStart)), at: cuesSeek.positionAt)
        var element = EBML.Buffer()
        element.cues(cues, track: MKVError.Stream.video.trackNumber)
        try output.append(element.data)
      }
      try output.overwrite(EBML.float64(Double(durationTicks)), at: durationAt)
      try output.overwrite(
        EBML.size(UInt64(output.count - segmentSize - EBML.sizeWidth)), at: segmentSize)
    }

    /// Writes the earliest of the two tracks' next packets while both have one, or every held
    /// packet when the tracks have ended.
    private mutating func interleave(untilEmpty: Bool) throws {
      while true {
        let next: MKVError.Stream
        switch (queues[.video]!.first, queues[.audio]!.first) {
        case (let video?, let audio?): next = video.tick <= audio.tick ? .video : .audio
        case (.some, nil) where untilEmpty: next = .video
        case (nil, .some) where untilEmpty: next = .audio
        default: return
        }
        try write(queues[next]!.pop())
      }
    }

    private mutating func write(_ packet: Pending) throws {
      durationTicks = max(durationTicks, packet.endTick)
      // A block can only store an Int16 offset from the cluster timestamp. When a packet falls
      // outside that range (common once the timeline grows past ~33 s, or when B-frames sit
      // behind a new cluster base), close the current cluster and start a new one whose base is
      // this packet's tick.
      // A video keyframe starts a new Cluster too, so seeking lands on one.
      let isCued = packet.stream == .video && packet.isKeyframe
      if let cluster {
        let outsideCluster =
          packet.tick >= cluster.timestampTicks
          ? packet.tick - cluster.timestampTicks > TimestampScale.maxForwardRelativeTick
          : cluster.timestampTicks - packet.tick > TimestampScale.maxBackwardRelativeTick
        if outsideCluster || isCued { try closeCluster() }
      }
      if cluster == nil {
        var body = EBML.Buffer()
        body.uint(ElementID.timestamp, packet.tick)
        cluster = (packet.tick, body, isCued)
      }
      let base = cluster!.timestampTicks
      let relative =
        packet.tick >= base ? Int64(packet.tick - base) : -Int64(base - packet.tick)
      cluster!.body.simpleBlock(
        track: packet.stream.trackNumber, relativeTicks: Int16(relative), bytes: packet.bytes,
        isKeyframe: packet.isKeyframe)
    }

    private mutating func closeCluster() throws {
      guard let cluster else { return }
      if cluster.isCued {
        cues.append((cluster.timestampTicks, output.count - segmentStart))
      }
      var element = EBML.Buffer()
      element.element(ElementID.cluster, cluster.body.data)
      try output.append(element.data)
      self.cluster = nil
    }

    private func ticks(_ presentation: Duration) -> UInt64 {
      let (seconds, attoseconds) = presentation.components
      // One millisecond is 10^15 attoseconds; convert the fractional second that way.
      let attosecondsPerMillisecond: Int64 = 1_000_000_000_000_000
      let whole = UInt64(seconds) * 1_000
      let fraction = attoseconds / attosecondsPerMillisecond
      var ticks = whole + UInt64(fraction)
      // Round half-up so 0.5 ms and above become the next tick.
      if attoseconds % attosecondsPerMillisecond >= attosecondsPerMillisecond / 2 {
        ticks += 1
      }
      return ticks
    }
  }
}

/// A first-in, first-out queue that pops without moving what's behind.
struct Queue<Element> {
  private var elements: [Element] = []
  private var head = 0

  var first: Element? { head < elements.count ? elements[head] : nil }

  mutating func push(_ element: Element) {
    elements.append(element)
  }

  mutating func pop() -> Element {
    let element = elements[head]
    head += 1
    // Let go of popped elements once they're half the array, so moving the rest stays cheap.
    if head * 2 >= elements.count {
      elements.removeFirst(head)
      head = 0
    }
    return element
  }
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
  static let seekHead: [UInt8] = [0x11, 0x4D, 0x9B, 0x74]
  static let seek: [UInt8] = [0x4D, 0xBB]
  static let seekID: [UInt8] = [0x53, 0xAB]
  static let seekPosition: [UInt8] = [0x53, 0xAC]
  static let cues: [UInt8] = [0x1C, 0x53, 0xBB, 0x6B]
  static let cuePoint: [UInt8] = [0xBB]
  static let cueTime: [UInt8] = [0xB3]
  static let cueTrackPositions: [UInt8] = [0xB7]
  static let cueTrack: [UInt8] = [0xF7]
  static let cueClusterPosition: [UInt8] = [0xF1]
  static let void: [UInt8] = [0xEC]
}

private enum EBML {
  /// How many bytes a size written over later takes: one marker byte, then 7 value bytes.
  static let sizeWidth = 8

  /// An element size `sizeWidth` bytes wide, whatever its value, so it can be written over a
  /// placeholder.
  static func size(_ value: UInt64) -> Data {
    var bytes = [UInt8](repeating: 0, count: sizeWidth)
    var scratch = value
    for index in stride(from: sizeWidth - 1, through: 1, by: -1) {
      bytes[index] = UInt8(truncatingIfNeeded: scratch)
      scratch >>= 8
    }
    bytes[0] = 0x01
    return Data(bytes)
  }

  struct Buffer {
    var data = Data()

    mutating func master(_ id: [UInt8], _ build: (inout Buffer) -> Void) {
      var child = Buffer()
      build(&child)
      element(id, child.data)
    }

    /// Starts a master element whose size is written over later, with `EBML.size`.
    mutating func unknownSizeMaster(_ id: [UInt8]) {
      data.append(contentsOf: id)
      // All ones means an unknown size, which a player still accepts if the size is never
      // written over.
      data.append(contentsOf: [0x01] + [UInt8](repeating: 0xFF, count: EBML.sizeWidth - 1))
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

    mutating func simpleBlock(track: UInt64, relativeTicks: Int16, bytes: Data, isKeyframe: Bool) {
      var body = Data()
      body.append(contentsOf: Self.vint(track))
      let relative = UInt16(bitPattern: relativeTicks)
      body.append(UInt8(relative >> 8))
      body.append(UInt8(truncatingIfNeeded: relative))
      body.append(isKeyframe ? 0x80 : 0)
      body.append(bytes)
      element(ElementID.simpleBlock, body)
    }

    /// The EBML header, saying the file is Matroska.
    mutating func header() {
      master(ElementID.ebml) { header in
        header.uint(ElementID.ebmlVersion, 1)
        header.uint(ElementID.ebmlReadVersion, 1)
        header.uint(ElementID.ebmlMaxIDLength, 4)
        header.uint(ElementID.ebmlMaxSizeLength, 8)
        header.string(ElementID.docType, Container.docType)
        header.uint(ElementID.docTypeVersion, Container.docTypeVersion)
        header.uint(ElementID.docTypeReadVersion, Container.docTypeReadVersion)
      }
    }

    /// The Info, with a Duration of 0 to write over; `durationAt` gets where its 8 bytes are.
    mutating func info(durationAt: (Int) -> Void) {
      var body = Buffer()
      body.uint(ElementID.timestampScale, TimestampScale.nanoseconds)
      body.float(ElementID.duration, 0)
      let durationInBody = body.data.count - 8
      body.string(ElementID.muxingApp, Container.writerName)
      body.string(ElementID.writingApp, Container.writerName)
      let bodyStart = element(ElementID.info, body.data)
      durationAt(bodyStart + durationInBody)
    }

    /// A SeekHead pointing at the Info, the Tracks and the Cues, by their positions in the
    /// Segment. The Cues' position is 0 for now; `cues` is where its Seek starts in the buffer
    /// and where its 8-byte position goes.
    static func seekHead(info: Int, tracks: Int) -> (
      buffer: Buffer, cues: (start: Int, positionAt: Int)
    ) {
      var body = Buffer()
      body.seek(ElementID.info, at: info)
      body.seek(ElementID.tracks, at: tracks)
      let cuesStart = body.data.count
      let cuesPosition = body.seek(ElementID.cues, at: 0)
      var buffer = Buffer()
      let bodyStart = buffer.element(ElementID.seekHead, body.data)
      return (buffer, (bodyStart + cuesStart, bodyStart + cuesPosition))
    }

    /// A Seek with its position 8 bytes wide; returns where the position starts.
    @discardableResult private mutating func seek(_ id: [UInt8], at position: Int) -> Int {
      var body = Buffer()
      body.element(ElementID.seekID, Data(id))
      let positionInBody = body.element(
        ElementID.seekPosition, EBML.fixedUnsigned(UInt64(position)))
      return element(ElementID.seek, body.data) + positionInBody
    }

    /// Cues pointing at each Cluster that starts with a keyframe of `track`.
    mutating func cues(_ cues: [(tick: UInt64, position: Int)], track: UInt64) {
      master(ElementID.cues) { body in
        for cue in cues {
          body.master(ElementID.cuePoint) { point in
            point.uint(ElementID.cueTime, cue.tick)
            point.master(ElementID.cueTrackPositions) { positions in
              positions.uint(ElementID.cueTrack, track)
              positions.uint(ElementID.cueClusterPosition, UInt64(cue.position))
            }
          }
        }
      }
    }

    /// The Tracks: video as track 1, audio as track 2.
    mutating func tracks(video: MKV.VideoFormat, audio: MKV.AudioFormat) {
      master(ElementID.tracks) { tracks in
        tracks.trackEntry(.video) { settings in
          settings.uint(ElementID.pixelWidth, UInt64(video.width))
          settings.uint(ElementID.pixelHeight, UInt64(video.height))
          let ratio = video.displayAspect.ratio
          settings.uint(ElementID.displayWidth, UInt64(ratio.width))
          settings.uint(ElementID.displayHeight, UInt64(ratio.height))
          settings.uint(ElementID.displayUnit, Container.displayUnitAspectRatio)
        }
        tracks.trackEntry(.audio) { settings in
          settings.float(ElementID.samplingFrequency, Double(audio.sampleRate))
          settings.uint(ElementID.channels, UInt64(audio.channels))
        }
      }
    }

    /// A TrackEntry for one stream; `settings` fills its Video or Audio element.
    private mutating func trackEntry(_ stream: MKVError.Stream, settings: (inout Buffer) -> Void) {
      master(ElementID.trackEntry) { entry in
        entry.uint(ElementID.trackNumber, stream.trackNumber)
        entry.uint(ElementID.trackUID, stream.trackNumber)
        entry.uint(ElementID.trackType, stream.trackType)
        entry.uint(ElementID.flagLacing, 0)
        entry.string(ElementID.codecID, stream.codecID)
        entry.master(stream.settingsID, settings)
      }
    }

    /// Appends an element and returns where its body starts.
    @discardableResult mutating func element(_ id: [UInt8], _ body: Data) -> Int {
      data.append(contentsOf: id)
      data.append(contentsOf: Self.vint(UInt64(body.count)))
      let bodyStart = data.count
      data.append(body)
      return bodyStart
    }

    /// Encodes an EBML variable-length integer: the leading byte's high bits mark
    /// the width, and the remaining bits hold the value. All-ones is reserved for
    /// an unknown size, so width `w` stops at `2^(7w) - 2`.
    static func vint(_ value: UInt64) -> [UInt8] {
      var width = 1
      // Width marker sits in the first byte (w-1 zeros, then a 1); remaining bits are
      // the value. With n = 7w value bits you get 2^n patterns (0 through 2^n-1); the
      // last pattern (all ones) means "unknown size", so real values stop one earlier.
      // width 1 → n=7 → max 126; width 2 → n=14 → max 16_382. Grow until value fits.
      while value > (UInt64(1) << (7 * width)) - 2 {
        width += 1
      }
      var scratch = value
      var bytes = [UInt8](repeating: 0, count: width)
      // Low byte first into the end of the array, then shift, so the layout is big-endian.
      for index in stride(from: width - 1, through: 0, by: -1) {
        bytes[index] = UInt8(truncatingIfNeeded: scratch)  // lowest 8 bits
        scratch >>= 8
      }
      // Set the width marker in the first byte: bit 7 for width 1, bit 6 for width 2, …
      // (the value fit in 7w bits, so those high bits were still clear).
      bytes[0] |= 0x80 >> (width - 1)
      return bytes
    }

    /// Big-endian integer body for a UInt element. Unlike `vint` (used for IDs and
    /// sizes), the payload has no width marker — the element's size field already
    /// says how many bytes follow.
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

    static func float64(_ value: Double) -> Data {
      let bits = value.bitPattern
      var bytes: [UInt8] = []
      bytes.reserveCapacity(8)
      for shift in stride(from: 56, through: 0, by: -8) {
        bytes.append(UInt8(truncatingIfNeeded: bits >> shift))
      }
      return Data(bytes)
    }
  }

  static func float64(_ value: Double) -> Data {
    Buffer.float64(value)
  }

  /// An unsigned integer body 8 bytes wide, whatever its value, so it can be written over.
  static func fixedUnsigned(_ value: UInt64) -> Data {
    Data((0..<8).reversed().map { UInt8(truncatingIfNeeded: value >> (8 * $0)) })
  }

  /// A Void element of `size` bytes in all, which players skip; `size` is 2 to 128.
  static func void(size: Int) -> Data {
    Data(ElementID.void + [0x80 | UInt8(size - 2)] + [UInt8](repeating: 0, count: size - 2))
  }
}
