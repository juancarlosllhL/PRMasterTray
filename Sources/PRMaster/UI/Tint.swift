import SwiftUI
import PRMasterCore

extension ReadinessTint {
    /// The only place semantic tints become concrete colours.
    var color: Color {
        switch self {
        case .green:  return .green
        case .yellow: return .yellow
        case .blue:   return .blue
        case .red:    return .red
        case .orange: return .orange
        case .gray:   return .secondary
        }
    }
}
