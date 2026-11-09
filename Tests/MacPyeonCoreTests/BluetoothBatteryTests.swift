import Foundation
import Testing
@testable import MacPyeonCore

struct BluetoothBatteryTests {
    @Test func parsesAirPodsAndMagicDevices() {
        let json = """
        {"SPBluetoothDataType":[{"controller_properties":{},
          "device_connected":[
            {"AirPods Pro":{"device_minorType":"Headphones","device_batteryLevelLeft":"80%","device_batteryLevelRight":"75%","device_batteryLevelCase":"40%"}},
            {"Magic Mouse":{"device_minorType":"Mouse","device_batteryLevelMain":"62%"}},
            {"PL87W-1":{"device_minorType":"Keyboard"}}
          ],
          "device_not_connected":[{"Old":{"device_batteryLevelMain":"10%"}}]}]}
        """.data(using: .utf8)!
        let list = BluetoothBatteryParser.parseSystemProfiler(json)
        #expect(list.map(\.name) == ["AirPods Pro", "Magic Mouse", "PL87W-1"])
        #expect(list[0].left == 80 && list[0].right == 75 && list[0].caseLevel == 40 && list[0].lowest == 75)
        #expect(list[1].main == 62 && list[1].symbol == "computermouse")
        #expect(list[2].hasLevel == false)
    }

    @Test func mergeFillsMissingLevels() {
        let a = [DeviceBattery(name: "PL87W-1", kind: "Keyboard")]
        let b = [DeviceBattery(name: "PL87W-1", kind: "", main: 55), DeviceBattery(name: "BLE Mouse", kind: "Mouse", main: 90)]
        let merged = BluetoothBatteryParser.merge([a, b])
        #expect(merged.map(\.name) == ["PL87W-1", "BLE Mouse"])
        #expect(merged[0].main == 55 && merged[0].kind == "Keyboard")
    }

    @Test func percentParsing() {
        #expect(BluetoothBatteryParser.percent("85%") == 85)
        #expect(BluetoothBatteryParser.percent(NSNumber(value: 7)) == 7)
        #expect(BluetoothBatteryParser.percent("abc") == nil)
        #expect(BluetoothBatteryParser.percent("150%") == nil)
    }
}
