import Foundation

// Format-level views of the IFO files, as laid out by the DVD-Video specification.
// Byte offsets are named after the fields they point to; sizes are in the comments.

/// Fields at the same place in every IFO header.
enum IFOHeader {
  /// The last Sector of the IFO itself (u32).
  static let lastSector = 0x1C
}

/// `VIDEO_TS.IFO`: the Disc's title table.
struct VideoManagerIFO {
  struct TitleEntry {
    let titleSet: Int
    let titleInSet: Int
  }

  private enum Header {
    /// The number of Title Sets on the Disc (u16).
    static let titleSetCount = 0x3E
    /// The Sector where the title table starts (u32).
    static let titleTableSector = 0xC4
  }

  /// The title table (`TT_SRPT`): a count, then one 12-byte entry per Title.
  private enum TitleTable {
    /// The number of Titles (u16).
    static let titleCount = 0
    static let firstEntry = 8
    static let entrySize = 12
    /// Within an entry: the Title Set holding the Title (u8).
    static let titleSet = 6
    /// Within an entry: the Title's number within its Title Set (u8).
    static let titleInSet = 7
  }

  let titleSetCount: Int
  let titles: [TitleEntry]

  init(_ data: Data) throws(DiscError.Reason) {
    let ifo = ByteReader(data)
    guard try ifo.bytes(at: 0, count: 12) == Array("DVDVIDEO-VMG".utf8) else { throw .notAnIFO }
    titleSetCount = try ifo.u16(at: Header.titleSetCount)

    let table = try ifo.u32(at: Header.titleTableSector) * Sector.size
    var titles: [TitleEntry] = []
    for index in 0..<(try ifo.u16(at: table + TitleTable.titleCount)) {
      let entry = table + TitleTable.firstEntry + TitleTable.entrySize * index
      titles.append(
        TitleEntry(
          titleSet: try ifo.u8(at: entry + TitleTable.titleSet),
          titleInSet: try ifo.u8(at: entry + TitleTable.titleInSet)))
    }
    self.titles = titles
  }
}
