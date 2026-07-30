import SwiftUI
import PRMasterCore

extension RGB {
    /// The only place a palette value becomes a concrete `Color`.
    ///
    /// This used to map `ReadinessTint` straight onto `Color.green`, `.yellow`
    /// and friends. Those are Apple's system colours, tuned for large fills, and
    /// as 11pt text on a light popover they measured 1.28:1 to 3.40:1 against a
    /// 4.5:1 floor. The mapping now goes through `Palette`, which is verified,
    /// and reaches views as `\.palette` in the environment so it can vary with
    /// the appearance and the contrast the user asked for.
    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue)
    }
}
