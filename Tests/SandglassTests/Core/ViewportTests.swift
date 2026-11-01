import Testing
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import Sandglass

/// The zoom and pan model behind the photo canvas and the navigator.
@Suite("Viewport")
struct ViewportTests {

    private func viewport(image: CGSize = CGSize(width: 6000, height: 4000),
                          view: CGSize = CGSize(width: 1200, height: 800),
                          scale: CGFloat = 2) -> Viewport {
        Viewport(imageSize: image, viewSize: view, backingScale: scale)
    }

    private func close(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 0.0001) -> Bool {
        abs(a - b) <= tolerance
    }

    @Test("At fit the whole photo is visible, centred and letterboxed")
    func fitShowsWholePhoto() {
        let v = viewport(image: CGSize(width: 4000, height: 4000), view: CGSize(width: 1000, height: 500))
        #expect(close(v.fitScale, 0.125))
        #expect(v.imageFrame == CGRect(x: 250, y: 0, width: 500, height: 500))
        #expect(v.visibleRegion == CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(!v.isZoomedIn)
        #expect(!v.canPan)
    }

    @Test("Percentages are measured against real pixels")
    func pixelMagnification() {
        var v = viewport()
        #expect(close(v.pixelMagnification, 0.4), "6000 px into 1200 pt on a 2x screen is 40%")
        v.setZoom(v.actualPixelsZoom)
        #expect(close(v.pixelMagnification, 1))
        #expect(close(v.actualPixelsZoom, 2.5))
        #expect(close(v.maximumZoom, 40), "1600% is the ceiling")
        v.setZoom(1000)
        #expect(close(v.pixelMagnification, Viewport.maximumPixelMagnification))
    }

    @Test("Zoom never goes below fit or above the ceiling, whatever it is asked")
    func zoomIsClamped() {
        var v = viewport()
        v.setZoom(0.2)
        #expect(v.zoom == 1)
        v.setZoom(-5)
        #expect(v.zoom == 1)
        v.setZoom(.infinity)
        #expect(v.zoom == 1, "a non-finite request is ignored")
        v.setZoom(.nan)
        #expect(v.zoom == 1)
        v.magnify(by: 0)
        #expect(v.zoom == 1)
    }

    @Test("The point under the pointer stays under the pointer while zooming")
    func anchoredZoomKeepsPoint() {
        var v = viewport()
        v.setZoom(3)
        let anchor = CGPoint(x: 900, y: 250)
        let before = v.normalisedPoint(forViewPoint: anchor)
        v.magnify(by: 1.7, anchor: anchor)
        let after = v.normalisedPoint(forViewPoint: anchor)
        #expect(close(before.x, after.x) && close(before.y, after.y), "\(before) moved to \(after)")
    }

    @Test("Zooming in and back out about an off-centre point leaves no drift")
    func zoomDoesNotDrift() {
        var v = viewport()
        let anchor = CGPoint(x: 1150, y: 760)
        for _ in 0..<40 { v.magnify(by: 1.13, anchor: anchor) }
        for _ in 0..<40 { v.magnify(by: 1 / 1.13, anchor: anchor) }
        #expect(close(v.zoom, 1, 0.000_001))
        #expect(v.centre == CGPoint(x: 0.5, y: 0.5), "back at fit the photo is centred exactly")
        #expect(v.imageFrame == CGRect(x: 0, y: 0, width: 1200, height: 800))
    }

    @Test("Resizing the pane while zoomed keeps the magnification and the centre")
    func resizeKeepsMagnification() {
        var v = viewport()
        v.setZoom(v.actualPixelsZoom)
        v.setCentre(CGPoint(x: 0.3, y: 0.6))
        let centre = v.centre
        for _ in 0..<50 {
            v.setViewSize(CGSize(width: 900, height: 700))
            v.setViewSize(CGSize(width: 1600, height: 1000))
        }
        v.setViewSize(CGSize(width: 1200, height: 800))
        #expect(close(v.pixelMagnification, 1), "showing a panel at 100% leaves you at 100%")
        #expect(close(v.centre.x, centre.x) && close(v.centre.y, centre.y))
    }

    @Test("At fit, resizing keeps the photo fitted")
    func resizeAtFitStaysFit() {
        var v = viewport()
        v.setViewSize(CGSize(width: 700, height: 900))
        #expect(v.zoom == 1)
        #expect(v.visibleRegion == CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    @Test("A sharper bitmap of the same photo lands exactly where the old one was")
    func swappingResolutionKeepsFraming() {
        var v = viewport(image: CGSize(width: 2560, height: 1707))
        v.setZoom(4, anchor: CGPoint(x: 300, y: 200))
        let frame = v.imageFrame
        let region = v.visibleRegion
        // The full-resolution decode arrives: same photo, 2.34x the pixels.
        v.setImageSize(CGSize(width: 6000, height: 4000))
        #expect(close(v.imageFrame.minX, frame.minX, 0.5) && close(v.imageFrame.minY, frame.minY, 1.5))
        #expect(close(v.imageFrame.width, frame.width, 1) && close(v.imageFrame.height, frame.height, 1.5))
        #expect(close(v.visibleRegion.minX, region.minX, 0.001))
    }

    @Test("The photo can never be panned out of view")
    func panningStaysInBounds() {
        var v = viewport(image: CGSize(width: 600, height: 600), view: CGSize(width: 800, height: 600), scale: 1)
        v.setZoom(2)
        v.pan(by: CGSize(width: -100_000, height: -100_000))
        #expect(v.imageFrame.maxX >= 800 - 0.001 && v.imageFrame.maxY >= 600 - 0.001)
        v.pan(by: CGSize(width: 100_000, height: 100_000))
        #expect(v.imageFrame.minX <= 0.001 && v.imageFrame.minY <= 0.001)
        v.setCentre(CGPoint(x: 5, y: -5))
        #expect(v.visibleRegion.maxX <= 1 && v.visibleRegion.minY >= 0)
    }

    @Test("Dragging moves the photo with the pointer")
    func panFollowsDrag() {
        var v = viewport(image: CGSize(width: 600, height: 600), view: CGSize(width: 800, height: 600), scale: 1)
        v.setZoom(3)
        let before = v.imageFrame
        v.pan(by: CGSize(width: 40, height: -25))
        #expect(close(v.imageFrame.minX - before.minX, 40))
        #expect(close(v.imageFrame.minY - before.minY, -25))
    }

    @Test("A photo narrower than the pane stays centred horizontally while zooming")
    func narrowAxisStaysCentred() {
        var v = viewport(image: CGSize(width: 3000, height: 4500), view: CGSize(width: 1200, height: 800))
        v.magnify(by: 1.2, anchor: CGPoint(x: 1100, y: 400))
        #expect(v.centre.x == 0.5, "nothing to pan horizontally yet")
        #expect(close(v.imageFrame.midX, 600))
    }

    @Test("Zoom steps land on standard magnifications and return to fit")
    func zoomSteps() {
        var v = viewport()
        var seen: [Int] = []
        for _ in 0..<5 {
            v.setZoom(v.steppedZoom(.in))
            seen.append(Int((v.pixelMagnification * 100).rounded()))
        }
        #expect(seen == [50, 67, 100, 150, 200])
        for _ in 0..<5 { v.setZoom(v.steppedZoom(.out)) }
        #expect(v.zoom == 1)
        #expect(v.steppedZoom(.out) == 1)
    }

    @Test("Toggle zoom goes to 100% and back, or 2x fit for tiny photos")
    func toggleZoom() {
        var v = viewport()
        v.setZoom(v.toggledZoom())
        #expect(close(v.pixelMagnification, 1))
        v.setZoom(v.toggledZoom())
        #expect(v.zoom == 1)
        v.setZoom(v.toggledZoom(pixelMagnification: 2))
        #expect(close(v.pixelMagnification, 2))

        var tiny = viewport(image: CGSize(width: 160, height: 120))
        tiny.setZoom(tiny.toggledZoom())
        #expect(tiny.zoom == min(2, tiny.maximumZoom))
    }

    @Test("Compare panes can adopt each other's framing")
    func adoptFraming() {
        var left = viewport()
        left.setZoom(5, anchor: CGPoint(x: 100, y: 100))
        var right = viewport(image: CGSize(width: 6048, height: 4024), view: CGSize(width: 1200, height: 800))
        right.adopt(zoom: left.zoom, centre: left.centre)
        #expect(close(right.zoom, left.zoom))
        #expect(close(right.visibleRegion.minX, left.visibleRegion.minX, 0.002))
    }

    @Test("Without content nothing breaks")
    func emptyViewport() {
        var v = Viewport()
        v.setZoom(3, anchor: CGPoint(x: 10, y: 10))
        v.pan(by: CGSize(width: 50, height: 50))
        #expect(v.visibleRegion == CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(v.steppedZoom(.in) == 1)
        v.setViewSize(CGSize(width: 300, height: 200))
        v.setImageSize(CGSize(width: 30, height: 20))
        #expect(v.hasContent)
    }
}

@Suite("Scroll and pinch input")
struct ZoomInputTests {

    private func intent(dy: CGFloat, dx: CGFloat = 0, precise: Bool, inverted: Bool = false,
                        _ modifiers: InputModifiers = []) -> ScrollIntent {
        ZoomInput.interpret(deltaX: dx, deltaY: dy, hasPreciseDeltas: precise,
                            isDirectionInverted: inverted, modifiers: modifiers)
    }

    @Test("Rolling a wheel away zooms in, with or without natural scrolling")
    func wheelDirectionIsPhysical() {
        // Natural scrolling off: rolling away reports +1.
        guard case .zoom(let plain) = intent(dy: 1, precise: false) else {
            Issue.record("a wheel notch should zoom"); return
        }
        #expect(plain > 1)
        // Natural scrolling on: the same physical roll reports −1 and is flagged inverted.
        guard case .zoom(let natural) = intent(dy: -1, precise: false, inverted: true) else {
            Issue.record("a wheel notch should zoom"); return
        }
        #expect(natural == plain, "the same gesture must zoom the same way")
    }

    @Test("Zoom factors are bounded and symmetric")
    func factorsAreBounded() {
        for delta in [-1000, -40, -4, -1, -0.1, 0.1, 1, 4, 40, 1000] as [CGFloat] {
            for precise in [false, true] {
                let modifiers: InputModifiers = precise ? [.command] : []
                guard case .zoom(let factor) = intent(dy: delta, precise: precise, modifiers) else {
                    Issue.record("expected zoom for \(delta)"); continue
                }
                #expect(factor > 0.4 && factor < 2.5, "factor \(factor) for delta \(delta)")
                guard case .zoom(let opposite) = intent(dy: -delta, precise: precise, modifiers) else { continue }
                #expect(abs(factor * opposite - 1) < 0.000_001, "in then out must cancel exactly")
            }
        }
    }

    @Test("A trackpad pans, and zooms with a modifier held")
    func trackpadRouting() {
        #expect(intent(dy: 4, dx: -2, precise: true) == .pan(dx: -2, dy: 4))
        for modifier in [InputModifiers.command, .option, .control] {
            if case .zoom = intent(dy: 4, precise: true, modifier) {} else {
                Issue.record("modifier-scroll on a trackpad should zoom")
            }
        }
    }

    @Test("Shift turns a wheel into a sideways pan; empty events do nothing")
    func shiftAndEmpty() {
        #expect(intent(dy: 1, precise: false, .shift) == .pan(dx: ZoomInput.lineStep, dy: 0))
        #expect(intent(dy: 0, precise: false) == .none)
        #expect(intent(dy: 0, precise: true) == .none)
        #expect(intent(dy: .nan, precise: false) == .none)
    }

    @Test("Pinch factors are bounded")
    func pinch() {
        #expect(ZoomInput.pinchFactor(0.05) == 1.05)
        #expect(ZoomInput.pinchFactor(-5) == 0.5)
        #expect(ZoomInput.pinchFactor(9) == 2)
        #expect(ZoomInput.pinchFactor(.nan) == 1)
    }
}

@Suite("Navigator geometry")
struct NavigatorGeometryTests {

    @Test("The map keeps the photo's aspect ratio within its bounds")
    func mapSize() {
        #expect(NavigatorGeometry.mapSize(forAspectRatio: 1.5, maxWidth: 180, maxHeight: 140) == CGSize(width: 180, height: 120))
        #expect(NavigatorGeometry.mapSize(forAspectRatio: 2.0 / 3.0, maxWidth: 180, maxHeight: 140) == CGSize(width: 93, height: 140))
        // A panorama is never cropped: it gets thin instead.
        #expect(NavigatorGeometry.mapSize(forAspectRatio: 6, maxWidth: 180, maxHeight: 140) == CGSize(width: 180, height: 30))
    }

    @Test("The rectangle maps the visible region onto the map one-to-one")
    func viewportRect() {
        let geometry = NavigatorGeometry(mapRect: CGRect(x: 0, y: 0, width: 200, height: 100))
        let rect = geometry.viewportRect(for: CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25))
        #expect(rect == CGRect(x: 50, y: 50, width: 100, height: 25))
        #expect(geometry.viewportRect(for: CGRect(x: 0, y: 0, width: 1, height: 1)) == geometry.mapRect)
    }

    @Test("A tiny region still gets a visible rectangle inside the map")
    func minimumRect() {
        let geometry = NavigatorGeometry(mapRect: CGRect(x: 0, y: 0, width: 200, height: 100))
        let rect = geometry.viewportRect(for: CGRect(x: 0.999, y: 0, width: 0.001, height: 0.001))
        #expect(rect.width >= NavigatorGeometry.minimumViewportSide)
        #expect(rect.height >= NavigatorGeometry.minimumViewportSide)
        #expect(geometry.mapRect.contains(rect))
    }

    @Test("Grabbing the rectangle off-centre does not make it jump")
    func dragKeepsGrabOffset() {
        var viewport = Viewport(imageSize: CGSize(width: 6000, height: 4000), viewSize: CGSize(width: 1200, height: 800))
        viewport.setZoom(4)
        let geometry = NavigatorGeometry(mapRect: CGRect(x: 0, y: 0, width: 180, height: 120))
        let rect = geometry.viewportRect(for: viewport.visibleRegion)

        let grab = CGPoint(x: rect.maxX - 2, y: rect.minY + 2)
        let drag = NavigatorDrag.begin(at: grab, viewportRect: rect)
        let unchanged = drag.targetCentre(for: grab, in: geometry)
        #expect(abs(unchanged.x - viewport.centre.x) < 0.000_1 && abs(unchanged.y - viewport.centre.y) < 0.000_1,
                "pressing inside the rectangle must not move the photo")

        let moved = drag.targetCentre(for: CGPoint(x: grab.x + 18, y: grab.y + 12), in: geometry)
        #expect(abs(moved.x - (viewport.centre.x + 0.1)) < 0.000_1)
        #expect(abs(moved.y - (viewport.centre.y + 0.1)) < 0.000_1)
    }

    @Test("Clicking outside the rectangle jumps there")
    func clickOutsideJumps() {
        let geometry = NavigatorGeometry(mapRect: CGRect(x: 0, y: 0, width: 180, height: 120))
        let rect = CGRect(x: 0, y: 0, width: 30, height: 20)
        let point = CGPoint(x: 135, y: 90)
        let drag = NavigatorDrag.begin(at: point, viewportRect: rect)
        #expect(drag.grabOffset == .zero)
        #expect(drag.targetCentre(for: point, in: geometry) == CGPoint(x: 0.75, y: 0.75))
        #expect(geometry.normalisedPoint(for: CGPoint(x: -50, y: 500)) == CGPoint(x: 0, y: 1))
    }
}
