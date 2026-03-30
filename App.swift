import SwiftUI
import AppKit

// Basic DDC Logic (Conceptual)
// Note: Hardware-level DDC on M1/M2 usually requires private frameworks or I2C drivers.
// This is a minimal UI template that you can expand.
struct DDC {
    static func setVCP(displayID: CGDirectDisplayID, vcp: UInt8, value: UInt8) {
        print("Setting Display \(displayID) VCP \(vcp) to \(value)")
        // Actual DDC implementation involves I2C calls via IOKit
    }
}

struct MonitorView: View {
    var displayID: CGDirectDisplayID
    var name: String
    @State private var brightness: Double = 50
    @State private var contrast: Double = 50

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(name).font(.system(size: 12, weight: .bold))
            
            HStack {
                Image(systemName: "sun.max.fill").frame(width: 20)
                Slider(value: $brightness, in: 0...100) { _ in
                    DDC.setVCP(displayID: displayID, vcp: 0x10, value: UInt8(brightness))
                }
            }
            
            HStack {
                Image(systemName: "circle.lefthalf.filled").frame(width: 20)
                Slider(value: $contrast, in: 0...100) { _ in
                    DDC.setVCP(displayID: displayID, vcp: 0x12, value: UInt8(contrast))
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
            
            Button("Quit MiniDisplay") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding()
        .frame(width: 240)
    }
}

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
            button.image = NSImage(systemName: "display")
            button.action = #selector(togglePopover)
        }
    }

    @objc func togglePopover() {
        if let button = statusItem?.button {
            if popover.isShown {
                popover.performClose(nil)
            } else {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            }
        }
    }
}