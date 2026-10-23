import DividiKit
import SwiftUI

struct ContentView: View {
  private enum Phase {
    case empty
    case reading
    case read([Title])
    case failed(String)
  }

  @State private var phase = Phase.empty
  @State private var isPickingFolder = false
  @State private var folder: URL?

  var body: some View {
    content
      .frame(minWidth: 720, minHeight: 320)
      .navigationSubtitle(folder?.lastPathComponent ?? "")
      .toolbar {
        Button("Open…", systemImage: "folder") { isPickingFolder = true }
          .disabled(isReading)
      }
      .fileImporter(isPresented: $isPickingFolder, allowedContentTypes: [.folder]) { result in
        if case .success(let url) = result { read(url) }
      }
  }

  @ViewBuilder private var content: some View {
    switch phase {
    case .empty:
      ContentUnavailableView {
        Label("No Source", systemImage: "opticaldiscdrive")
      } description: {
        Text("Open a VIDEO_TS folder, or the folder containing it.")
      } actions: {
        Button("Open…") { isPickingFolder = true }
      }
    case .reading:
      ProgressView("Reading Disc…")
    case .read(let titles):
      TitleTable(titles: titles)
    case .failed(let message):
      ContentUnavailableView(
        "Couldn't Read Disc", systemImage: "exclamationmark.triangle",
        description: Text(message))
    }
  }

  private var isReading: Bool {
    if case .reading = phase { true } else { false }
  }

  private func read(_ url: URL) {
    folder = url
    phase = .reading
    Task {
      let accessing = url.startAccessingSecurityScopedResource()
      defer { if accessing { url.stopAccessingSecurityScopedResource() } }
      do {
        let disc = try await Task.detached { try Disc(reading: FolderSource(url: url)) }.value
        phase = .read(disc.titles)
      } catch {
        phase = .failed(error.localizedDescription)
      }
    }
  }
}

private struct TitleTable: View {
  let titles: [Title]

  var body: some View {
    Table(titles) {
      TableColumn("Title") { Text($0.number, format: .number) }
        .width(40)
      TableColumn("Duration") { Text($0.duration, format: .time(pattern: .hourMinuteSecond)) }
        .width(70)
      TableColumn("Chapters") { Text($0.chapters.count, format: .number) }
        .width(60)
      TableColumn("Audio") {
        Text($0.audioTracks.map(\.label).formatted(.list(type: .and, width: .narrow)))
      }
      TableColumn("Subtitles") {
        Text($0.subtitleTracks.map(\.label).formatted(.list(type: .and, width: .narrow)))
      }
      TableColumn("Status") { Text($0.status) }
        .width(min: 80, ideal: 160)
    }
  }
}

extension Title {
  fileprivate var status: String {
    switch unsupportedReason {
    case nil: String(localized: "OK", comment: "Status of a Title dividi can extract")
    case .multiAngle:
      String(localized: "Unsupported: multi-angle", comment: "Status of a multi-angle Title")
    case .seamlessBranching:
      String(
        localized: "Unsupported: seamless branching",
        comment: "Status of a Title using seamless branching")
    }
  }
}

extension AudioTrack {
  /// E.g. "en AC-3 6ch (commentary)".
  fileprivate var label: String {
    let language = language ?? unknownLanguage
    let codec =
      switch codec {
      case .ac3: "AC-3"
      case .mpeg1: "MPEG-1"
      case .mpeg2: "MPEG-2"
      case .lpcm: "LPCM"
      case .dts: "DTS"
      case .unknown: String(localized: "unknown", comment: "Codec of an audio Track")
      }
    let kind: String? =
      switch kind {
      case .unspecified, .normal: nil
      case .visuallyImpaired:
        String(localized: "visually impaired", comment: "Kind of audio Track")
      case .directorsComments, .alternateDirectorsComments:
        String(localized: "commentary", comment: "Kind of audio or subtitle Track")
      }
    guard let kind else {
      return String(
        localized: "\(language) \(codec) \(channels)ch",
        comment: "Audio Track: language code, codec, channel count")
    }
    return String(
      localized: "\(language) \(codec) \(channels)ch (\(kind))",
      comment: "Audio Track: language code, codec, channel count, kind")
  }
}

extension SubtitleTrack {
  /// E.g. "en (forced)".
  fileprivate var label: String {
    let language = language ?? unknownLanguage
    let kind: String? =
      switch kind {
      case .unspecified, .normal: nil
      case .large: String(localized: "large", comment: "Kind of subtitle Track")
      case .children: String(localized: "children", comment: "Kind of subtitle Track")
      case .captions: String(localized: "captions", comment: "Kind of subtitle Track")
      case .largeCaptions: String(localized: "large captions", comment: "Kind of subtitle Track")
      case .childrensCaptions:
        String(localized: "children's captions", comment: "Kind of subtitle Track")
      case .forced: String(localized: "forced", comment: "Kind of subtitle Track")
      case .directorsComments, .largeDirectorsComments, .childrensDirectorsComments:
        String(localized: "commentary", comment: "Kind of audio or subtitle Track")
      }
    guard let kind else { return language }
    return String(
      localized: "\(language) (\(kind))", comment: "Subtitle Track: language code, kind")
  }
}

/// Shown in place of a Track's language code when the Disc doesn't give one.
private let unknownLanguage = String(
  localized: "??", comment: "Placeholder for a Track's missing language code")

#Preview {
  ContentView()
}
