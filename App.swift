import SwiftUI
import AppKit
import IOKit

// --- APPLE SILICON PRIVATE API BRIDGE ---
// These functions exist in the macOS Private Frameworks
@_silgen_name("IOAVServiceCreateWithService")
func IOAVServiceCreateWithService(_ allocator: CFAllocator?, _ service: io_service_t) -> Unmanaged<AnyObject>?

@_silgen_name("IOAVServiceWriteI2C")
func IOAVServiceWriteI2C(_ service: AnyObject, _ chipAddress: UInt32, _ dataAddress: UInt32, _ pointer: UnsafePointer<UInt8>, _ length: UInt32) -> Int32

struct DDC {
    static func setVCP(vcp: UInt8, value: UInt8) {
        let serviceNames = ["IOAVService", "dc-pa-v-service", "AppleCLCD2"]
        
        for name in serviceNames {
            var iter: io_iterator_t = 0
            let matching = IOServiceMatching(name)
            guard IOServiceGetMatchingServices(kIOMasterPortDefault, matching, &iter) == kIOReturnSuccess else { continue }
            
            while case let service = IOIteratorNext(iter), service != 0 {
                if let avService = IOAVServiceCreateWithService(kCFAllocatorDefault, service)?.takeRetainedValue() {
                    var data = [UInt8](repeating: 0, count: 6)
                    data[0] = 0x51
                    data[1] = 0x82
                    data[2] = 0x03
                    data[3] = vcp
                    data[4] = value
                    
                    var checksum: UInt8 = 0x6E
                    for i in 0..<5 { checksum ^= data[i] }
                    data[5] = checksum
                    
                    // Try writing to the I2C bus
                    let result = IOAVServiceWriteI2C(avService, 0x37, 0x51, data, UInt32(data.count))
                    print("Service \(name) attempt result: \(result)")
                }
                IOObjectRelease(service)
            }
            IOObjectRelease(iter)
        }
    }
}

// --- UI ---
struct MonitorView: View {
    var id: CGDirectDisplayID
    var name: String
    @State private var brightness: Double = 50
    @State private var contrast: Double = 50

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(name).font(.system(size: 11, weight: .bold)).foregroundColor(.blue)
            
            VStack {
                HStack {
                    Image(systemName: "sun.max.fill").font(.system(size: 10))
                    Slider(value: $brightness, in: 0...100) { editing in
                        if !editing { DDC.setVCP(displayID: id, vcp: 0x10, value: UInt8(brightness)) }
                    }
                }
                HStack {
                    Image(systemName: "circle.lefthalf.filled").font(.system(size: 10))
                    Slider(value: $contrast, in: 0...100) { editing in
                        if !editing { DDC.setVCP(displayID: id, vcp: 0x12, value: UInt8(contrast)) }
                    }
                }
            }
            Divider().padding(.vertical, 5)
        }
    }
}

struct MainView: View {
    // Detect all screens
    let screens = NSScreen.screens

    var body: some View {
        VStack(spacing: 10) {
            Text("MiniDisplay M4").font(.caption).bold()
            
            ScrollView {
                VStack {
                    ForEach(screens, id: \.self) { screen in
                        let displayID = screen.deviceDescription[NSDeviceDescriptionKey(rawValue: "NSScreenNumber")] as? CGDirectDisplayID ?? 0
                        // Only show external monitors (skip built-in if it were a laptop)
                        MonitorView(id: displayID, name: screen.localizedName)
                    }
                }
            }
            .frame(maxHeight: 300)

            Button("Quit") { NSApplication.shared.terminate(nil) }
                .controlSize(.small)
        }
        .padding()
        .frame(width: 250)
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