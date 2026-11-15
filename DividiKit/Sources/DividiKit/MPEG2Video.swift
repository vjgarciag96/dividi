import Foundation

// Format-level view of an MPEG-2 video elementary stream, as laid out by MPEG-2 Video.
//
// The stream is a run of start codes (00 00 01, then an id byte) and the data after each:
//
//   B3     sequence header: picture size, aspect ratio, frame rate
//   B8     group of pictures header: temporal references restart from here
//   00     picture header: temporal reference and coding type
//   B5     extensions: progressive sequence, how many fields a picture is shown for
//   01–AF  slices, B2 user data: part of whatever came before

enum MPEG2Video {
  struct Format: Equatable {
    /// Coded width, in pixels.
    let width: Int
    /// Coded height, in pixels.
    let height: Int
    let displayAspect: MKV.Video.DisplayAspect
  }

  /// Cuts the packets' payloads into frames, in decode order.
  ///
  /// A frame holds a frame picture or a pair of field pictures, with the sequence and group
  /// headers before it, the same split MKV and ffmpeg use. Anything before the first sequence
  /// header is dropped, since it can't be decoded. A frame whose header starts in a stamped
  /// packet takes its stamp; others count from the stamped frames in the same group.
  static func frames(in packets: [PESPacket]) throws(DemuxError) -> (
    format: Format, frames: [CodedFrame]
  ) {
    let (stream, packetStarts) = joinedPayloads(of: packets)
    guard let (sequenceStart, format, rate) = try firstSequence(in: stream) else {
      throw .missingSequenceHeader
    }

    var cutter = FrameCutter()
    for header in headers(in: stream, from: sequenceStart) {
      cutter.take(header)
    }
    let cuts = cutter.cuts

    // Headers left after the last picture belong to no frame.
    let ends = cuts.dropFirst().map(\.start) + [cutter.leadingStart ?? stream.count]
    let pictures = zip(cuts, ends).map { cut, end in
      (bytes: stream[cut.start..<end], picture: cut.picture)
    }
    let presentations = presentationTimes(
      of: pictures.map(\.picture), packetStarts: packetStarts, rate: rate)
    let frames = zip(pictures, presentations).map { picture, presentation in
      CodedFrame(
        bytes: Data(picture.bytes), presentation: presentation,
        duration: rate.ticks(fields: picture.picture.fields), isKeyframe: picture.picture.isIntra)
    }
    return (format, frames)
  }

  /// The headers that shape frames, from one start code.
  private enum Header {
    /// A sequence or group of pictures header: either starts the next frame.
    case leading(isGroup: Bool)
    case picture(temporalReference: Int, isIntra: Bool)
    /// A picture coding extension: whether its picture is one field, and how many fields it
    /// is shown for.
    case pictureCoding(isFieldPicture: Bool, fields: Int)
  }

  /// The first sequence header: where it starts, and what it says. Nothing before it can be
  /// decoded.
  private static func firstSequence(in stream: [UInt8]) throws(DemuxError) -> (
    start: Int, format: Format, rate: FrameRate
  )? {
    var offset = 0
    while let start = nextStartCode(in: stream, from: offset), start + 8 <= stream.count {
      if stream[start + 3] == 0xB3 {
        let (format, rate) = try sequenceHeader(stream, at: start)
        return (start, format, rate)
      }
      offset = start + 3
    }
    return nil
  }

  /// The frame-shaping headers from `offset` on, with where each starts in the stream.
  private static func headers(in stream: [UInt8], from offset: Int) -> [(start: Int, Header)] {
    var headers: [(start: Int, Header)] = []
    var isProgressive = false
    var offset = offset
    while let start = nextStartCode(in: stream, from: offset), start + 8 <= stream.count {
      offset = start + 3
      switch stream[start + 3] {
      case 0xB3:
        headers.append((start, .leading(isGroup: false)))
      case 0xB8:
        headers.append((start, .leading(isGroup: true)))
      case 0x00:
        // Picture header, from the start code:
        //
        //   0x04  10 bits   temporal reference
        //         3 bits    coding type: 1 I, 2 P, 3 B
        headers.append(
          (
            start,
            .picture(
              temporalReference: Int(stream[start + 4]) << 2 | Int(stream[start + 5] >> 6),
              isIntra: stream[start + 5] >> 3 & 0x07 == 1)
          ))
      case 0xB5:
        // Extension, from the start code:
        //
        //   0x04  4 bits    extension id: 1 sequence, 8 picture coding
        //
        // Sequence extension:
        //
        //   0x05  bit 3     progressive sequence
        //
        // Picture coding extension:
        //
        //   0x06  low 2 bits  picture structure: 1 top field, 2 bottom field, 3 frame
        //   0x07  bit 7       top field first
        //         bit 1       repeat first field
        switch stream[start + 4] >> 4 {
        case 1:
          isProgressive = stream[start + 5] & 0x08 != 0
        case 8:
          let isFieldPicture = stream[start + 6] & 0x03 != 3
          let fields = shownFields(
            isProgressive: isProgressive, isFieldPicture: isFieldPicture,
            topFieldFirst: stream[start + 7] & 0x80 != 0,
            repeatFirstField: stream[start + 7] & 0x02 != 0)
          headers.append((start, .pictureCoding(isFieldPicture: isFieldPicture, fields: fields)))
        default:
          break
        }
      default:
        break
      }
    }
    return headers
  }

  /// Groups headers into frames: a frame is the sequence and group headers before it, then a
  /// frame picture or a pair of field pictures.
  private struct FrameCutter {
    private(set) var cuts: [Cut] = []
    /// Where the sequence and group headers waiting for the next picture start.
    private(set) var leadingStart: Int?
    private var group = 0

    mutating func take(_ header: (start: Int, Header)) {
      let (start, header) = header
      switch header {
      case .leading(let isGroup):
        leadingStart = leadingStart ?? start
        if isGroup { group += 1 }
      case .picture(let temporalReference, let isIntra):
        // The second field picture of a frame follows the first straight away.
        if leadingStart == nil, cuts.last?.stage == .awaitingSecondField {
          cuts[cuts.count - 1].stage = .secondField
          return
        }
        cuts.append(
          Cut(
            start: leadingStart ?? start,
            picture: Picture(
              offset: start, temporalReference: temporalReference, isIntra: isIntra,
              group: group)))
        leadingStart = nil
      case .pictureCoding(let isFieldPicture, let fields):
        guard leadingStart == nil, let stage = cuts.last?.stage else { return }
        switch stage {
        case .firstField:
          cuts[cuts.count - 1].picture.fields = fields
          cuts[cuts.count - 1].stage = isFieldPicture ? .awaitingSecondField : .whole
        case .secondField:
          cuts[cuts.count - 1].picture.fields += fields
          cuts[cuts.count - 1].stage = .whole
        case .awaitingSecondField, .whole:
          break
        }
      }
    }
  }

  private struct Cut {
    /// Where the frame's first header starts in the joined payloads.
    let start: Int
    var picture: Picture
    var stage = Stage.firstField

    /// How far through its pictures a frame is.
    enum Stage {
      /// Its first picture's coding extension is still to come.
      case firstField
      /// Its first picture is a field: the next picture is the other one.
      case awaitingSecondField
      /// Its second field's coding extension is still to come.
      case secondField
      /// Nothing more belongs to it.
      case whole
    }
  }

  private struct Picture {
    /// Where the picture header starts in the joined payloads.
    let offset: Int
    let temporalReference: Int
    let isIntra: Bool
    let group: Int
    var fields = 2
  }

  private struct FrameRate {
    let frames: Int
    let seconds: Int

    func ticks(fields: Int) -> Int {
      (90_000 * seconds * fields + frames) / (2 * frames)
    }
  }

  private static func shownFields(
    isProgressive: Bool, isFieldPicture: Bool, topFieldFirst: Bool, repeatFirstField: Bool
  ) -> Int {
    if isProgressive {
      guard repeatFirstField else { return 2 }
      return topFieldFirst ? 6 : 4
    }
    if isFieldPicture { return 1 }
    return repeatFirstField ? 3 : 2
  }

  // Sequence header, from the start code:
  //
  //   0x04  12 bits   width
  //         12 bits   height
  //   0x07  4 bits    aspect ratio: 2 is 4:3, 3 is 16:9
  //         4 bits    frame rate code
  private static func sequenceHeader(_ stream: [UInt8], at start: Int) throws(DemuxError) -> (
    format: Format, rate: FrameRate
  ) {
    let displayAspect: MKV.Video.DisplayAspect
    switch stream[start + 7] >> 4 {
    case 2: displayAspect = .fourByThree
    case 3: displayAspect = .sixteenByNine
    default: throw .unsupportedAspectRatio
    }
    let (frames, seconds) =
      switch stream[start + 7] & 0x0F {
      case 1: (24_000, 1001)
      case 2: (24, 1)
      case 3: (25, 1)
      case 4: (30_000, 1001)
      case 5: (30, 1)
      case 6: (50, 1)
      case 7: (60_000, 1001)
      case 8: (60, 1)
      default: throw .unsupportedFrameRate
      }
    let format = Format(
      width: Int(stream[start + 4]) << 4 | Int(stream[start + 5] >> 4),
      height: Int(stream[start + 5] & 0x0F) << 8 | Int(stream[start + 6]),
      displayAspect: displayAspect)
    return (format, FrameRate(frames: frames, seconds: seconds))
  }

  private static func presentationTimes(
    of pictures: [Picture], packetStarts: [PacketStart], rate: FrameRate
  ) -> [Int] {
    let stamped = stamps(at: pictures.map(\.offset), packetStarts: packetStarts)

    // Pictures missing from a group count as two fields.
    var groupFields: [Int: [Int: Int]] = [:]
    for picture in pictures {
      groupFields[picture.group, default: [:]][picture.temporalReference] = picture.fields
    }
    let shownAfter = pictures.map { picture in
      let fields = groupFields[picture.group] ?? [:]
      return rate.ticks(
        fields: (0..<picture.temporalReference).reduce(0) { $0 + (fields[$1] ?? 2) })
    }

    // A group without stamps follows on from the end of the group before it.
    var groupStarts: [Int: Int] = [:]
    for (index, stamp) in stamped.enumerated() where groupStarts[pictures[index].group] == nil {
      if let stamp {
        groupStarts[pictures[index].group] = stamp - shownAfter[index]
      }
    }
    var times: [Int] = []
    var end = 0
    var group: Int?
    var groupStart = 0
    for (index, picture) in pictures.enumerated() {
      if picture.group != group {
        group = picture.group
        groupStart = groupStarts[picture.group] ?? end
      }
      let time = stamped[index] ?? groupStart + shownAfter[index]
      times.append(time)
      end = max(end, time + rate.ticks(fields: picture.fields))
    }
    return times
  }
}

private func nextStartCode(in stream: [UInt8], from offset: Int) -> Int? {
  var index = offset
  while index + 2 < stream.count {
    if stream[index + 2] > 1 {
      index += 3
    } else if stream[index] == 0, stream[index + 1] == 0, stream[index + 2] == 1 {
      return index
    } else {
      index += 1
    }
  }
  return nil
}
