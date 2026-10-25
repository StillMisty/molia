import AppKit
import Foundation

// 生成 macOS AppIcon：把 Android 全彩方图缩进 1024 画布（824 内容 + 100 边距，
// 贴近 Apple 的圆角方块网格），再按 AppIcon.appiconset 的尺寸导出。
//
// 在仓库根目录运行：`swift tool/gen_macos_icons.swift`
let source = "assets/icons/image_path_android.png"
let outDir = "macos/Runner/Assets.xcassets/AppIcon.appiconset"

guard let image = NSImage(contentsOfFile: source) else {
  fatalError("cannot load \(source)")
}

func makeCanvas(size: Int) -> NSBitmapImageRep {
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: size,
    pixelsHigh: size,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
  )!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  NSColor.clear.set()
  NSRect(x: 0, y: 0, width: size, height: size).fill()
  NSGraphicsContext.restoreGraphicsState()
  return rep
}

func write(_ rep: NSBitmapImageRep, to path: String) {
  guard let data = rep.representation(using: .png, properties: [:]) else {
    fatalError("cannot encode \(path)")
  }
  try! data.write(to: URL(fileURLWithPath: path))
}

let master = makeCanvas(size: 1024)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: master)
NSGraphicsContext.current?.imageInterpolation = .high
image.draw(
  in: NSRect(x: 100, y: 100, width: 824, height: 824),
  from: .zero,
  operation: .sourceOver,
  fraction: 1
)
NSGraphicsContext.restoreGraphicsState()

write(master, to: "\(outDir)/app_icon_1024.png")

for size in [16, 32, 64, 128, 256, 512] {
  let rep = makeCanvas(size: size)
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  NSGraphicsContext.current?.imageInterpolation = .high
  image.draw(
    in: NSRect(
      x: Double(size) * 100.0 / 1024.0,
      y: Double(size) * 100.0 / 1024.0,
      width: Double(size) * 824.0 / 1024.0,
      height: Double(size) * 824.0 / 1024.0
    ),
    from: .zero,
    operation: .sourceOver,
    fraction: 1
  )
  NSGraphicsContext.restoreGraphicsState()
  write(rep, to: "\(outDir)/app_icon_\(size).png")
}
print("ok")
