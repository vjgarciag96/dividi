import Foundation
import Testing

@testable import DividiKit

@Test func singleCellTitle() throws {
  let disc = TestDisc(
    titles: [TestTitle(titleSet: 1, titleInSet: 1, chapterCount: 1)],
    titleSets: [
      TestTitleSet(
        chapters: [[(programChain: 1, program: 1)]],
        programChains: [
          TestProgramChain(
            playbackTime: TestTime(minutes: 1, seconds: 30, frames: 12),
            cells: [
              TestCell(
                playbackTime: TestTime(minutes: 1, seconds: 30, frames: 12),
                firstSector: 0, lastSector: 999)
            ],
            programs: [1])
        ])
    ])

  let titles = try Disc(reading: disc.source).titles

  #expect(
    titles == [
      Title(
        number: 1,
        titleSet: 1,
        duration: .milliseconds(90_480),
        chapters: [Chapter(start: .zero, duration: .milliseconds(90_480))],
        cells: [Cell(sectors: 0...999, duration: .milliseconds(90_480))])
    ])
}

@Test func multiCellTitleKeepsCellsInPlaybackOrder() throws {
  let disc = TestDisc(
    titles: [TestTitle(titleSet: 1, titleInSet: 1, chapterCount: 2)],
    titleSets: [
      TestTitleSet(
        chapters: [[(programChain: 1, program: 1), (programChain: 1, program: 2)]],
        programChains: [
          TestProgramChain(
            playbackTime: TestTime(minutes: 22, seconds: 0),
            cells: [
              TestCell(playbackTime: TestTime(seconds: 30), firstSector: 5000, lastSector: 5999),
              TestCell(playbackTime: TestTime(minutes: 10), firstSector: 0, lastSector: 2999),
              TestCell(
                playbackTime: TestTime(minutes: 11, seconds: 30), firstSector: 3000,
                lastSector: 4999),
            ],
            programs: [1, 3])
        ])
    ])

  let title = try #require(try Disc(reading: disc.source).titles.first)

  #expect(title.duration == .seconds(22 * 60))
  #expect(
    title.cells == [
      Cell(sectors: 5000...5999, duration: .seconds(30)),
      Cell(sectors: 0...2999, duration: .seconds(600)),
      Cell(sectors: 3000...4999, duration: .seconds(690)),
    ])
  #expect(
    title.chapters == [
      Chapter(start: .zero, duration: .seconds(630)),
      Chapter(start: .seconds(630), duration: .seconds(690)),
    ])
}

@Test func titlesFollowTheTitleTableAcrossTitleSets() throws {
  func titleSet(durations: [Int]) -> TestTitleSet {
    TestTitleSet(
      chapters: durations.indices.map { [(programChain: $0 + 1, program: 1)] },
      programChains: durations.enumerated().map { index, minutes in
        TestProgramChain(
          titleInSet: index + 1, playbackTime: TestTime(minutes: minutes), cells: [TestCell()])
      })
  }
  let disc = TestDisc(
    titles: [
      TestTitle(titleSet: 2, titleInSet: 1),
      TestTitle(titleSet: 1, titleInSet: 2),
      TestTitle(titleSet: 1, titleInSet: 1),
    ],
    titleSets: [titleSet(durations: [20, 21]), titleSet(durations: [90])])

  let titles = try Disc(reading: disc.source).titles

  #expect(titles.map(\.number) == [1, 2, 3])
  #expect(titles.map(\.titleSet) == [2, 1, 1])
  #expect(titles.map(\.duration) == [.seconds(90 * 60), .seconds(21 * 60), .seconds(20 * 60)])
}

@Test func ntscFramesCountAt29_97FramesPerSecond() throws {
  let time = TestTime(seconds: 1, frames: 15, framesPerSecond: 30)
  let disc = TestDisc(
    titles: [TestTitle()],
    titleSets: [
      TestTitleSet(
        chapters: [[(programChain: 1, program: 1)]],
        programChains: [TestProgramChain(playbackTime: time, cells: [TestCell(playbackTime: time)])]
      )
    ])

  let title = try #require(try Disc(reading: disc.source).titles.first)

  #expect(title.duration == .seconds(1) + .nanoseconds(500_500_000))
}

private let oneTitleDisc = TestDisc(
  titles: [TestTitle()],
  titleSets: [
    TestTitleSet(
      chapters: [[(programChain: 1, program: 1)]],
      programChains: [TestProgramChain(cells: [TestCell()])])
  ])

@Test func missingDiscIFOFailsTheSource() {
  var source = oneTitleDisc.source
  source.files["VIDEO_TS.IFO"] = nil

  #expect {
    try Disc(reading: source)
  } throws: { error in
    (error as? DiscError)?.file == "VIDEO_TS.IFO"
  }
}

@Test func titleSetIFOWithoutSignatureFailsTheSource() {
  var source = oneTitleDisc.source
  source.files["VTS_01_0.IFO"]!.replaceSubrange(0..<12, with: Data("NOT-AN-IFO!!".utf8))

  #expect(throws: DiscError(file: "VTS_01_0.IFO", reason: .notAnIFO)) {
    try Disc(reading: source)
  }
}

@Test func truncatedTitleSetIFOFailsTheSource() {
  var source = oneTitleDisc.source
  source.files["VTS_01_0.IFO"] = source.files["VTS_01_0.IFO"]!.prefix(Sector.size)

  #expect(throws: DiscError(file: "VTS_01_0.IFO", reason: .truncated)) {
    try Disc(reading: source)
  }
}

@Test func titleInAMissingTitleSetFailsTheSource() {
  let disc = TestDisc(titles: [TestTitle(titleSet: 2)], titleSets: [TestTitleSet()])

  #expect(
    throws: DiscError(
      file: "VIDEO_TS.IFO", reason: .invalidReference("Title 1 is in missing Title Set 2"))
  ) {
    try Disc(reading: disc.source)
  }
}

@Test func discIFOWithoutSignatureFailsTheSource() {
  var source = TestDisc(titles: [TestTitle()], titleSets: [TestTitleSet()]).source
  source.files["VIDEO_TS.IFO"]!.replaceSubrange(0..<12, with: Data("NOT-AN-IFO!!".utf8))

  #expect(throws: DiscError(file: "VIDEO_TS.IFO", reason: .notAnIFO)) {
    try Disc(reading: source)
  }
}

@Test func discWithoutTitleSetsFailsTheSource() {
  let disc = TestDisc(titles: [TestTitle(titleSet: 1)], titleSets: [])

  #expect(
    throws: DiscError(
      file: "VIDEO_TS.IFO", reason: .invalidReference("Title 1 is in missing Title Set 1"))
  ) {
    try Disc(reading: disc.source)
  }
}
