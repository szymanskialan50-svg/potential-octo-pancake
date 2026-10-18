import UIKit
import CoreImage

/// Downloads YouTube thumbnails, crops them to a square and builds blurred backgrounds.
final class ArtworkLoader {
    static let shared = ArtworkLoader()

    private let cache = NSCache<NSString, UIImage>()
    private static let ciContext = CIContext(options: nil)

    /// Square, center-cropped artwork for a video id (best quality that exists).
    func artwork(for id: String) async -> UIImage? {
        if let hit = cache.object(forKey: id as NSString) { return hit }
        for name in ["maxresdefault", "sddefault", "hqdefault", "mqdefault"] {
            guard let url = URL(string: "https://i.ytimg.com/vi/\(id)/\(name).jpg") else { continue }
            guard let (data, resp) = try? await URLSession.shared.data(from: url),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let image = UIImage(data: data),
                  let square = ArtworkLoader.squareCrop(image) else { continue }
            cache.setObject(square, forKey: id as NSString)
            return square
        }
        return nil
    }

    static func squareCrop(_ image: UIImage) -> UIImage? {
        guard let cg = image.cgImage else { return image }
        let w = CGFloat(cg.width)
        let h = CGFloat(cg.height)
        guard w > 0, h > 0 else { return nil }
        var content = CGRect(x: 0, y: 0, width: w, height: h)
        if abs(w / h - 4.0 / 3.0) < 0.03 {
            // 4:3 thumbnails are letterboxed 16:9 pictures
            let ch = (w * 9.0 / 16.0).rounded()
            content = CGRect(x: 0, y: ((h - ch) / 2).rounded(), width: w, height: ch)
        }
        let side = min(content.width, content.height)
        let rect = CGRect(x: (content.midX - side / 2).rounded(),
                          y: (content.midY - side / 2).rounded(),
                          width: side, height: side)
        guard let cropped = cg.cropping(to: rect) else { return image }
        return UIImage(cgImage: cropped)
    }

    /// Small, pre-blurred, saturated copy used by the animated background.
    static func blurred(_ image: UIImage, radius: Double, saturation: Double = 1.45) -> UIImage? {
        let small = downscale(image, maxSide: 200)
        guard let input = CIImage(image: small) else { return nil }
        let extent = input.extent
        guard let blur = CIFilter(name: "CIGaussianBlur") else { return nil }
        blur.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        blur.setValue(radius, forKey: kCIInputRadiusKey)
        guard var out = blur.outputImage?.cropped(to: extent) else { return nil }
        if let color = CIFilter(name: "CIColorControls") {
            color.setValue(out, forKey: kCIInputImageKey)
            color.setValue(saturation, forKey: kCIInputSaturationKey)
            if let o = color.outputImage { out = o }
        }
        guard let cg = ciContext.createCGImage(out, from: extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    static func downscale(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let w = image.size.width
        let h = image.size.height
        let scale = min(1, maxSide / max(w, h))
        let size = CGSize(width: max(1, (w * scale).rounded()), height: max(1, (h * scale).rounded()))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// Four average colors (2x2 grid) of the image.
    static func palette(from image: UIImage) -> [UIColor] {
        guard let cg = image.cgImage else { return [] }
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let raw = ctx.data else { return [] }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 2, height: 2))
        let p = raw.bindMemory(to: UInt8.self, capacity: 16)
        var colors: [UIColor] = []
        for i in 0..<4 {
            colors.append(UIColor(red: CGFloat(p[i * 4]) / 255,
                                  green: CGFloat(p[i * 4 + 1]) / 255,
                                  blue: CGFloat(p[i * 4 + 2]) / 255,
                                  alpha: 1))
        }
        return colors
    }
}
