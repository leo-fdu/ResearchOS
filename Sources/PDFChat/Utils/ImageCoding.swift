import Foundation
import AppKit

enum ImageCoding {
    /// 将 NSImage 转为 data: URL (PNG base64).
    static func dataURL(from image: NSImage) -> String? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }

    /// 从剪贴板取图片 (截图/Copy的图片).
    static func imageFromPasteboard() -> NSImage? {
        let pb = NSPasteboard.general
        if pb.canReadObject(forClasses: [NSImage.self], options: nil) {
            return pb.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage
        }
        return nil
    }
}