import SwiftUI

/// Small cross-platform shims so the same views build for iOS and macOS.
/// Each shim keeps the iOS behaviour unchanged and picks the idiomatic macOS equivalent.
extension View {
    /// iOS shows pushed and sheet titles inline; macOS has no navigation-bar display mode.
    @ViewBuilder func muralInlineTitleDisplayMode() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// iOS sheets size with medium/large detents; macOS sheets take a comfortable fixed frame.
    @ViewBuilder func muralSheetSizing() -> some View {
        #if os(iOS)
        presentationDetents([.medium, .large])
        #else
        frame(minWidth: 420, idealWidth: 540, minHeight: 360, idealHeight: 520)
        #endif
    }

    /// The full-height variant used by onboarding and the AI consent sheet.
    @ViewBuilder func muralLargeSheetSizing() -> some View {
        #if os(iOS)
        presentationDetents([.large])
        #else
        frame(minWidth: 460, idealWidth: 560, minHeight: 460, idealHeight: 620)
        #endif
    }

    /// iOS text fields can disable autocapitalisation; macOS has no such modifier.
    @ViewBuilder func muralNoAutocapitalization() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never)
        #else
        self
        #endif
    }

    /// Onboarding and AI consent must not be swiped away on iOS. macOS has no equivalent modifier; RootView re-presents onboarding when an incomplete sheet is dismissed, and the AI consent flow handles its own dismissal.
    @ViewBuilder func muralInteractiveDismissDisabled() -> some View {
        #if os(iOS)
        interactiveDismissDisabled()
        #else
        self
        #endif
    }

    /// The warm background behind the toolbar: navigation bar on iOS, window toolbar on macOS.
    @ViewBuilder func muralToolbarBackground() -> some View {
        #if os(iOS)
        toolbarBackground(MuralColor.cream, for: .navigationBar)
        #else
        toolbarBackground(MuralColor.cream, for: .windowToolbar)
        #endif
    }
}

enum PlatformInfo {
    /// User-facing copy that named the iPhone before the Mac version existed.
    static let deviceName: String = {
        #if os(iOS)
        return "this iPhone"
        #else
        return "this Mac"
        #endif
    }()
}
