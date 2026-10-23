import Foundation

// Format-level views of the IFO files, as laid out by the DVD-Video specification.
//
// Each structure's layout is drawn as a table above the code that reads it: the byte offset
// of each field, its size, and what it holds. Offsets are hexadecimal, and all values are
// big-endian. Fields the parser doesn't need are left out.

/// `VIDEO_TS.IFO`: the Disc's title table.
struct VideoManagerIFO {
  struct TitleEntry {
    let angles: Int
    let titleSet: Int
    let titleInSet: Int
  }

  let titleSetCount: Int
  let titles: [TitleEntry]

  // Header:
  //
  //   0x00  12 bytes  "DVDVIDEO-VMG"
  //   0x3E  u16       number of Title Sets on the Disc
  //   0xC4  u32       Sector where the title table starts
  //
  // Title table (TT_SRPT):
  //
  //   0x00  u16       number of Titles (n)
  //   0x08  n × 12    one entry per Title:
  //
  //     0x01  u8        number of camera angles
  //     0x06  u8        Title Set holding the Title
  //     0x07  u8        the Title's number within its Title Set
  init(_ data: Data) throws(DiscError.Reason) {
    let ifo = ByteReader(data)
    guard try ifo.bytes(at: 0, count: 12) == Array("DVDVIDEO-VMG".utf8) else { throw .notAnIFO }
    titleSetCount = try ifo.u16(at: 0x3E)

    let table = try ifo.u32(at: 0xC4) * Sector.size
    var titles: [TitleEntry] = []
    for index in 0..<(try ifo.u16(at: table)) {
      let entry = table + 0x08 + 12 * index
      titles.append(
        TitleEntry(
          angles: try ifo.u8(at: entry + 0x01),
          titleSet: try ifo.u8(at: entry + 0x06),
          titleInSet: try ifo.u8(at: entry + 0x07)))
    }
    self.titles = titles
  }
}

/// `VTS_xx_0.IFO`: a Title Set's streams, Chapters and program chains.
struct TitleSetIFO {
  /// A Chapter's entry point: a program within a program chain, both 1-based.
  struct ChapterEntry {
    let programChain: Int
    let program: Int
  }

  let audioTracks: [AudioTrack]
  let subtitleTracks: [SubtitleTrack]
  /// For each Title in the set, its Chapters' entry points.
  let chapters: [[ChapterEntry]]
  let programChains: [ProgramChain]

  // Header:
  //
  //   0x000  12 bytes  "DVDVIDEO-VTS"
  //   0x0C8  u32       Sector where the Chapter table starts
  //   0x0CC  u32       Sector where the program chain table starts
  //   0x202  u16       number of audio streams (at most 8)
  //   0x204  8 × 8     audio attributes, one entry per stream
  //   0x254  u16       number of subtitle streams (at most 32)
  //   0x256  32 × 6    subtitle attributes, one entry per stream
  init(_ data: Data) throws(DiscError.Reason) {
    let ifo = ByteReader(data)
    guard try ifo.bytes(at: 0, count: 12) == Array("DVDVIDEO-VTS".utf8) else { throw .notAnIFO }

    var audioTracks: [AudioTrack] = []
    for index in 0..<min(try ifo.u16(at: 0x202), 8) {
      audioTracks.append(try AudioTrack(ifo, at: 0x204 + 8 * index))
    }
    self.audioTracks = audioTracks

    var subtitleTracks: [SubtitleTrack] = []
    for index in 0..<min(try ifo.u16(at: 0x254), 32) {
      subtitleTracks.append(try SubtitleTrack(ifo, at: 0x256 + 6 * index))
    }
    self.subtitleTracks = subtitleTracks

    chapters = try Self.chapters(ifo, at: try ifo.u32(at: 0x0C8) * Sector.size)
    programChains = try Self.programChains(ifo, at: try ifo.u32(at: 0x0CC) * Sector.size)
  }

  // Chapter table (VTS_PTT_SRPT). Offsets inside it are relative to its start:
  //
  //   0x00  u16       number of Titles (n)
  //   0x04  u32       offset of the table's last byte
  //   0x08  n × u32   offset of each Title's Chapter list
  //   ...             the Chapter lists, back to back
  //
  // A Chapter list has no count of its own: it runs until the next Title's list starts, and
  // the last one until the table ends. Each Chapter in a list is 4 bytes:
  //
  //   0x00  u16       program chain number
  //   0x02  u16       program number within that chain
  private static func chapters(_ ifo: ByteReader, at table: Int) throws(DiscError.Reason)
    -> [[ChapterEntry]]
  {
    let titleCount = try ifo.u16(at: table)
    let tableEnd = table + (try ifo.u32(at: table + 0x04)) + 1

    var listStarts: [Int] = []
    for title in 0..<titleCount {
      listStarts.append(table + (try ifo.u32(at: table + 0x08 + 4 * title)))
    }
    // Each list runs until the next Title's list; the last one until the table ends.
    let listEnds = listStarts.dropFirst() + [tableEnd]

    var chapters: [[ChapterEntry]] = []
    for (start, end) in zip(listStarts, listEnds) {
      var list: [ChapterEntry] = []
      for chapter in stride(from: start, to: end, by: 4) {
        list.append(
          ChapterEntry(
            programChain: try ifo.u16(at: chapter),
            program: try ifo.u16(at: chapter + 0x02)))
      }
      chapters.append(list)
    }
    return chapters
  }

  // Program chain table (VTS_PGCI). Offsets inside it are relative to its start:
  //
  //   0x00  u16       number of program chains (n)
  //   0x08  n × 8     one entry per program chain:
  //
  //     0x04  u32       offset of the program chain
  private static func programChains(_ ifo: ByteReader, at table: Int) throws(DiscError.Reason)
    -> [ProgramChain]
  {
    var programChains: [ProgramChain] = []
    for index in 0..<(try ifo.u16(at: table)) {
      let entry = table + 0x08 + 8 * index
      programChains.append(try ProgramChain(ifo, at: table + (try ifo.u32(at: entry + 0x04))))
    }
    return programChains
  }
}

/// A sequence of Cells played in order, split into programs (Chapter entry points).
struct ProgramChain {
  struct CellPlayback {
    let sectors: ClosedRange<Int>
    let playbackTime: Duration
    /// Part of a block of Cells that are alternative camera angles.
    let isAngle: Bool
    /// Interleaved with other Cells on the Disc, as angles and seamless branches are.
    let isInterleaved: Bool
  }

  let playbackTime: Duration
  /// The 1-based entry Cell of each program.
  let programs: [Int]
  let cells: [CellPlayback]
  /// Whether each of the Title Set's audio streams is used by this chain.
  let usesAudio: [Bool]
  let usesSubtitles: [Bool]

  // Program chain (PGC). Offsets inside it are relative to its start:
  //
  //   0x02  u8        number of programs
  //   0x03  u8        number of Cells
  //   0x04  4 bytes   playback time (see `ByteReader.playbackTime(at:)`)
  //   0x0C  8 × 2     audio stream control: top bit set if the chain uses that stream
  //   0x1C  32 × 4    subtitle stream control: top bit set if the chain uses that stream
  //   0xE6  u16       offset of the program map: each program's entry Cell, a u8 each
  //   0xE8  u16       offset of the Cell playback table: 24 bytes per Cell, in playback order
  //
  // Cell playback entry:
  //
  //   0x00  u8        bits 7–6 block mode, bits 5–4 block type (01 = angle block),
  //                   bit 2 interleaved
  //   0x04  4 bytes   playback time
  //   0x08  u32       first Sector
  //   0x14  u32       last Sector
  init(_ ifo: ByteReader, at start: Int) throws(DiscError.Reason) {
    let programCount = try ifo.u8(at: start + 0x02)
    let cellCount = try ifo.u8(at: start + 0x03)
    playbackTime = try ifo.playbackTime(at: start + 0x04)
    usesAudio = try (0..<8).map { (index) throws(DiscError.Reason) in
      try ifo.u8(at: start + 0x0C + 2 * index) & 0x80 != 0
    }
    usesSubtitles = try (0..<32).map { (index) throws(DiscError.Reason) in
      try ifo.u8(at: start + 0x1C + 4 * index) & 0x80 != 0
    }

    let programMap = start + (try ifo.u16(at: start + 0xE6))
    programs = try (0..<programCount).map { (index) throws(DiscError.Reason) in
      try ifo.u8(at: programMap + index)
    }

    let cellTable = start + (try ifo.u16(at: start + 0xE8))
    cells = try (0..<cellCount).map { (index) throws(DiscError.Reason) in
      let cell = cellTable + 24 * index
      let flags = try ifo.u8(at: cell)
      return CellPlayback(
        sectors: try ifo.u32(at: cell + 0x08)...(try ifo.u32(at: cell + 0x14)),
        playbackTime: try ifo.playbackTime(at: cell + 0x04),
        isAngle: flags >> 4 & 0b11 == 0b01,
        isInterleaved: flags & 0x04 != 0)
    }
  }
}

extension Array {
  /// DVD-Video numbers are 1-based. Returns nil when the number is missing.
  subscript(oneBased number: Int) -> Element? {
    indices.contains(number - 1) ? self[number - 1] : nil
  }
}

extension AudioTrack {
  // Audio attributes entry, 8 bytes:
  //
  //   0x00  u8        bits 7–5 coding mode
  //   0x01  u8        bits 2–0 channel count minus 1
  //   0x02  2 bytes   language code, ASCII
  //   0x05  u8        kind (code extension)
  init(_ ifo: ByteReader, at offset: Int) throws(DiscError.Reason) {
    codec =
      switch try ifo.u8(at: offset) >> 5 {
      case 0: .ac3
      case 2: .mpeg1
      case 3: .mpeg2
      case 4: .lpcm
      case 6: .dts
      default: .unknown
      }
    channels = (try ifo.u8(at: offset + 0x01) & 0x07) + 1
    language = try languageCode(ifo, at: offset + 0x02)
    kind =
      switch try ifo.u8(at: offset + 0x05) {
      case 1: .normal
      case 2: .visuallyImpaired
      case 3: .directorsComments
      case 4: .alternateDirectorsComments
      default: .unspecified
      }
  }
}

extension SubtitleTrack {
  // Subtitle attributes entry, 6 bytes:
  //
  //   0x02  2 bytes   language code, ASCII
  //   0x05  u8        kind (code extension)
  init(_ ifo: ByteReader, at offset: Int) throws(DiscError.Reason) {
    language = try languageCode(ifo, at: offset + 0x02)
    kind =
      switch try ifo.u8(at: offset + 0x05) {
      case 1: .normal
      case 2: .large
      case 3: .children
      case 5: .captions
      case 6: .largeCaptions
      case 7: .childrensCaptions
      case 9: .forced
      case 13: .directorsComments
      case 14: .largeDirectorsComments
      case 15: .childrensDirectorsComments
      default: .unspecified
      }
  }
}

/// A raw 2-letter language code, or `nil` when the bytes aren't letters.
private func languageCode(_ ifo: ByteReader, at offset: Int) throws(DiscError.Reason) -> String? {
  let bytes = try ifo.bytes(at: offset, count: 2)
  guard
    bytes.allSatisfy({
      Character(UnicodeScalar($0)).isASCII && Character(UnicodeScalar($0)).isLetter
    })
  else { return nil }
  return String(decoding: bytes, as: UTF8.self)
}
