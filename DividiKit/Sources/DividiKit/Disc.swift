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
    guard titleSet.chapters.indices.contains(entry.titleInSet - 1) else {
      throw .invalidReference("Title \(number) is missing from its Title Set")
    }
    let chapterEntries = titleSet.chapters[entry.titleInSet - 1]

    // The Title plays its program chains in the order its Chapters first reach them.
    var chainNumbers: [Int] = []
    for chapter in chapterEntries where !chainNumbers.contains(chapter.programChain) {
      guard titleSet.programChains.indices.contains(chapter.programChain - 1) else {
        throw .invalidReference("Title \(number) has a Chapter in a missing program chain")
      }
      chainNumbers.append(chapter.programChain)
    }
    let chains = chainNumbers.map { titleSet.programChains[$0 - 1] }
    guard !chains.isEmpty else {
      throw .invalidReference("Title \(number) has no Chapters")
    }

    // Offset of each Cell from the start of the Title, by program chain.
    var cellStarts: [Int: [Duration]] = [:]
    var elapsed = Duration.zero
    for (chainNumber, chain) in zip(chainNumbers, chains) {
      var cellStart = elapsed
      cellStarts[chainNumber] = chain.cells.map { cell in
        defer { cellStart += cell.playbackTime }
        return cellStart
      }
      elapsed += chain.playbackTime
    }

    var chapterStarts: [Duration] = []
    for chapter in chapterEntries {
      let programs = titleSet.programChains[chapter.programChain - 1].programs
      let starts = cellStarts[chapter.programChain] ?? []
      guard programs.indices.contains(chapter.program - 1),
        starts.indices.contains(programs[chapter.program - 1] - 1)
      else { throw .invalidReference("Title \(number) has a Chapter with no Cell") }
      chapterStarts.append(starts[programs[chapter.program - 1] - 1])
    }

    let cells = chains.flatMap(\.cells)
    self.number = number
    self.titleSet = entry.titleSet
    duration = elapsed
    chapters = zip(chapterStarts, chapterStarts.dropFirst() + [elapsed]).map {
      Chapter(start: $0, duration: $1 - $0)
    }
    self.cells = cells.map { Cell(sectors: $0.sectors, duration: $0.playbackTime) }
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
    let lastSector = try ByteReader(header).u32(at: IFOHeader.lastSector)
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
