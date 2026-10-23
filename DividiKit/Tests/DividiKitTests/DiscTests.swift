import Foundation
import Testing

@testable import DividiKit

@Test func singleCellTitle() throws {
  let disc = TestDisc(
    titles: [TestTitle(titleSet: 1, titleInSet: 1, chapterCount: 1)],
    titleSets: [
      TestTitleSet(
        audio: [TestAudio(codingMode: 0, channels: 6, language: "en", codeExtension: 1)],
        chapters: [[(programChain: 1, program: 1)]],
        programChains: [
          TestProgramChain(
            playbackTime: TestTime(minutes: 1, seconds: 30, frames: 12),
            cells: [
              TestCell(
                playbackTime: TestTime(minutes: 1, seconds: 30, frames: 12),
                firstSector: 0, lastSector: 999)
            ],
            programs: [1],
            audioStreams: [0])
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
        cells: [Cell(sectors: 0...999, duration: .milliseconds(90_480))],
        audioTracks: [AudioTrack(codec: .ac3, channels: 6, language: "en", kind: .normal)],
        subtitleTracks: [],
        unsupportedReason: nil)
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

@Test func titleListsOnlyTheTracksItUses() throws {
  let disc = TestDisc(
    titles: [TestTitle()],
    titleSets: [
      TestTitleSet(
        audio: [
          TestAudio(codingMode: 0, channels: 6, language: "en", codeExtension: 1),
          TestAudio(codingMode: 6, channels: 6, language: "de", codeExtension: 1),
          TestAudio(codingMode: 0, channels: 2, language: "en", codeExtension: 3),
          TestAudio(codingMode: 4, channels: 2, language: nil, codeExtension: 0),
        ],
        subtitles: [
          TestSubtitle(language: "en", codeExtension: 1),
          TestSubtitle(language: "fr", codeExtension: 1),
          TestSubtitle(language: "en", codeExtension: 9),
        ],
        chapters: [[(programChain: 1, program: 1)]],
        programChains: [
          TestProgramChain(
            cells: [TestCell()],
            audioStreams: [0, 2, 3],
            subtitleStreams: [0, 2])
        ])
    ])

  let title = try #require(try Disc(reading: disc.source).titles.first)

  #expect(
    title.audioTracks == [
      AudioTrack(codec: .ac3, channels: 6, language: "en", kind: .normal),
      AudioTrack(codec: .ac3, channels: 2, language: "en", kind: .directorsComments),
      AudioTrack(codec: .lpcm, channels: 2, language: nil, kind: .unspecified),
    ])
  #expect(
    title.subtitleTracks == [
      SubtitleTrack(language: "en", kind: .normal),
      SubtitleTrack(language: "en", kind: .forced),
    ])
}

@Test func multiAngleTitleIsUnsupported() throws {
  let angleCells = [
    TestCell(firstSector: 0, lastSector: 99, angleBlock: .firstAngle, interleaved: true),
    TestCell(firstSector: 100, lastSector: 199, angleBlock: .lastAngle, interleaved: true),
  ]
  let disc = TestDisc(
    titles: [TestTitle(angles: 2)],
    titleSets: [
      TestTitleSet(
        chapters: [[(programChain: 1, program: 1)]],
        programChains: [TestProgramChain(cells: angleCells)])
    ])

  let title = try #require(try Disc(reading: disc.source).titles.first)

  #expect(title.unsupportedReason == .multiAngle)
}

@Test func seamlessBranchingTitleIsUnsupported() throws {
  let disc = TestDisc(
    titles: [TestTitle()],
    titleSets: [
      TestTitleSet(
        chapters: [[(programChain: 1, program: 1)]],
        programChains: [
          TestProgramChain(cells: [
            TestCell(firstSector: 0, lastSector: 99),
            TestCell(firstSector: 100, lastSector: 199, seamless: true, interleaved: true),
          ])
        ])
    ])

  let title = try #require(try Disc(reading: disc.source).titles.first)

  #expect(title.unsupportedReason == .seamlessBranching)
}

@Test func seamlessCellsWithoutInterleavingAreSupported() throws {
  let disc = TestDisc(
    titles: [TestTitle()],
    titleSets: [
      TestTitleSet(
        chapters: [[(programChain: 1, program: 1)]],
        programChains: [
          TestProgramChain(cells: [
            TestCell(firstSector: 0, lastSector: 99),
            TestCell(firstSector: 100, lastSector: 199, seamless: true),
          ])
        ])
    ])

  let title = try #require(try Disc(reading: disc.source).titles.first)

  #expect(title.unsupportedReason == nil)
}

@Test func titleSpanningProgramChainsPlaysThemInChapterOrder() throws {
  let disc = TestDisc(
    titles: [TestTitle(chapterCount: 3)],
    titleSets: [
      TestTitleSet(
        chapters: [
          [
            (programChain: 2, program: 1), (programChain: 2, program: 2),
            (programChain: 1, program: 1),
          ]
        ],
        programChains: [
          TestProgramChain(
            playbackTime: TestTime(minutes: 5),
            cells: [TestCell(playbackTime: TestTime(minutes: 5), firstSector: 0, lastSector: 99)]),
          TestProgramChain(
            playbackTime: TestTime(minutes: 10),
            cells: [
              TestCell(playbackTime: TestTime(minutes: 4), firstSector: 100, lastSector: 199),
              TestCell(playbackTime: TestTime(minutes: 6), firstSector: 200, lastSector: 299),
            ],
            programs: [1, 2]),
        ])
    ])

  let title = try #require(try Disc(reading: disc.source).titles.first)

  #expect(title.duration == .seconds(15 * 60))
  #expect(title.cells.map(\.sectors) == [100...199, 200...299, 0...99])
  #expect(
    title.chapters == [
      Chapter(start: .zero, duration: .seconds(240)),
      Chapter(start: .seconds(240), duration: .seconds(360)),
      Chapter(start: .seconds(600), duration: .seconds(300)),
    ])
}

@Test func titleSpanningProgramChainsListsTracksUsedByAnyOfThem() throws {
  let disc = TestDisc(
    titles: [TestTitle(chapterCount: 2)],
    titleSets: [
      TestTitleSet(
        audio: [TestAudio(language: "en"), TestAudio(language: "fr")],
        subtitles: [TestSubtitle(language: "en"), TestSubtitle(language: "fr")],
        chapters: [[(programChain: 1, program: 1), (programChain: 2, program: 1)]],
        programChains: [
          TestProgramChain(cells: [TestCell()], audioStreams: [0], subtitleStreams: []),
          TestProgramChain(cells: [TestCell()], audioStreams: [1], subtitleStreams: [1]),
        ])
    ])

  let title = try #require(try Disc(reading: disc.source).titles.first)

  #expect(title.audioTracks.map(\.language) == ["en", "fr"])
  #expect(title.subtitleTracks.map(\.language) == ["fr"])
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
