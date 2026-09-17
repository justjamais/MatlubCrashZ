import SwiftUI

public extension View {
    /// Records a "screen: <name>" breadcrumb every time this view appears. Use it on your top-level screens:
    /// `HomeView().crashScreen("Home")`.
    func crashScreen(_ name: String) -> some View {
        onAppear { MatlubCrashZ.log("screen: \(name)", category: "navigation") }
    }
}
