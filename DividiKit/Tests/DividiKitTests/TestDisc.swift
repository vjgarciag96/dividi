import DividiKit
import Foundation

/// Builds the IFO files of a synthetic Disc, laid out as the DVD-Video format
/// specifies, without sharing any code with the parser.
struct TestDisc {
  var titles: [TestTitle] = []
  var titleSets: [TestTitleSet] = []

  var source: InMemorySource {
    var files = ["VIDEO_TS.IFO": videoManagerIFO()]
    for (index, titleSet) in titleSets.enumerated() {
      files[String(format: "VTS_%02d_0.IFO", index + 1)] = titleSet.ifo()
    }
    return InMemorySource(files: files)
  }

  private func videoManagerIFO() -> Data {
    var titleTable = ByteWriter()
    titleTable.u16(titles.count)
    titleTable.u16(0)  // reserved
    titleTable.u32(8 + 12 * titles.count - 1)  // last byte of the table
    for title in titles {
      titleTable.u8(0)  // title type
      titleTable.u8(title.angles)
      titleTable.u16(title.chapterCount)
      titleTable.u16(0)  // parental mask
      titleTable.u8(title.titleSet)
      titleTable.u8(title.titleInSet)
      titleTable.u32(0)  // Title Set's first Sector
    }

    var header = ByteWriter()
    header.ascii("DVDVIDEO-VMG")
    header.u16(titleSets.count, at: 0x3E)  // Title Set count
    header.u32(1, at: 0xC4)  // title table Sector
    return layOutIFO(header: header, tables: [titleTable])
  }
}

/// An entry in the Disc's title table.
struct TestTitle {
  var titleSet = 1
  var titleInSet = 1
  var chapterCount = 1
  var angles = 1
}

struct TestTitleSet {
  var audio: [TestAudio] = []
  var subtitles: [TestSubtitle] = []
  /// For each Title in the set, its Chapters as (program chain, program) pairs, 1-based.
  var chapters: [[(programChain: Int, program: Int)]] = []
  var programChains: [TestProgramChain] = []

  fileprivate func ifo() -> Data {
    var chapterTable = ByteWriter()
    chapterTable.u16(chapters.count)
    chapterTable.u16(0)  // reserved
    let listsStart = 8 + 4 * chapters.count
    let end = listsStart + 4 * chapters.joined().count - 1
    chapterTable.u32(end)  // last byte of the table
    var offset = listsStart
    for list in chapters {
      chapterTable.u32(offset)  // this Title's Chapter list
      offset += 4 * list.count
    }
    for (programChain, program) in chapters.joined() {
      chapterTable.u16(programChain)
      chapterTable.u16(program)
    }

    var programChainTable = ByteWriter()
    programChainTable.u16(programChains.count)
    programChainTable.u16(0)  // reserved
    let encoded = programChains.map { $0.bytes() }
    let tableSize = 8 + 8 * programChains.count + encoded.map(\.count).reduce(0, +)
    programChainTable.u32(tableSize - 1)  // last byte of the table
    var programChainOffset = 8 + 8 * programChains.count
    for (chain, bytes) in zip(programChains, encoded) {
      programChainTable.u8(0x80 | chain.titleInSet)  // entry chain flag | Title
      programChainTable.u8(0)  // menu and block types
      programChainTable.u16(0)  // parental mask
      programChainTable.u32(programChainOffset)
      programChainOffset += bytes.count
    }
    for bytes in encoded { programChainTable.bytes(bytes) }

    var header = ByteWriter()
    header.ascii("DVDVIDEO-VTS")
    header.u16(audio.count, at: 0x202)  // audio stream count
    for (index, track) in audio.enumerated() {
      let offset = 0x204 + 8 * index  // audio attributes
      // Coding mode | language present.
      header.u8(track.codingMode << 5 | (track.language == nil ? 0 : 1) << 2, at: offset)
      header.u8(track.channels - 1, at: offset + 1)  // channel count - 1
      header.ascii(track.language ?? "\0\0", at: offset + 2)  // language code
      header.u8(track.codeExtension, at: offset + 5)  // kind
    }
    header.u16(subtitles.count, at: 0x254)  // subtitle stream count
    for (index, track) in subtitles.enumerated() {
      let offset = 0x256 + 6 * index  // subtitle attributes
      header.u8(track.language == nil ? 0 : 1, at: offset)  // language present
      header.ascii(track.language ?? "\0\0", at: offset + 2)  // language code
      header.u8(track.codeExtension, at: offset + 5)  // kind
    }

    let chapterTableSectors = chapterTable.sectorCount
    header.u32(1, at: 0xC8)  // Chapter table Sector
    header.u32(1 + chapterTableSectors, at: 0xCC)  // program chain table Sector
    return layOutIFO(header: header, tables: [chapterTable, programChainTable])
  }
}

struct TestAudio {
  /// 0 AC-3, 2 MPEG-1, 3 MPEG-2, 4 LPCM, 6 DTS.
  var codingMode = 0
  var channels = 2
  var language: String? = "en"
  /// 1 normal, 2 visually impaired, 3 director's comments, 4 alternate director's comments.
  var codeExtension = 1
}

struct TestSubtitle {
  var language: String? = "en"
  /// 1 normal, 2 large, 3 children, 5–7 captions, 9 forced, 13–15 director's comments.
  var codeExtension = 1
}

/// A program chain: Cells in playback order, the programs (Chapter entry points)
/// that start at them, and the streams it uses.
struct TestProgramChain {
  var titleInSet = 1
  var playbackTime = TestTime(seconds: 0)
  var cells: [TestCell] = []
  /// Entry Cell of each program, 1-based.
  var programs = [1]
  /// Audio stream numbers the chain uses, as indices into the Title Set's audio.
  var audioStreams: [Int] = []
  var subtitleStreams: [Int] = []

  fileprivate func bytes() -> Data {
    let headerSize = 0xEC
    let programMapSize = (programs.count + 1) & ~1
    let cellPlaybackOffset = headerSize + programMapSize
    let cellPositionOffset = cellPlaybackOffset + 24 * cells.count

    var chain = ByteWriter()
    chain.u8(programs.count, at: 2)  // program count
    chain.u8(cells.count, at: 3)  // Cell count
    chain.bytes(playbackTime.bcd, at: 4)  // playback time
    for stream in audioStreams {
      chain.u8(0x80 | stream, at: 0x0C + 2 * stream)  // audio stream control: used | stream
    }
    for stream in subtitleStreams {
      chain.u8(0x80 | stream, at: 0x1C + 4 * stream)  // subtitle stream control: used | stream
    }
    chain.u16(headerSize, at: 0xE6)  // program map offset
    chain.u16(cellPlaybackOffset, at: 0xE8)  // Cell playback table offset
    chain.u16(cellPositionOffset, at: 0xEA)  // Cell position table offset
    for (index, entryCell) in programs.enumerated() {
      chain.u8(entryCell, at: headerSize + index)
    }
    for (index, cell) in cells.enumerated() {
      let offset = cellPlaybackOffset + 24 * index
      let flags =
        cell.angleBlock.rawValue << 4 | (cell.seamless ? 0x08 : 0) | (cell.interleaved ? 0x04 : 0)
      chain.u8(flags, at: offset)  // block mode and type | seamless | interleaved
      chain.bytes(cell.playbackTime.bcd, at: offset + 4)  // playback time
      chain.u32(cell.firstSector, at: offset + 8)  // first Sector
      chain.u32(cell.lastSector - 1, at: offset + 16)  // last VOBU's first Sector
      chain.u32(cell.lastSector, at: offset + 20)  // last Sector
    }
    for (index, _) in cells.enumerated() {
      chain.u16(1, at: cellPositionOffset + 4 * index)  // VOB ID
      chain.u8(index + 1, at: cellPositionOffset + 4 * index + 3)  // Cell ID
    }
    chain.pad(to: cellPositionOffset + 4 * cells.count)
    return chain.data
  }
}

struct TestCell {
  enum AngleBlock: Int {
    case none = 0
    case firstAngle = 0b0101
    case lastAngle = 0b1101
  }

  var playbackTime = TestTime(seconds: 0)
  var firstSector = 0
  var lastSector = 0
  var angleBlock = AngleBlock.none
  var seamless = false
  var interleaved = false
}

/// A playback time as IFOs store it: BCD hours, minutes, seconds and frames.
struct TestTime {
  var hours = 0
  var minutes = 0
  var seconds = 0
  var frames = 0
  var framesPerSecond = 25

  var bcd: Data {
    func bcd(_ value: Int) -> UInt8 { UInt8((value / 10) << 4 | value % 10) }
    let rate: UInt8 = framesPerSecond == 25 ? 0b01 : 0b11
    return Data([bcd(hours), bcd(minutes), bcd(seconds), rate << 6 | bcd(frames)])
  }
}

/// Lays out an IFO: the header in sector 0, then each table starting on its own sector.
private func layOutIFO(header: ByteWriter, tables: [ByteWriter]) -> Data {
  var header = header
  let lastSector = tables.map(\.sectorCount).reduce(0, +)
  header.u32(lastSector, at: 0x1C)  // the IFO's last Sector
  header.pad(to: Sector.size)
  var data = header.data
  for table in tables {
    var table = table
    table.pad(to: table.sectorCount * Sector.size)
    data += table.data
  }
  return data
}

/// Writes big-endian fields, appending or at a fixed offset, growing as needed.
struct ByteWriter {
  private(set) var data = Data()

  var sectorCount: Int { max(1, (data.count + Sector.size - 1) / Sector.size) }

  mutating func pad(to count: Int) {
    if data.count < count { data.append(Data(count: count - data.count)) }
  }

  mutating func bytes(_ bytes: Data, at offset: Int? = nil) {
    let offset = offset ?? data.count
    pad(to: offset + bytes.count)
    data.replaceSubrange(offset..<offset + bytes.count, with: bytes)
  }

  mutating func u8(_ value: Int, at offset: Int? = nil) {
    bytes(Data([UInt8(value)]), at: offset)
  }

  mutating func u16(_ value: Int, at offset: Int? = nil) {
    bytes(Data([UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]), at: offset)
  }

  mutating func u32(_ value: Int, at offset: Int? = nil) {
    let bytes = (0..<4).reversed().map { UInt8(value >> ($0 * 8) & 0xFF) }
    self.bytes(Data(bytes), at: offset)
  }

  mutating func ascii(_ string: String, at offset: Int? = nil) {
    bytes(Data(string.utf8), at: offset)
  }
}
