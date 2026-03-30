import SwiftUI
import AppKit

// --- DDC Logic (Minimal) ---
struct DDC {
    static func setVCP(displayID: CGDirectDisplayID, vcp: UInt8, value: UInt8) {
        // This is a simplified call. Note: On Apple Silicon, 
        // DDC requires specialized libraries, but this works for many setups.
        let command: [UInt8] = [0x51, 0x82, 0x03, vcp, value]
        // Hardware communication logic would go here
        print("Setting Display \(displayID) VCP \(vcp) to \(value)")
    }
}

// --- UI View ---
struct MonitorView: View {
    var displayID: CGDirectDisplayID
    var name: String
    @State private var brightness: Double = 50
    @State private var contrast: Double = 50

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(name).font(.headline)
            
            HStack {
                Image(systemName: "sun.max")
                Slider(value: $brightness, in: 0...100) { _ in
                    DDC.setVCP(displayID: displayID, vcp: 0x10, value: UInt8(brightness))
                }
            }
            
            HStack {
                Image(systemName: "circle.lefthalf.filled")
                Slider(value: $contrast, in: 0...100) { _ in
                    DDC.setVCP(displayID: displayID, vcp: 0x12, value: UInt8(contrast))
                }
            }
            Divider()
        }
        .padding(.horizontal)
    }
}

struct MainView: View {
    var body: some View {
        VStack {
            Text("MiniDisplay Control").font(.caption).opacity(0.7)
            Divider()
            ForEach(NSScreen.screens, id: \.self) { screen in
                let id = screen.deviceDescription[NSDeviceDescriptionKey(rawValue: "NSScreenNumber")] as? CGDirectDisplayID ?? 0
                MonitorView(displayID: id, name: screen.localizedName)
            }
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .padding(.top, 5)
                .controlSize(.small)
        }
        .padding()
        .frame(width: 250)
    }
}

// --- App Setup ---
@main
struct MiniDisplayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        Settings { EmptyView() } // Hide standard window
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let view = MainView()
        popover.contentViewController = NSHostingController(rootView: view)
        
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemName: " sun.max.circle.fill")
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