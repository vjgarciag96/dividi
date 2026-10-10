import SwiftUI

struct ContentView: View {
  var body: some View {
    ContentUnavailableView("Dividi", systemImage: "opticaldiscdrive")
      .frame(minWidth: 480, minHeight: 320)
  }
}

#Preview {
  ContentView()
}
