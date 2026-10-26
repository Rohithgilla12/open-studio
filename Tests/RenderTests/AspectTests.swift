import Foundation
import Testing
@testable import Render
import Timeline

struct AspectCanvasSpec {
    static let screen = Size(width: 3456, height: 2234)
    static let wideArea = Size(width: 800, height: 400)
    static let tallArea = Size(width: 600, height: 1200)

    static let expected: [(CanvasAspect, hd: PixelSize, uhd: PixelSize)] = [
        (.fit, PixelSize(width: 1920, height: 1080), PixelSize(width: 3840, height: 2160)),
        (.widescreen, PixelSize(width: 1920, height: 1080), PixelSize(width: 3840, height: 2160)),
        (.vertical, PixelSize(width: 1080, height: 1920), PixelSize(width: 2160, height: 3840)),
        (.square, PixelSize(width: 1080, height: 1080), PixelSize(width: 2160, height: 2160)),
        (.standard, PixelSize(width: 1440, height: 1080), PixelSize(width: 2880, height: 2160)),
        (.portrait, PixelSize(width: 1080, height: 1350), PixelSize(width: 2160, height: 2700)),
    ]

    @Test func everyPresetCoversEveryAspect() {
        #expect(Set(Self.expected.map(\.0)) == Set(CanvasAspect.allCases))
    }

    @Test func anEntireScreenTakeGetsTheAspectsBox() {
        for (aspect, hd, uhd) in Self.expected {
            let hdFormat = OutputFormat(size: .hd1080, aspect: aspect, frameRate: .fps60, codec: .hevc)
            let uhdFormat = OutputFormat(size: .uhd2160, aspect: aspect, frameRate: .fps60, codec: .hevc)
            #expect(hdFormat.canvasSize(for: Self.screen, padding: 0.08) == hd, "\(aspect) 1080p")
            #expect(uhdFormat.canvasSize(for: Self.screen, padding: 0.08) == uhd, "\(aspect) 4K")
        }
    }

    @Test func anAreaTakeGetsTheAspectsBoxUnlessItFits() {
        for (aspect, hd, uhd) in Self.expected where aspect != .fit {
            for area in [Self.wideArea, Self.tallArea] {
                let hdFormat = OutputFormat(size: .hd1080, aspect: aspect, frameRate: .fps60, codec: .hevc)
                let uhdFormat = OutputFormat(size: .uhd2160, aspect: aspect, frameRate: .fps60, codec: .hevc)
                #expect(hdFormat.canvasSize(forArea: area, padding: 0.08) == hd, "\(aspect) 1080p \(area)")
                #expect(uhdFormat.canvasSize(forArea: area, padding: 0.08) == uhd, "\(aspect) 4K \(area)")
            }
        }
        let fit = OutputFormat(size: .hd1080, aspect: .fit, frameRate: .fps60, codec: .hevc)
        #expect(fit.canvasSize(forArea: Self.wideArea, padding: 0.08) == PixelSize(width: 1920, height: 960))
        #expect(fit.canvasSize(forArea: Self.tallArea, padding: 0.08) == PixelSize(width: 540, height: 1080))
    }

    @Test func nativeIgnoresTheAspect() {
        for aspect in CanvasAspect.allCases {
            let format = OutputFormat(size: .native, aspect: aspect, frameRate: .fps60, codec: .hevc)
            #expect(format.canvasSize(for: Size(width: 800, height: 400), padding: 0.1) == PixelSize(width: 1000, height: 500))
            #expect(format.canvasSize(forArea: Self.tallArea, padding: 0.1) == PixelSize(width: 750, height: 1500))
        }
    }

    @Test func aProjectSizesItsCanvasWithTheAspect() throws {
        let take = try Fixture.metadataOnlyTake()
        defer { try? FileManager.default.removeItem(at: take) }
        let vertical = OutputFormat(size: .hd1080, aspect: .vertical, frameRate: .fps60, codec: .hevc)
        #expect(try Project.open(take).canvasSize(for: vertical) == PixelSize(width: 1080, height: 1920))
        try Fixture.setArea(Rect(origin: Point(x: 400, y: 440), size: Self.wideArea), in: take)
        #expect(try Project.open(take).canvasSize(for: vertical) == PixelSize(width: 1080, height: 1920))
    }

    @Test func aVerticalCanvasFitsTheScreenAcrossItsWidth() {
        let style = Style(background: .solid(RGBColor(red: 0, green: 0, blue: 1)), padding: 0.08, cornerRadius: 0, shadow: .none)
        let layout = CanvasLayout(style: style, canvas: PixelSize(width: 1080, height: 1920), source: Size(width: 1920, height: 1080))
        // Inset 0.08 * 1080 = 86.4 each side; 907.2 px wide at the source's 16:9.
        #expect(layout.content.size == Size(width: 907, height: 510))
        #expect(layout.content.origin == Point(x: 86, y: 705))
    }

    @Test func aMissingAspectKeyKeepsTodaysCanvas() throws {
        let saved = Data(#"{"size": "hd1080", "frameRate": 60, "codec": "hevc"}"#.utf8)
        #expect(try JSONDecoder().decode(OutputFormat.self, from: saved) == .hd1080)
    }

    @Test func theAspectRoundTripsAsItsRatio() throws {
        for aspect in CanvasAspect.allCases {
            let format = OutputFormat(size: .uhd2160, aspect: aspect, frameRate: .fps30, codec: .h264)
            let data = try JSONEncoder().encode(format)
            #expect(try JSONDecoder().decode(OutputFormat.self, from: data) == format)
        }
        let vertical = try JSONEncoder().encode(OutputFormat(size: .hd1080, aspect: .vertical, frameRate: .fps60, codec: .hevc))
        #expect(String(decoding: vertical, as: UTF8.self).contains(#""aspect":"9:16""#))
    }

    @Test func anUnknownAspectIsRefused() {
        let saved = Data(#"{"size": "hd1080", "aspect": "3:2", "frameRate": 60, "codec": "hevc"}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(OutputFormat.self, from: saved) }
    }
}

struct AspectPixelSpec {
    func isRed(_ p: (red: Int, green: Int, blue: Int)) -> Bool { p.red > 200 && p.green < 60 && p.blue < 60 }
    func isGreen(_ p: (red: Int, green: Int, blue: Int)) -> Bool { p.green > 200 && p.red < 60 && p.blue < 60 }
    func isBlue(_ p: (red: Int, green: Int, blue: Int)) -> Bool { p.blue > 200 && p.red < 60 && p.green < 60 }

    /// Catches a canvas rendered at the wrong shape or the content placed for a landscape canvas.
    @Test func aVerticalStillHasTheScreenInABandAcrossTheMiddle() async throws {
        let take = try await Fixture.take(top: (255, 0, 0), bottom: (0, 255, 0))
        defer { try? FileManager.default.removeItem(at: take) }
        var project = try Project.open(take)
        project.edits.zooms = .empty
        project.edits.style = Style(
            background: .solid(RGBColor(red: 0, green: 0, blue: 1)), padding: 0.08, cornerRadius: 0, shadow: .none)
        project.edits.format = OutputFormat(size: .hd1080, aspect: .vertical, frameRate: .fps60, codec: .hevc)
        let pixels = Pixels(try await Still.cgImage(project, at: .seconds(1)))
        // Content 907 x 510 at (86, 705), from aVerticalCanvasFitsTheScreenAcrossItsWidth.
        #expect(pixels.width == 1080 && pixels.height == 1920)
        #expect(isBlue(pixels[540, 600]), "above the band \(pixels[540, 600])")
        #expect(isRed(pixels[540, 705 + 100]), "upper content \(pixels[540, 805])")
        #expect(isGreen(pixels[540, 705 + 400]), "lower content \(pixels[540, 1105])")
        #expect(isBlue(pixels[540, 1300]), "below the band \(pixels[540, 1300])")
        #expect(isBlue(pixels[40, 960]), "left padding \(pixels[40, 960])")
    }
}
