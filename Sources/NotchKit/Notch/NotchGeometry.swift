import CoreGraphics

/// Pure layout maths, kept free of AppKit so it can be tested.
enum NotchGeometry {
    static let expandedSize = CGSize(width: 600, height: 160)

    /// The notch in global screen coordinates (origin bottom-left), or nil when the screen has none.
    /// `leftAux` / `rightAux` are the widths of NSScreen.auxiliaryTopLeftArea / auxiliaryTopRightArea.
    static func notchRect(screen: CGRect, safeTop: CGFloat, leftAux: CGFloat?, rightAux: CGFloat?) -> CGRect? {
        guard safeTop > 0, let leftAux, let rightAux else { return nil }
        let width = screen.width - leftAux - rightAux
        guard width > 0 else { return nil }
        return CGRect(x: screen.minX + leftAux, y: screen.maxY - safeTop, width: width, height: safeTop)
    }

    /// The expanded panel hangs from the top edge of the notch, centred on it.
    static func expandedRect(around notch: CGRect) -> CGRect {
        CGRect(x: notch.midX - expandedSize.width / 2, y: notch.maxY - expandedSize.height,
               width: expandedSize.width, height: expandedSize.height)
    }

    /// Both rects in CoreGraphics display coordinates (origin top-left).
    /// A fullscreen window spans the display and starts at or above the bottom of the notch;
    /// a zoomed window starts below the menu bar, which is taller than the notch.
    // ponytail: bounds heuristic, relies on menu bar height > safeTop (38 vs 37 here). If it
    // misfires on another Mac, switch to checking for the Window Server's layer-24 menu bar window.
    static func isFullscreen(window: CGRect, display: CGRect, safeTop: CGFloat) -> Bool {
        window.intersection(display).width >= display.width
            && window.minY - display.minY <= safeTop
            && window.maxY >= display.maxY
    }
}
