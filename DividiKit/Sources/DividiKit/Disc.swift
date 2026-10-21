import Foundation

/// The DVD-Video structure exposed by a Source, as described by its IFO files.
public struct Disc: Sendable {
  /// The Titles reachable from the Disc's title table, in title-table order.
  public let titles: [Title]

  /// Reads and parses every IFO the title table needs. Any IFO that fails fails the whole Disc.
  public init(reading source: some SectorSource) throws(DiscError) {
    let managerFile = "VIDEO_TS.IFO"
    let manager = try parse(managerFile, from: source, as: VideoManagerIFO.init)

    var titleSets: [Int: TitleSetIFO] = [:]
    var titles: [Title] = []
    for (index, entry) in manager.titles.enumerated() {
      guard entry.titleSet >= 1, entry.titleSet <= manager.titleSetCount else {
        throw DiscError(
          file: managerFile,
          reason: .invalidReference("Title \(index + 1) is in missing Title Set \(entry.titleSet)"))
      }
      let titleSetFile = String(format: "VTS_%02d_0.IFO", entry.titleSet)
      let titleSet: TitleSetIFO
      if let parsed = titleSets[entry.titleSet] {
        titleSet = parsed
      } else {
        titleSet = try parse(titleSetFile, from: source, as: TitleSetIFO.init)
        titleSets[entry.titleSet] = titleSet
      }
      do {
        titles.append(try Title(number: index + 1, entry: entry, in: titleSet))
      } catch {
        throw DiscError(file: titleSetFile, reason: error)
      }
    }
    self.titles = titles
  }
}

/// Why a Source couldn't be read as a Disc.
public struct DiscError: Error, Equatable {
  public enum Reason: Error, Equatable, Sendable {
    /// The Source failed to read the file.
    case unreadable(String)
    /// The file doesn't start with an IFO signature.
    case notAnIFO
    /// A table runs past the end of the file.
    case truncated
    /// A table points at something that doesn't exist.
    case invalidReference(String)
  }

  /// The IFO that failed, e.g. `VTS_01_0.IFO`.
  public let file: String
  public let reason: Reason
}

extension DiscError: LocalizedError {
  public var errorDescription: String? {
    let reason =
      switch reason {
      case .unreadable(let description): description
      case .notAnIFO: "not an IFO file"
      case .truncated: "the file is truncated"
      case .invalidReference(let description): description
      }
    return "\(file): \(reason)"
  }
}

extension Title {
  /// Resolves a title-table entry through its Title Set's Chapters, program chains and Cells.
  fileprivate init(number: Int, entry: VideoManagerIFO.TitleEntry, in titleSet: TitleSetIFO)
    throws(DiscError.Reason)
  {
    guard let chapterEntries = titleSet.chapters[oneBased: entry.titleInSet] else {
      throw .invalidReference("Title \(number) is missing from its Title Set")
    }
    guard let chainNumber = chapterEntries.first?.programChain,
      let chain = titleSet.programChains[oneBased: chainNumber]
    else { throw .invalidReference("Title \(number) has no program chain") }
    guard chapterEntries.allSatisfy({ $0.programChain == chainNumber }) else {
      throw .invalidReference("Title \(number) spans several program chains")
    }

    // Offset of each Cell from the start of the Title.
    var cellStarts: [Duration] = []
    var elapsed = Duration.zero
    for cell in chain.cells {
      cellStarts.append(elapsed)
      elapsed += cell.playbackTime
    }

    var chapterStarts: [Duration] = []
    for chapter in chapterEntries {
      guard let entryCell = chain.programs[oneBased: chapter.program],
        let start = cellStarts[oneBased: entryCell]
      else { throw .invalidReference("Title \(number) has a Chapter with no Cell") }
      chapterStarts.append(start)
    }

    self.number = number
    self.titleSet = entry.titleSet
    duration = chain.playbackTime
    let ends = chapterStarts.dropFirst() + [chain.playbackTime]
    chapters = zip(chapterStarts, ends).map { start, end in
      Chapter(start: start, duration: end - start)
    }
    cells = chain.cells.map { Cell(sectors: $0.sectors, duration: $0.playbackTime) }
  }
}

/// Reads a whole IFO through the Source and parses it.
private func parse<IFO>(
  _ file: String, from source: some SectorSource,
  as parse: (Data) throws(DiscError.Reason) -> IFO
) throws(DiscError) -> IFO {
  let data: Data
  do {
    let header = try source.readSectors(0...0, of: file)
    // Every IFO header holds the IFO's own last Sector at 0x1C (u32).
    let lastSector = try ByteReader(header).u32(at: 0x1C)
    data = try source.readSectors(0...lastSector, of: file)
  } catch let reason as DiscError.Reason {
    throw DiscError(file: file, reason: reason)
  } catch {
    throw DiscError(file: file, reason: .unreadable(error.localizedDescription))
  }
  do {
    return try parse(data)
  } catch {
    throw DiscError(file: file, reason: error)
  }
}
