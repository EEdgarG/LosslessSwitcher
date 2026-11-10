//
//  MenuView.swift
//  LosslessSwitcher
//
//  Created by Vincent Neo on 23/6/25.
//

import SwiftUI


struct MenuView: View {
    
    @EnvironmentObject private var outputDevices: OutputDevices
    @EnvironmentObject private var defaults: Defaults
    
    @State var stream = LogReader()
    
    private var selectedDeviceUID: Binding<String?> {
        Binding(
            get: {
                outputDevices.selectedOutputDevice?.uid
                    ?? outputDevices.missingSelectedDevice?.uid
            },
            set: { outputDevices.selectOutputDevice(uid: $0) }
        )
    }
    
    var body: some View {
        VStack {
            ContentView()
            
            Divider()
            
            Button {
                defaults.userPreferIconStatusBarItem.toggle()
            } label: {
                Text(defaults.statusBarItemTitle)
            }
            
            Button {
                defaults.userPreferBitDepthDetection.toggle()
            } label: {
                HStack {
                    Text("Bit Depth Switching")
                    if defaults.userPreferBitDepthDetection {
                        Image(systemName: "checkmark")
                    }
                }
            }
            
            Button {
                defaults.userPreferSampleRateMultiples.toggle()
            } label: {
                HStack {
                    Text("Prefer Closest Sample Rate Multiple")
                    if defaults.userPreferSampleRateMultiples {
                        Image(systemName: "checkmark")
                    }
                }
            }
            
            Picker("Selected Device", selection: selectedDeviceUID) {
                Text("Default Device").tag(String?.none)
                ForEach(outputDevices.outputDevices, id: \.uid) { device in
                    Text(device.name).tag(device.uid)
                }
                if let missing = outputDevices.missingSelectedDevice {
                    Text("\(missing.name) (disconnected)").tag(String?.some(missing.uid))
                }
            }
            .pickerStyle(.menu)
            
            Menu {
                Text("Version - \(currentVersion)")
                Text("Build - \(currentBuild)")
            } label: {
                Text("About")
            }
            
            Menu {
                Button("Select Script...") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    panel.message = "Select a script that should be invoked when sample rate changes."
                    
                    panel.begin { response in
                        let path = panel.url?.path
                        DispatchQueue.main.async { [weak defaults] in
                            defaults?.shellScriptPath = path
                        }
                    }
                }
                
                Button("Clear Selection") {
                    defaults.shellScriptPath = nil
                }
                
                Text(defaults.shellScriptPath ?? "No selection")
                
            } label: {
                Text("Scripting")
            }
            
            Button {
                NSApp.terminate(self)
            } label: {
                Text("Quit LosslessSwitcher")
            }
        }
    }
}
