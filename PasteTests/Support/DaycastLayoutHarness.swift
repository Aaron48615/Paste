// Standalone entry point used only by scripts/test-daycast-layout.py.
// Do not add to the application or XCTest target. No windows are ordered onscreen.
import AppKit
import SwiftUI

@main
@MainActor
enum LayoutHarness {
    static var failures = 0
    static var probes: [String: CGRect] = [:]
    static func check(_ condition: Bool, _ message: String) {
        print("\(condition ? "PASS" : "FAIL") \(message)")
        if !condition { failures += 1 }
    }
    static func pump(_ panel: NSWindow, _ duration: Double = 0.2) {
        let until = Date().addingTimeInterval(duration)
        while Date() < until {
            panel.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        panel.contentView?.layoutSubtreeIfNeeded()
    }
    static func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }
    static func main() {
        guard Bundle.main.bundleIdentifier?.hasPrefix("com.aaron.RePaste.LayoutHarness") == true else {
            fatalError("Requires isolated harness application identity")
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        // Never start AppCore: no monitors, global shortcuts, menus, IPC, or visible windows.
        let core = AppCore.shared
        core.settings.renderMarkdown = false
        core.settings.paletteVisualStyle = .daycast
        let vm = core.palette
        let fixtures = ["LAYOUT_ALPHA first fixture", "LAYOUT_BETA second fixture", "LAYOUT_GAMMA third fixture"]
        core.clipboardStore.clearAll()
        for text in fixtures { _ = core.clipboardStore.addText(text, sourceBundleID: nil) }
        for initial in [NSSize(width: 420, height: 475), NSSize(width: 750, height: 475)] {
            core.clipboardStore.clearAll()
            for text in fixtures { _ = core.clipboardStore.addText(text, sourceBundleID: nil) }
            vm.prepare()
            let root = RootPaletteView(visualStyle: .daycast)
                .environmentObject(core).environmentObject(vm).environmentObject(core.clipboardStore)
            let panel = PalettePanel(rootView: root, visualStyle: .daycast)
            panel.setFrame(NSRect(origin: NSPoint(x: -10000, y: -10000), size: initial), display: false)
            pump(panel)
            guard let content = panel.contentView,
                  let table = allViews(content).compactMap({ $0 as? NSTableView }).first else {
                check(false, "table exists at \(initial)"); continue
            }
            let point = NSPoint(x: 60, y: table.rect(ofRow: 1).midY)
            let inWindow = table.convert(point, to: nil)
            let event = NSEvent.mouseEvent(with: .mouseMoved, location: inWindow,
                modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber,
                context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
            table.mouseMoved(with: event)
            pump(panel)
            check(vm.selectedID != nil, "hover selects item from cold \(initial.width)")
            for width in [initial.width, CGFloat(420), 750, 420] {
                panel.setFrame(NSRect(origin: NSPoint(x: -10000, y: -10000),
                    size: NSSize(width: width, height: 475)), display: false)
                pump(panel)
                for row in [1, 2, 3] {
                    let hitPoint = table.convert(NSPoint(x: 60, y: table.rect(ofRow: row).midY), to: nil)
                    let parentPoint = content.superview?.convert(hitPoint, from: nil) ?? hitPoint
                    let hit = content.hitTest(parentPoint)
                    check(hit === table || hit?.isDescendant(of: table) == true,
                          "row hit target cold=\(initial.width) width=\(width) row=\(row): \(String(describing: hit))")
                    table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    pump(panel)
                    let views = allViews(content)
                    let previews = views.compactMap { $0 as? PreviewTextScrollView }
                    let expected = vm.selectedItem?.text ?? "MISSING"
                    check(previews.contains { $0.textView.string == expected },
                          "preview updates cold=\(initial.width) width=\(width) row=\(row)")
                    for preview in previews {
                        let rect = preview.convert(preview.bounds, to: content)
                        check(rect.width <= width && rect.width > 100 && rect.height > 20,
                              "preview dimensions within window")
                    }
                }
            }
            // Exercise image-to-image, image-to-text and live split sizing without showing a window.
            func fixturePNG(_ size: NSSize, color: NSColor) -> Data {
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width),
                    pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4,
                    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                    bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                color.setFill(); NSRect(origin: .zero, size: size).fill()
                NSGraphicsContext.restoreGraphicsState()
                return rep.representation(using: .png, properties: [:])!
            }
            var added = false
            Task { @MainActor in
                await core.clipboardStore.addImage(fixturePNG(NSSize(width: 600, height: 100), color: .red), sourceBundleID: nil)
                await core.clipboardStore.addImage(fixturePNG(NSSize(width: 100, height: 600), color: .blue), sourceBundleID: nil)
                added = true
            }
            while !added { pump(panel, 0.05) }
            pump(panel)
            for item in vm.results.filter({ $0.kind == .image }) {
                vm.select(item.id)
                pump(panel, 0.4)
                for (width, height, ratio) in [(420.0, 420.0, 0.2), (679, 650, 0.8), (680, 475, 0.3), (750, 650, 0.7), (420, 475, 0.45)] {
                    UserDefaults.standard.set(ratio, forKey: "daycastSplit.verticalRatio")
                    UserDefaults.standard.set(ratio, forKey: "daycastSplit.horizontalRatio")
                    panel.setFrame(NSRect(x: -10000, y: -10000, width: width, height: height), display: false)
                    pump(panel)
                    if let divider = allViews(content).compactMap({ $0 as? DaycastSplitDividerView }).first {
                        let before = probes["viewport"]
                        // Invoke the real drag callbacks, without moving the system pointer.
                        let delta: CGFloat = ratio < 0.5 ? 24 : -24
                        divider.onChange?(divider.listLength + delta)
                        pump(panel)
                        if let before, let after = probes["viewport"] {
                            check(before.size != after.size, "divider updates preview size while dragging")
                        } else { check(false, "divider geometry available") }
                        divider.onEnd?()
                        pump(panel)
                    } else { check(false, "divider exists") }
                    if let viewport = probes["viewport"], let payload = probes["payload"] {
                        check(payload.width <= viewport.width + 1 && payload.height <= viewport.height + 1,
                              "image fits preview viewport cold=\(initial.width) width=\(width)")
                        if let url = core.clipboardStore.imageURL(for: item), let image = NSImage(contentsOf: url) {
                            check(abs(payload.width / max(1, payload.height) - image.size.width / image.size.height) < 0.05,
                                  "image preview matches selected image aspect ratio")
                        } else { check(false, "image fixture readable") }
                    } else { check(false, "preview geometry available") }
                    if width < 680,
                       let scroll = allViews(content).compactMap({ $0 as? NSScrollView }).first(where: {
                           String(describing: type(of: $0)).contains("HostingScrollView")
                       }), let viewport = probes["viewport"], let doc = scroll.documentView {
                        check(abs(scroll.contentView.bounds.height - viewport.height) < 1,
                              "compact scroll viewport excludes footer")
                        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, doc.frame.height - scroll.contentView.bounds.height)))
                        scroll.reflectScrolledClipView(scroll.contentView)
                        pump(panel)
                        if let info = probes["info"] {
                            check(info.maxY <= viewport.maxY + 1, "all metadata reachable above footer")
                        } else { check(false, "metadata geometry available") }
                    } else if width < 680 { check(false, "compact scroll view exists") }

                }
            }
            vm.query = "LAYOUT_ALPHA"
            pump(panel, 0.5)
            check(vm.results.count == 1, "search filters after repeated layout changes")
            if let item = vm.results.first {
                vm.select(item.id)
                vm.handle(.rename)
                pump(panel)
                let draft = vm.renameDraft
                for width in [CGFloat(750), 420] {
                    panel.setFrame(NSRect(x: -10000, y: -10000, width: width, height: 475), display: false)
                    pump(panel)
                    check(vm.renamingID == item.id && vm.renameDraft == draft && vm.query == "LAYOUT_ALPHA",
                          "rename and search survive layout transition")
                }
            }
            vm.prepare()
            pump(panel)
            check(vm.selectedID == nil && vm.query.isEmpty, "reopening resets selection and search")
            table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            pump(panel)
            check(vm.selectedID != nil, "selection works after reopening")
            vm.toggleAppMenu()
            pump(panel)
            let selectionBeforeMenuHover = vm.selectedID
            table.mouseMoved(with: event)
            pump(panel)
            check(vm.selectedID == selectionBeforeMenuHover, "menu blocks list hover")
            vm.closeMenu()
            panel.contentView = nil
            panel.close()
            pump(panel)
            probes.removeAll()
        }
        print("FAILURES \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
