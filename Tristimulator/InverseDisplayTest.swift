//
//  InverseDisplayTest.swift
//  Tristimulator
//
//  Test suite for inverse display transform functionality
//

import Foundation

#if DEBUG

class InverseDisplayTransformTests {
    
    static func runAllTests() {
        print("🧪 Running Inverse Display Transform Tests")
        print("==========================================\n")
        
        testEnumDefinition()
        testImageManagerProperties()
        testOCIOBridgeAvailability()
        testInverseDisplayProcessorCreation()
        
        print("\n✅ All tests completed")
    }
    
    static func testEnumDefinition() {
        print("Test 1: SourceTransformMode enum")
        
        let colorspaceMode = SourceTransformMode.colorspace
        let inverseDisplayMode = SourceTransformMode.inverseDisplay
        
        assert(colorspaceMode.rawValue == "Color Space", "Colorspace mode raw value incorrect")
        assert(inverseDisplayMode.rawValue == "Inverse Display", "Inverse display mode raw value incorrect")
        assert(colorspaceMode.id == "Color Space", "Colorspace mode ID incorrect")
        
        print("  ✅ Enum definition correct")
    }
    
    static func testImageManagerProperties() {
        print("Test 2: ImageManager properties")
        
        let imageManager = ImageManager()
        
        // Default values
        assert(imageManager.sourceTransformMode == .colorspace, "Default mode should be colorspace")
        assert(imageManager.sourceInverseDisplay == "", "Default inverse display should be empty")
        assert(imageManager.sourceInverseView == "", "Default inverse view should be empty")
        
        // Test setting values
        imageManager.sourceTransformMode = .inverseDisplay
        imageManager.sourceInverseDisplay = "ACES"
        imageManager.sourceInverseView = "ACES 1.0 - SDR Video"
        
        assert(imageManager.sourceTransformMode == .inverseDisplay, "Mode change failed")
        assert(imageManager.sourceInverseDisplay == "ACES", "Display change failed")
        assert(imageManager.sourceInverseView == "ACES 1.0 - SDR Video", "View change failed")
        
        print("  ✅ ImageManager properties working correctly")
    }
    
    static func testOCIOBridgeAvailability() {
        print("Test 3: OCIO Bridge availability")
        
        let version = OpenColorIOBridge.version()
        print("  📊 OCIO Version: \(version)")
        
        let isAvailable = OpenColorIOBridge.isAvailable()
        print("  📊 OCIO Available: \(isAvailable)")
        
        if let config = OCIOConfig.default() {
            print("  ✅ OCIO config loaded")
            
            let displays = config.displayNames()
            print("  📊 Available displays: \(displays.count)")
            
            if !displays.isEmpty {
                let defaultDisplay = config.defaultDisplay()
                print("  📊 Default display: \(defaultDisplay)")
                
                let views = config.viewNames(forDisplay: defaultDisplay)
                print("  📊 Views for default display: \(views.count)")
            }
        } else {
            print("  ⚠️  No OCIO config available (this is OK for basic testing)")
        }
    }
    
    static func testInverseDisplayProcessorCreation() {
        print("Test 4: Inverse display processor creation")
        
        guard let config = OCIOConfig.default() else {
            print("  ⚠️  Skipped: No OCIO config available")
            return
        }
        
        let displays = config.displayNames()
        guard !displays.isEmpty else {
            print("  ⚠️  Skipped: No displays in config")
            return
        }
        
        let defaultDisplay = config.defaultDisplay()
        let views = config.viewNames(forDisplay: defaultDisplay)
        
        guard !views.isEmpty else {
            print("  ⚠️  Skipped: No views for default display")
            return
        }
        
        let defaultView = views[0]
        
        print("  📊 Testing inverse display processor:")
        print("     Display: \(defaultDisplay)")
        print("     View: \(defaultView)")
        
        do {
            let processor = try OCIOProcessor.makeInverseDisplayProcessor(
                config: config,
                display: defaultDisplay,
                view: defaultView
            )
            print("  ✅ Inverse display processor created successfully")
            
            // Test with sample pixel data
            let width = 2
            let height = 1
            let channels = 4
            
            var pixels: [Float] = [
                0.5, 0.5, 0.5, 1.0,  // Mid-gray
                1.0, 1.0, 1.0, 1.0   // White
            ]
            
            let inputData = Data(bytes: &pixels, count: pixels.count * MemoryLayout<Float>.size)
            
            let outputData = try processor.processPixelData(
                inputData,
                width: width,
                height: height,
                channels: channels
            )
            
            outputData.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
                let floats = ptr.bindMemory(to: Float.self)
                print("  📊 Processed pixels:")
                print("     Pixel 0: R=\(floats[0]), G=\(floats[1]), B=\(floats[2])")
                print("     Pixel 1: R=\(floats[4]), G=\(floats[5]), B=\(floats[6])")
            }
            
            print("  ✅ Pixel processing successful")
            
        } catch {
            print("  ❌ Error creating inverse display processor: \(error)")
        }
    }
}

#endif
