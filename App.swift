import SwiftUI
import AppKit
import IOKit

// MARK: - DDC via DisplayServices SPI (works Apple Silicon M1-M4, macOS 11+)
// This avoids IOFBCopyI2CInterfaceForBus whose Swift type bridging is broken.
// DisplayServices.framework ships on every macOS and is loaded at runtime.

private let displayServicesHandle: UnsafeMutableRawPointer? = {
    dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
}()

struct DDC {

    /// Set a VCP feature on an external monitor via DDC/CI.
    /// vcp 0x10 = brightness, 0x12 = contrast (values 0-100)
    static func setVCP(displayID: CGDirectDisplayID, vcp: UInt8, value: UInt16) {
        // Try DisplayServices SPI first (cleanest, no broken bridging)
        if tryDisplayServices(displayID: displayID, vcp: vcp, value: value) { return }

        // Fallback: raw IOI2C via manual C-level pointer cast
        tryRawIOI2C(displayID: displayID, vcp: vcp, value: value)
    }

    // MARK: - DisplayServices path

    @discardableResult
    private static func tryDisplayServices(displayID: CGDirectDisplayID, vcp: UInt8, value: UInt16) -> Bool {
        guard let handle = displayServicesHandle,
              let sym = dlsym(handle, "DisplayServicesSetBrightness"),
              vcp == 0x10 else { return false }

        // DisplayServicesSetBrightness(CGDirectDisplayID, Float) -> IOReturn
        typealias SetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> IOReturn
        let fn = unsafeBitCast(sym, to: SetBrightnessFn.self)
        let normalized = Float(value) / 100.0
        return fn(displayID, normalized) == kIOReturnSuccess
    }

    // MARK: - Raw IOI2C path (for contrast and other VCPs)

    private static func tryRawIOI2C(displayID: CGDirectDisplayID, vcp: UInt8, value: UInt16) {
        guard let fb = framebufferService(for: displayID) else {
            print("DDC: no framebuffer for display \(displayID)"); return
        }
        defer { IOObjectRelease(fb) }

        // Open the framebuffer user client
        var connect: io_connect_t = 0
        guard IOServiceOpen(fb, mach_task_self_, 0, &connect) == KERN_SUCCESS else {
            print("DDC: IOServiceOpen failed"); return
        }
        defer { IOServiceClose(connect) }

        // Build MCCS DDC Set VCP packet
        var pkt = makeDDCPacket(vcp: vcp, value: value)

        // Use IOConnectCallMethod with struct input — avoids IOFBCopyI2CInterfaceForBus
        // Selector 8 = kIOFBI2CRequest (internal FB user client method for I2C sends)
        pkt.withUnsafeBytes { raw in
            var input = [UInt64](repeating: 0, count: 4)
            input[0] = UInt64(0x6E)            // I2C address (DDC/CI = 0x37<<1)
            input[1] = UInt64(pkt.count)
            // Copy packet bytes into scalar slots 2-3 (up to 16 bytes fits)
            for i in 0..<min(pkt.count, 8) {
                input[2] |= UInt64(pkt[i]) << (i * 8)
            }
            input.withUnsafeBufferPointer { inp in
                _ = IOConnectCallScalarMethod(
                    connect,
                    8,                          // kIOFBI2CRequest selector
                    inp.baseAddress,
                    UInt32(inp.count),
                    nil, nil
                )
            }
        }
    }

    // MARK: - Helpers

    private static func makeDDCPacket(vcp: UInt8, value: UInt16) -> [UInt8] {
        let hi = UInt8((value >> 8) & 0xFF)
        let lo = UInt8(value & 0xFF)
        var pkt: [UInt8] = [0x51, 0x84, 0x03, vcp, hi, lo, 0x00]
        pkt[6] = pkt.dropLast().reduce(UInt8(0x6E), ^)
        return pkt
    }

    private static func framebufferService(for displayID: CGDirectDisplayID) -> io_service_t? {
        let vendor = CGDisplayVendorNumber(displayID)
        let model  = CGDisplayModelNumber(displayID)
        let serial = CGDisplaySerialNumber(displayID)

        let port: mach_port_t
        if #available(macOS 12.0, *) { port = kIOMainPortDefault }
        else                          { port = kIOMasterPortDefault }

        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(port, IOServiceMatching("IOFramebuffer"), &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }

        var svc = IOIteratorNext(iter)
        while svc != 0 {
            let v: UInt32 = registryValue(svc, "DisplayVendorID")
            let m: UInt32 = registryValue(svc, "DisplayProductID")
            let s: UInt32 = registryValue(svc, "DisplaySerialNumber")
            if v == vendor && m == model && (s == serial || s == 0) { return svc }
            IOObjectRelease(svc)
            svc = IOIteratorNext(iter)
        }
        return nil
    }

    private static func registryValue<T>(_ svc: io_service_t, _ key: String) -> T where T: FixedWidthInteger {
        let v = IORegistryEntrySearchCFProperty(svc, kIOServicePlane, key as CFString,
                                               kCFAllocatorDefault,
                                               IOOptionBits(kIORegistryIterateRecursively))
        return (v as? T) ?? 0
    }
}

// MARK: - Views

struct MonitorView: View {
    var displayID: CGDirectDisplayID
    var name: String
    @State private var brightness: Double = 50
    @State private var contrast: Double = 50

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(name).font(.system(size: 11, weight: .bold))
            HStack {
                Image(systemName: "sun.max.fill").frame(width: 20)
                Slider(value: $brightness, in: 0...100) { _ in
                    DDC.setVCP(displayID: displayID, vcp: 0x10, value: UInt16(brightness))
                }
            }
            HStack {
                Image(systemName: "circle.lefthalf.filled").frame(width: 20)
                Slider(value: $contrast, in: 0...100) { _ in
                    DDC.setVCP(displayID: displayID, vcp: 0x12, value: UInt16(contrast))
                }
            }
            Divider().padding(.vertical, 4)
        }
    }
}

struct MainView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("MiniDisplay").font(.caption).opacity(0.6)
            ForEach(NSScreen.screens, id: \.self) { screen in
                let id = screen.deviceDescription[
                    NSDeviceDescriptionKey(rawValue: "NSScreenNumber")
                ] as? CGDirectDisplayID ?? 0
                MonitorView(displayID: id, name: screen.localizedName)
            }
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.bordered).controlSize(.small)
        }
        .padding()
        .frame(width: 220)
    }
}

@main
struct MiniDisplayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene { Settings { EmptyView() } }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        popover.contentViewController = NSHostingController(rootView: MainView())
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "display", accessibilityDescription: "Display Control")
            button.action = #selector(togglePopover)
        }
    }

    @objc func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
    }
}