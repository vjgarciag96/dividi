import Foundation

/// A Title Set's VOB files read as the one run of Sectors that Cells count through.
///
/// On disk the run is split into `VTS_xx_1.VOB`, `VTS_xx_2.VOB` and so on, each up to 1 GB.
struct TitleSetVOBs {
  /// The 1-based Title Set.
  let titleSet: Int
  let source: any SectorSource

  /// Reads Sectors of the run, joining the files they're split across.
  func readSectors(_ sectors: ClosedRange<Int>) throws -> Data {
    var data = Data()
    var fileStart = 0
    var fileNumber = 1
    while fileStart <= sectors.upperBound {
      let file = String(format: "VTS_%02d_%d.VOB", titleSet, fileNumber)
      let fileEnd = fileStart + (try source.sectorCount(of: file))
      let first = max(sectors.lowerBound, fileStart)
      let last = min(sectors.upperBound, fileEnd - 1)
      if first <= last {
        data += try source.readSectors((first - fileStart)...(last - fileStart), of: file)
      }
      fileStart = fileEnd
      fileNumber += 1
    }
    return data
  }
}
