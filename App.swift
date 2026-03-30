import SwiftUI
import AppKit
import IOKit
import IOKit.i2c

// MARK: - DDC/CI over IOKit (Apple Silicon + Intel, macOS 11+)

struct DDC {

    static func setVCP(displayID: CGDirectDisplayID, vcp: UInt8, value: UInt16) {
        guard let service = serviceForDisplay(displayID) else {
            print("DDC: no IOService for display \(displayID)")
            return
        }
        defer { IOObjectRelease(service) }
        sendDDC(service: service, vcp: vcp, value: value)
    }

    // MARK: - DDC packet sender

    private static func sendDDC(service: io_service_t, vcp: UInt8, value: UInt16) {
        // MCCS Set VCP Feature (0x03), 4 data bytes, XOR checksum
        let valueHigh = UInt8((value >> 8) & 0xFF)
        let valueLow  = UInt8(value & 0xFF)
        // Packet bytes sent after the I2C address (0x6E = 0x37 << 1)
        var payload: [UInt8] = [0x51, 0x84, 0x03, vcp, valueHigh, valueLow, 0x00]
        payload[6] = payload.dropLast().reduce(UInt8(0x6E), ^)

        withUnsafeMutableBytes(of: &payload) { ptr in
            var request = IOI2CRequest()
            bzero(&request, MemoryLayout<IOI2CRequest>.size)
            request.commFlags             = 0
            request.sendAddress           = 0x6E
            request.sendTransactionType   = IOOptionBits(kIOI2CSimpleTransactionType)
            request.sendBuffer            = UInt(bitPattern: ptr.baseAddress)
            request.sendBytes             = UInt32(payload.count)
            request.replyTransactionType  = IOOptionBits(kIOI2CNoTransactionType)
            request.replyBytes            = 0
            request.minReplyDelay         = 0

            var busCount: IOItemCount = 0
            guard IOFBGetI2CInterfaceCount(service, &busCount) == KERN_SUCCESS,
                  busCount > 0 else { return }

            for bus in 0..<busCount {
                var connect: io_connect_t = 0
                guard IOFBCopyI2CInterfaceForBus(service, bus, &connect) == KERN_SUCCESS else { continue }
                _ = IOI2CSendRequest(connect, 0, &request)
                IOServiceClose(connect)
            }
        }
    }

    // MARK: - Resolve CGDirectDisplayID -> io_service_t (IOFramebuffer)

    private static func serviceForDisplay(_ displayID: CGDirectDisplayID) -> io_service_t? {
        let vendor  = CGDisplayVendorNumber(displayID)
        let model   = CGDisplayModelNumber(displayID)
        let serial  = CGDisplaySerialNumber(displayID)

        let matching = IOServiceMatching("IOFramebuffer")
        var iterator: io_iterator_t = 0

        let port: mach_port_t
        if #available(macOS 12.0, *) {
            port = kIOMainPortDefault
        } else {
            port = kIOMasterPortDefault
        }

        guard IOServiceGetMatchingServices(port, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            let v = registryUInt32(service, key: "DisplayVendorID")
            let m = registryUInt32(service, key: "DisplayProductID")
            let s = registryUInt32(service, key: "DisplaySerialNumber")

            if v == vendor && m == model && (s == serial || s == 0) {
                return service  // caller must IOObjectRelease
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return nil
    }

    private static func registryUInt32(_ service: io_service_t, key: String) -> UInt32 {
        let value = IORegistryEntrySearchCFProperty(
            service,
            kIOServicePlane,
            key as CFString,
            kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively)
        )
        return (value as? UInt32) ?? 0
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

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding()
        .frame(width: 220)
    }
}

// MARK: - App entry point

@main
struct MiniDisplayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        Settings { EmptyView() }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        popover.contentViewController = NSHostingController(rootView: MainView())

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "display",
                                   accessibilityDescription: "Display Control")
            button.action = #selector(togglePopover)
        }
    }

    @objc func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}