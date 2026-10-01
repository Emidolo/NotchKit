import CoreGraphics
import Testing
@testable import NotchKit

// Numbers measured on a 15" MacBook Air at 1920×1243.
private let screen = CGRect(x: 0, y: 0, width: 1920, height: 1243)

@Test func notchIsTheGapBetweenTheAuxiliaryAreas() {
    let notch = NotchGeometry.notchRect(screen: screen, safeTop: 37, leftAux: 856, rightAux: 856)
    #expect(notch == CGRect(x: 856, y: 1206, width: 208, height: 37))
}

@Test func noNotchWithoutSafeAreaOrAuxiliaryAreas() {
    #expect(NotchGeometry.notchRect(screen: screen, safeTop: 0, leftAux: nil, rightAux: nil) == nil)
    #expect(NotchGeometry.notchRect(screen: screen, safeTop: 37, leftAux: nil, rightAux: nil) == nil)
}

@Test func notchFollowsAScreenThatIsNotAtTheOrigin() {
    let offset = screen.offsetBy(dx: -1920, dy: 300)
    let notch = NotchGeometry.notchRect(screen: offset, safeTop: 37, leftAux: 856, rightAux: 856)
    #expect(notch == CGRect(x: -1064, y: 1506, width: 208, height: 37))
}

@Test func expandedPanelHangsFromTheTopCentredOnTheNotch() {
    let rect = NotchGeometry.expandedRect(around: CGRect(x: 856, y: 1206, width: 208, height: 37))
    #expect(rect.midX == 960)
    #expect(rect.maxY == 1243)
    #expect(rect.size == NotchGeometry.expandedSize)
}

@Test func fullscreenVersusZoomedWindows() {
    let fullscreen = CGRect(x: 0, y: 37, width: 1920, height: 1206)
    let zoomed = CGRect(x: 0, y: 38, width: 1920, height: 1205)
    let ordinary = CGRect(x: 200, y: 100, width: 900, height: 700)
    #expect(NotchGeometry.isFullscreen(window: fullscreen, display: screen, safeTop: 37))
    #expect(!NotchGeometry.isFullscreen(window: zoomed, display: screen, safeTop: 37))
    #expect(!NotchGeometry.isFullscreen(window: ordinary, display: screen, safeTop: 37))
}
