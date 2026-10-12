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
      TableColumn("Audio") { Text($0.audioTracks.map(\.label).joined(separator: ", ")) }
      TableColumn("Subtitles") { Text($0.subtitleTracks.map(\.label).joined(separator: ", ")) }
      TableColumn("Status") { Text($0.status) }
        .width(min: 80, ideal: 160)
    }
  }
}

extension Title {
  fileprivate var status: String {
    switch unsupportedReason {
    case nil: "OK"
    case .multiAngle: "Unsupported: multi-angle"
    case .seamlessBranching: "Unsupported: seamless branching"
    }
  }
}

extension AudioTrack {
  /// E.g. "en AC-3 6ch (commentary)".
  fileprivate var label: String {
    let codec =
      switch codec {
      case .ac3: "AC-3"
      case .mpeg1: "MPEG-1"
      case .mpeg2: "MPEG-2"
      case .lpcm: "LPCM"
      case .dts: "DTS"
      case .unknown: "unknown"
      }
    let kind: String? =
      switch kind {
      case .unspecified, .normal: nil
      case .visuallyImpaired: "visually impaired"
      case .directorsComments, .alternateDirectorsComments: "commentary"
      }
    return ["\(language ?? "??") \(codec) \(channels)ch", kind.map { "(\($0))" }]
      .compactMap { $0 }.joined(separator: " ")
  }
}

extension SubtitleTrack {
  /// E.g. "en (forced)".
  fileprivate var label: String {
    let kind: String? =
      switch kind {
      case .unspecified, .normal: nil
      case .large: "large"
      case .children: "children"
      case .captions: "captions"
      case .largeCaptions: "large captions"
      case .childrensCaptions: "children's captions"
      case .forced: "forced"
      case .directorsComments, .largeDirectorsComments, .childrensDirectorsComments: "commentary"
      }
    return [language ?? "??", kind.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
  }
}

#Preview {
  ContentView()
}
