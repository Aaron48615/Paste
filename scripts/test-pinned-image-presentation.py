#!/usr/bin/env python3
"""Check the real pinned-image crop policy without building or launching RePaste."""
from pathlib import Path
import subprocess
import tempfile
import sys

repo = Path(__file__).resolve().parents[1]
source = (repo / 'Paste/Features/Clipboard/PinnedImageWindow.swift').read_text()
start = source.index('enum PinnedImagePresentation {')
end = source.index('/// The image is the entire window content:', start)
checks = r'''
func fixture(_ shape: String) -> NSImage {
    let context = CGContext(data: nil, width: 240, height: 200, bitsPerComponent: 8,
        bytesPerRow: 240 * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(gray: 0, alpha: 0.2))
    context.fill(CGRect(x: 10, y: 10, width: 220, height: 180))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    switch shape {
    case "screenshot": context.fill(CGRect(x: 20, y: 25, width: 200, height: 160))
    case "photo": context.fill(CGRect(x: 0, y: 0, width: 240, height: 200))
    case "artwork": context.fillEllipse(in: CGRect(x: 20, y: 25, width: 200, height: 160))
    default: break
    }
    return NSImage(cgImage: context.makeImage()!, size: CGSize(width: 240, height: 200))
}
var failures = 0
func check(_ condition: Bool, _ name: String) {
    print("\(condition ? "PASS" : "FAIL") \(name)")
    if !condition { failures += 1 }
}
let screenshot = fixture("screenshot")
let cropped = PinnedImagePresentation.image(screenshot)
check(cropped.size == CGSize(width: 200, height: 160), "remove screenshot margins and baked shadow")
let cropPixels = NSBitmapImageRep(data: cropped.tiffRepresentation!)!
check([CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 159), CGPoint(x: 0, y: 80), CGPoint(x: 199, y: 80)].allSatisfy {
    cropPixels.colorAt(x: Int($0.x), y: Int($0.y))!.alphaComponent == 1
}, "cropped pixels reach all four edges without shifting the body")
check(screenshot.size == CGSize(width: 240, height: 200), "preserve original image")
check(PinnedImagePresentation.image(cropped).size == cropped.size, "repeated presentation does not keep shrinking")
for name in ["photo", "artwork", "translucent"] {
    let input = fixture(name)
    check(PinnedImagePresentation.image(input).size == input.size, "preserve \(name)")
}
if CommandLine.arguments.count > 1 {
    let input = NSImage(contentsOfFile: CommandLine.arguments[1])!
    let output = PinnedImagePresentation.image(input)
    let pixels = output.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    check(pixels.width == 1920 && pixels.height == 1562, "reported Activity Monitor screenshot: 2144x1786 -> 1920x1562")
}
exit(failures == 0 ? 0 : 1)
'''
with tempfile.TemporaryDirectory(prefix='repaste-image-check-') as directory:
    script = Path(directory) / 'check.swift'
    script.write_text('import AppKit\n' + source[start:end] + checks)
    result = subprocess.run(['swift', str(script), *sys.argv[1:]])
    sys.exit(result.returncode)
