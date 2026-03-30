import SwiftUI
import AppKit

// --- APPLE SILICON (M1/M2/M3/M4) HARDWARE LOGIC ---

// Linking to the private IOAVService functions
@_silgen_name("IOAVServiceCreateWithService")
func IOAVServiceCreateWithService(_ allocator: CFAllocator?, _ service: io_service_t) -> Unmanaged<AnyObject>?

@_silgen_name("IOAVServiceWriteI2C")
func IOAVServiceWriteI2C(_ service: AnyObject, _ chipAddress: UInt32, _ dataAddress: UInt32, _ pointer: UnsafePointer<UInt8>, _ length: UInt32) -> Int32

struct DDC {
    static func setVCP(vcp: UInt8, value: UInt8) {
        var iter: io_iterator_t = 0
        // On M-series, DDC is handled by 'dc-pa-v-service'
        let matching = IOServiceMatching("dc-pa-v-service")
        
        guard IOServiceGetMatchingServices(kIOMasterPortDefault, matching, &iter) == kIOReturnSuccess else {
            print("Could not find Apple Silicon Display Services")
            return
        }
        
        defer { IOObjectRelease(iter) }
        
        while case let service = IOIteratorNext(iter), service != 0 {
            // Create the AVService for this specific monitor port
            if let avService = IOAVServiceCreateWithService(kCFAllocatorDefault, service)?.takeRetainedValue() {
                
                // Construct DDC Packet: [Destination, Length, Command, VCP, Value, Checksum]
                var data = [UInt8](repeating: 0, count: 6)
                data[0] = 0x51
                data[1] = 0x82
                data[2] = 0x03
                data[3] = vcp
                data[4] = value
                
                var checksum: UInt8 = 0x6E
                for i in 0..<5 { checksum ^= data[i] }
                data[5] = checksum
                
                // On Apple Silicon, we write to I2C address 0x37 (0x6E >> 1)
                let result = IOAVServiceWriteI2C(avService, 0x37, 0x51, data, UInt32(data.count))
                
                if result == 0 {
                    print("Successfully changed hardware value on M4 via IOAV")
                }
            }
            IOObjectRelease(service)
        }
    }
}

// --- UI VIEW ---
struct MonitorView: View {
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
                        DDC.setVCP(vcp: 0x10, value: UInt8(brightness))
                    }
                }
            }
            
            HStack {
                Image(systemName: "circle.lefthalf.filled").frame(width: 20)
                Slider(value: $contrast, in: 0...100) { editing in
                    if !editing {
                        DDC.setVCP(vcp: 0x12, value: UInt8(contrast))
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
            Text("MiniDisplay (M4 Mode)").font(.caption).opacity(0.6)
            
            // On Apple Silicon, iterating NSScreen is fine for the UI, 
            // but the DDC command above will loop through all external ports.
            ForEach(NSScreen.screens, id: \.self) { screen in
                if screen != NSScreen.screens.first { // Usually skips the built-in MacBook screen
                    MonitorView(name: screen.localizedName)
                }
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