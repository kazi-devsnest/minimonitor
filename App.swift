import SwiftUI
import AppKit
import IOKit
import IOKit.i2c

// MARK: - DDC/CI over IOKit (works on Apple Silicon + Intel)

struct DDC {

    // Send a DDC Set VCP command to a display identified by CGDirectDisplayID
    static func setVCP(displayID: CGDirectDisplayID, vcp: UInt8, value: UInt16) {
        guard let service = IOServicePortFromCGDisplayID(displayID) else {
            print("DDC: Could not find IOService for display \(displayID)")
            return
        }
        defer { IOObjectRelease(service) }

        // Build DDC Set VCP Feature request (MCCS spec)
        // Packet: 0x51 (source), length, 0x03 (Set VCP), vcp code, value high, value low, checksum
        let length: UInt8 = 0x84          // 0x80 | 4 bytes of data
        let valueHigh = UInt8((value >> 8) & 0xFF)
        let valueLow  = UInt8(value & 0xFF)
        var packet: [UInt8] = [0x51, length, 0x03, vcp, valueHigh, valueLow, 0x00]
        // XOR checksum over all bytes including the I2C destination address byte (0x6E)
        packet[6] = packet.dropLast().reduce(0x6E, ^)

        var request = IOI2CRequest()
        request.commFlags          = 0
        request.sendAddress        = 0x6E          // DDC/CI address (0x37 << 1)
        request.sendTransactionType = kIOI2CSimpleTransactionType
        request.sendBuffer         = withUnsafeMutableBytes(of: &packet) {
            UInt(bitPattern: $0.baseAddress)
        }
        request.sendBytes          = UInt32(packet.count)
        request.replyTransactionType = kIOI2CNoTransactionType
        request.replyBytes         = 0

        let interface = getI2CInterface(service: service)
        defer { releaseI2CInterface(interface) }

        guard let iface = interface else { return }
        let kr = IOI2CSendRequest(iface, IOOptionBits(kIOI2CUseSubAddressCommFlag), &request)
        if kr != KERN_SUCCESS {
            print("DDC: IOI2CSendRequest failed for display \(displayID), vcp \(vcp): \(kr)")
        }
    }

    // MARK: - Private helpers

    private static func IOServicePortFromCGDisplayID(_ displayID: CGDirectDisplayID) -> io_service_t? {
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("IODisplayConnect")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            // Each IODisplayConnect has a parent framebuffer with a display ID
            var framebuffer: io_service_t = 0
            if IORegistryEntryGetParentEntry(service, kIOServicePlane, &framebuffer) == KERN_SUCCESS {
                defer { IOObjectRelease(framebuffer) }
                var info: Unmanaged<CFMutableDictionary>?
                if IODisplayCreateInfoDictionary(framebuffer, IOOptionBits(kIODisplayOnlyPreferredName), &info) == KERN_SUCCESS,
                   let dict = info?.takeRetainedValue() as? [String: AnyObject],
                   let vendorID   = dict["DisplayVendorID"]   as? UInt32,
                   let productID  = dict["DisplayProductID"]  as? UInt32,
                   let serialNumber = dict["DisplaySerialNumber"] as? UInt32 {
                    _ = vendorID; _ = productID; _ = serialNumber // used implicitly via matching below
                }

                // Match via CGDisplayVendorNumber / CGDisplayModelNumber
                let vendor  = CGDisplayVendorNumber(displayID)
                let model   = CGDisplayModelNumber(displayID)
                var fbVendor: UInt32 = 0
                var fbModel:  UInt32 = 0
                if let v = IORegistryEntrySearchCFProperty(framebuffer, kIOServicePlane, "DisplayVendorID" as CFString, nil, IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) as? UInt32 { fbVendor = v }
                if let m = IORegistryEntrySearchCFProperty(framebuffer, kIOServicePlane, "DisplayProductID" as CFString, nil, IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) as? UInt32 { fbModel = m }

                if fbVendor == vendor && fbModel == model {
                    return service   // caller releases via defer
                }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return nil
    }

    // Open the first I2C interface on the given IOService
    private static func getI2CInterface(service: io_service_t) -> IOI2CInterfaceConnection? {
        var busCount: IOItemCount = 0
        guard IOFBGetI2CInterfaceCount(service, &busCount) == KERN_SUCCESS, busCount > 0 else {
            return nil
        }
        var interface: IOI2CInterfaceConnection?
        _ = IOFBCopyI2CInterfaceForBus(service, 0, &interface)
        return interface
    }

    private static func releaseI2CInterface(_ interface: IOI2CInterfaceConnection?) {
        if let iface = interface {
            IOI2CInterfaceClose(iface, 0)
        }
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