import Foundation
import Testing

@testable import DividiKit

@Test func titlesFollowTheTitleTableAcrossTitleSets() throws {
  let disc = TestDisc(
    titles: [
      TestTitle(titleSet: 2, titleInSet: 1),
      TestTitle(titleSet: 1, titleInSet: 2),
      TestTitle(titleSet: 1, titleInSet: 1),
    ],
    titleSets: [TestTitleSet(), TestTitleSet()])

  let titles = try Disc(reading: disc.source).titles

  #expect(
    titles == [
      Title(number: 1, titleSet: 2),
      Title(number: 2, titleSet: 1),
      Title(number: 3, titleSet: 1),
    ])
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

@Test func missingDiscIFOFailsTheSource() {
  var source = TestDisc(titles: [TestTitle()], titleSets: [TestTitleSet()]).source
  source.files["VIDEO_TS.IFO"] = nil

  #expect {
    try Disc(reading: source)
  } throws: { error in
    (error as? DiscError)?.file == "VIDEO_TS.IFO"
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
