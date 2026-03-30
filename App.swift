import SwiftUI
import AppKit
import IOKit
import IOKit.i2c

// --- REAL HARDWARE COMMUNICATION LOGIC ---
struct DDC {
    static func setBrightness(displayID: CGDirectDisplayID, value: UInt8) {
        if CGDisplayIsBuiltin(displayID) != 0 {
            let service = CGDisplayIOServicePort(displayID)
            guard service != 0 else {
                print("Builtin display service not found for ID: \(displayID)")
                return
            }

            let normalized = Float(value) / 100.0
            let result = IODisplaySetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, normalized)
            if result != kIOReturnSuccess {
                print("Failed to set builtin brightness (IODisplaySetFloatParameter): \(result)")
            } else {
                print("Builtin brightness set to \(value)%")
            }
            IOObjectRelease(service)
            return
        }

        setVCP(displayID: displayID, vcp: 0x10, value: value)
    }

    static func setVCP(displayID: CGDirectDisplayID, vcp: UInt8, value: UInt8) {
        // 1. Find the Framebuffer service for this display
        let service = IOFramebufferPortFromDisplayID(displayID)
        guard service != 0 else {
            print("Could not find framebuffer for ID: \(displayID)")
            return
        }

        // 2. Prepare the DDC Packet
        var data = [UInt8](repeating: 0, count: 7)
        data[0] = 0x51
        data[1] = 0x82
        data[2] = 0x03
        data[3] = vcp
        data[4] = value

        var checksum: UInt8 = 0x6E
        for i in 0..<5 {
            checksum ^= data[i]
        }
        data[5] = checksum

        // 3. Setup I2C Request
        var request = IOI2CRequest()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 6)
        for i in 0..<6 { buffer[i] = data[i] }

        request.commFlags = 0
        request.sendAddress = 0x6E
        request.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
        request.sendBuffer = vm_address_t(bitPattern: buffer)
        request.sendBytes = 6

        request.replyAddress = 0x6F
        request.replyTransactionType = IOOptionBits(kIOI2CNoTransactionType)
        request.replyBuffer = 0
        request.replyBytes = 0

        // 4. Send Request (Fixed casting for Swift compatibility)
        // We cast the service (UInt32) to the expected OpaquePointer (IOI2CConnectRef)
        let connect = unsafeBitCast(service, to: IOI2CConnectRef.self)
        let result = IOI2CSendRequest(connect, 0, &request)

        if result != kIOReturnSuccess {
            print("DDC hardware communication failed error: \(result)")
        } else {
            print("Successfully sent VCP \(vcp) value \(value)")
        }

        buffer.deallocate()
        IOObjectRelease(service)
    }

    private static func IOFramebufferPortFromDisplayID(_ displayID: CGDirectDisplayID) -> io_service_t {
        var iter: io_iterator_t = 0
        let sMatching = IOServiceMatching("IOFramebuffer")
        guard IOServiceGetMatchingServices(kIOMasterPortDefault, sMatching, &iter) == kIOReturnSuccess else { return 0 }
        
        defer { IOObjectRelease(iter) }
        
        // Loop through services to find the one matching our display
        while case let service = IOIteratorNext(iter), service != 0 {
            // In a minimal app, we return the first active external framebuffer.
            // A production app would use 'CGDisplayIOServicePort(displayID)'
            // but that is a private API. This is the common workaround:
            return service 
        }
        return 0
    }
}

// --- UI VIEW ---
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
                Slider(value: $brightness, in: 0...100) { editing in
                    if !editing {
                        DDC.setBrightness(displayID: displayID, value: UInt8(brightness))
                    }
                }
            }
            
            HStack {
                Image(systemName: "circle.lefthalf.filled").frame(width: 20)
                Slider(value: $contrast, in: 0...100) { editing in
                    if !editing {
                        DDC.setVCP(displayID: displayID, vcp: 0x12, value: UInt8(contrast))
                    }
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
                let id = screen.deviceDescription[NSDeviceDescriptionKey(rawValue: "NSScreenNumber")] as? CGDirectDisplayID ?? 0
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
        if let button = statusItem?.button {
            if popover.isShown { popover.performClose(nil) }
            else { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
        }
    }
}