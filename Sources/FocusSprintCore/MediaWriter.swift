import AppKit
import AVFoundation
import CoreText
import ImageIO

/// Turns captured frames into the stored evidence: captioned JPEGs or short MP4 clips.
public enum MediaWriter {
    /// Adds a black bar under the image with bold white text, so the file explains itself
    /// even when viewed outside the app.
    public static func caption(_ image: CGImage, text: String, canvas: CGSize? = nil) -> CGImage {
        let width = Int(canvas?.width ?? CGFloat(image.width)) & ~1
        let height = Int(canvas?.height ?? CGFloat(image.height)) & ~1
        let bar = max(40, height / 16) & ~1
        guard let ctx = CGContext(data: nil, width: width, height: height + bar, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return image }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height + bar))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: bar, width: width, height: height))

        var size = CGFloat(bar) * 0.52
        var line = makeLine(text, size: size)
        let available = CGFloat(width) - CGFloat(bar)
        let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        if lineWidth > available {
            size *= available / lineWidth
            line = makeLine(text, size: size)
        }
        ctx.textPosition = CGPoint(x: CGFloat(bar) / 2, y: (CGFloat(bar) - size * 0.72) / 2)
        CTLineDraw(line, ctx)
        return ctx.makeImage() ?? image
    }

    private static func makeLine(_ text: String, size: CGFloat) -> CTLine {
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil) ?? CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    }

    public static func jpeg(_ image: CGImage, quality: Double = 0.6) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// Encodes frames (all the same size) as H.264, played back at the rate they were captured.
    public static func mp4(frames: [CGImage], fps: Int) async throws -> Data {
        guard let first = frames.first else { throw CocoaError(.fileWriteUnknown) }
        let width = first.width & ~1, height = first.height & ~1
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("focussprint-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 1_200_000],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        for (index, frame) in frames.enumerated() {
            var waited = 0
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 10_000_000)
                waited += 1
                if waited > 500 { throw CocoaError(.fileWriteUnknown) }
            }
            guard let pool = adaptor.pixelBufferPool else { throw CocoaError(.fileWriteUnknown) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw CocoaError(.fileWriteUnknown) }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                   bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) {
                ctx.draw(frame, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps))) else {
                throw writer.error ?? CocoaError(.fileWriteUnknown)
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frames.count), timescale: CMTimeScale(fps)))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        return try Data(contentsOf: url)
    }
}
