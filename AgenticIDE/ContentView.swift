import SwiftUI

struct ContentView: View {
    var body: some View {
        GhosttyTerminal()
            .ignoresSafeArea()
    }
}

#Preview {
    ContentView()
        .frame(width: 800, height: 500)
}
