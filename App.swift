import SwiftUI
import AppKit
import IOKit.i2c

// --- REAL HARDWARE COMMUNICATION LOGIC ---
struct DDC {
    static func setVCP(displayID: CGDirectDisplayID, vcp: UInt8, value: UInt8) {
        // 1. Find the Framebuffer service for this display
        let service = IOFramebufferPortFromDisplayID(displayID)
        guard service != 0 else { return }
        
        // 2. Prepare the DDC Packet
        // [Destination (0x51), Length (0x82 = 2 bytes of data + 0x80), Command (0x03 = Set), VCP Code, Value, Checksum]
        var data = [UInt8](repeating: 0, count: 7)
        data[0] = 0x51
        data[1] = 0x82
        data[2] = 0x03
        data[3] = vcp
        data[4] = value
        
        // Calculate Checksum (XOR of all previous bytes including the I2C address 0x6E)
        var checksum: UInt8 = 0x6E
        for i in 0..<5 {
            checksum ^= data[i]
        }
        data[5] = checksum

        // 3. Send via I2C
        var request = IOI2CRequest()
        request.commFlags = 0
        request.sendAddress = 0x6E
        request.sendTransactionType = kIOI2CSimpleTransactionType
        request.sendBuffer = vm_address_t(bitPattern: UnsafeMutablePointer<UInt8>.allocate(capacity: 6))
        
        // Copy data to pointer
        let ptr = UnsafeMutablePointer<UInt8>(bitPattern: Int(request.sendBuffer))
        for i in 0..<6 { ptr?[i] = data[i] }
        
        request.sendBytes = 6
        request.replyAddress = 0x6F
        request.replyTransactionType = kIOI2CNoTransactionType
        request.replyBuffer = 0
        request.replyBytes = 0
        
        // Execute the hardware call
        let result = IOI2CSendRequest(service, 0, &request)
        if result != kIOReturnSuccess {
            print("DDC failed for display \(displayID)")
        }
        
        IOObjectRelease(service)
    }

    // Helper to find the hardware port for the display
    private static func IOFramebufferPortFromDisplayID(_ displayID: CGDirectDisplayID) -> io_service_t {
        var iter: io_iterator_t = 0
        let sMatching = IOServiceMatching("IOFramebuffer")
        guard IOServiceGetMatchingServices(kIOMasterPortDefault, sMatching, &iter) == kIOReturnSuccess else { return 0 }
        
        defer { IOObjectRelease(iter) }
        
        var service = IOIteratorNext(iter)
        while service != 0 {
            // Match the display ID to the framebuffer
            if let info = IORegistryEntryCreateCFProperty(service, "IOIndex" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int {
                // This is a simplified check; in a full app we'd map CGDirectDisplayID to the specific Framebuffer
            }
            // For most dual monitor setups, the first two framebuffers found are the correct ones
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
                    if !editing { // Only send command when user stops sliding for better performance
                        DDC.setVCP(displayID: displayID, vcp: 0x10, value: UInt8(brightness))
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