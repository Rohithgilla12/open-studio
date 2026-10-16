import CoreGraphics
@testable import Studio
import Testing

struct DisplaySpaceSpec {
    let main = CGRect(x: 0, y: 0, width: 1512, height: 982)
    /// To the right of the main display and 200 points lower.
    let right = CGRect(x: 1512, y: -200, width: 1920, height: 1080)
    /// To the left of the main display and above it.
    let leftAbove = CGRect(x: -1920, y: 982, width: 1920, height: 1080)

    @Test func theMainDisplayFlipsY() {
        #expect(DisplaySpace.displayPoint(fromScreen: CGPoint(x: 100, y: 882), screenFrame: main) == CGPoint(x: 100, y: 100))
        #expect(
            DisplaySpace.screenRect(fromDisplay: CGRect(x: 100, y: 100, width: 200, height: 50), screenFrame: main)
                == CGRect(x: 100, y: 832, width: 200, height: 50))
    }

    @Test func aSecondaryDisplayIsMeasuredFromItsOwnTopLeft() {
        #expect(DisplaySpace.displayPoint(fromScreen: CGPoint(x: 1612, y: 830), screenFrame: right) == CGPoint(x: 100, y: 50))
        #expect(
            DisplaySpace.screenRect(fromDisplay: CGRect(x: 100, y: 50, width: 400, height: 300), screenFrame: right)
                == CGRect(x: 1612, y: 530, width: 400, height: 300))
        #expect(DisplaySpace.displayPoint(fromScreen: CGPoint(x: -1920, y: 2062), screenFrame: leftAbove) == .zero)
        #expect(
            DisplaySpace.screenRect(fromDisplay: CGRect(x: 0, y: 1000, width: 1920, height: 80), screenFrame: leftAbove)
                == CGRect(x: -1920, y: 982, width: 1920, height: 80))
    }

    @Test(arguments: [CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: 1512, y: -200, width: 1920, height: 1080)])
    func theTwoDirectionsAreInverse(screenFrame: CGRect) {
        let area = CGRect(x: 37, y: 211, width: 640, height: 360)
        let onScreen = DisplaySpace.screenRect(fromDisplay: area, screenFrame: screenFrame)
        let topLeft = DisplaySpace.displayPoint(fromScreen: CGPoint(x: onScreen.minX, y: onScreen.maxY), screenFrame: screenFrame)
        let bottomRight = DisplaySpace.displayPoint(fromScreen: CGPoint(x: onScreen.maxX, y: onScreen.minY), screenFrame: screenFrame)
        #expect(CGRect(corner: topLeft, opposite: bottomRight) == area)
    }
}

struct AreaEditorSpec {
    let display = CGSize(width: 1512, height: 982)
    let start = CGRect(x: 100, y: 100, width: 200, height: 100)

    @Test func aPresetIsClippedToTheDisplay() {
        #expect(AreaEditor(displaySize: display, preset: CGRect(x: 1400, y: 900, width: 300, height: 300)).selection
            == CGRect(x: 1400, y: 900, width: 112, height: 82))
        #expect(AreaEditor(displaySize: display, preset: CGRect(x: 2000, y: 0, width: 300, height: 300)).selection == nil)
    }

    @Test func drawingStopsAtTheDisplayEdge() {
        var editor = AreaEditor(displaySize: display, preset: nil)
        editor.begin(at: CGPoint(x: 100, y: 100))
        editor.drag(to: CGPoint(x: -50, y: 5000))
        editor.end()
        #expect(editor.selection == CGRect(x: 0, y: 100, width: 100, height: 882))
    }

    @Test func movingKeepsTheWholeSelectionOnTheDisplay() {
        var editor = AreaEditor(displaySize: display, preset: start)
        editor.begin(at: CGPoint(x: 150, y: 150))
        editor.drag(to: CGPoint(x: 160, y: 140))
        #expect(editor.selection == CGRect(x: 110, y: 90, width: 200, height: 100))
        editor.drag(to: CGPoint(x: 10_000, y: 10_000))
        editor.end()
        #expect(editor.selection == CGRect(x: 1312, y: 882, width: 200, height: 100))
    }

    @Test func aHandleMovesOnlyItsEdgesAndCanCrossTheOppositeOne() {
        var editor = AreaEditor(displaySize: display, preset: start)
        #expect(editor.handle(at: CGPoint(x: 102, y: 149)) == .left)
        editor.begin(at: CGPoint(x: 100, y: 150))
        editor.drag(to: CGPoint(x: 400, y: 900))
        editor.end()
        #expect(editor.selection == CGRect(x: 300, y: 100, width: 100, height: 100))

        editor.begin(at: CGPoint(x: 400, y: 100))
        editor.drag(to: CGPoint(x: 500, y: 0))
        editor.end()
        #expect(editor.selection == CGRect(x: 300, y: 0, width: 200, height: 200))
    }

    @Test func aClickOutsideTheSelectionKeepsIt() {
        var editor = AreaEditor(displaySize: display, preset: start)
        editor.begin(at: CGPoint(x: 800, y: 600))
        editor.drag(to: CGPoint(x: 802, y: 601))
        editor.end()
        #expect(editor.selection == start)

        editor.begin(at: CGPoint(x: 800, y: 600))
        editor.drag(to: CGPoint(x: 900, y: 700))
        editor.end()
        #expect(editor.selection == CGRect(x: 800, y: 600, width: 100, height: 100))
    }

    @Test func theSmallestAreaIsMeasuredInScreenPixels() {
        let retina = AreaEditor(displaySize: display, preset: CGRect(x: 0, y: 0, width: 32, height: 40))
        #expect(retina.pixelSize(scale: 2) == CGSize(width: 64, height: 80))
        #expect(retina.isLargeEnough(scale: 2))
        #expect(!retina.isLargeEnough(scale: 1))

        let short = AreaEditor(displaySize: display, preset: CGRect(x: 0, y: 0, width: 400, height: 31.75))
        #expect(short.pixelSize(scale: 2) == CGSize(width: 800, height: 63))
        #expect(!short.isLargeEnough(scale: 2))
        #expect(!AreaEditor(displaySize: display, preset: nil).isLargeEnough(scale: 2))
    }
}
