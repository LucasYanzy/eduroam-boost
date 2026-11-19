// eduroam-boost-helper: the parts of macOS Wi-Fi control that need Location permission.
//
// macOS hides network names and BSSIDs from processes without Location Services access,
// and only an app bundle can ask for that permission. This tiny agent app does:
//   authorize                 ask for Location permission (one-time system prompt)
//   scan                      every visible BSS as JSON, including the AP's advertised load
//   current                   the BSS we are associated with, as JSON
//   watch --out F             stream a scan every --interval s as JSON lines (stop with F.stop)
//
// It writes JSON to the file given by --out (because `open` does not relay stdout).
import AppKit
import CoreLocation
import CoreWLAN
import Foundation

var outPath: String?
var output: [String: Any] = [:]

func finish(_ code: Int32) -> Never {
    let data = (try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    if let p = outPath { FileManager.default.createFile(atPath: p, contents: data) } else { FileHandle.standardOutput.write(data) }
    exit(code)
}

// ---------------------------------------------------------------- location permission

final class Auth: NSObject, CLLocationManagerDelegate {
    let manager = CLLocationManager()
    var decided = false
    func status() -> String {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not_determined"
        @unknown default: return "unknown"
        }
    }
    func refresh() -> String {
        manager.delegate = self
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        return status()
    }
    func request(timeout: TimeInterval) -> String {
        manager.delegate = self
        if manager.authorizationStatus == .notDetermined {
            NSApplication.shared.setActivationPolicy(.accessory)
            NSApplication.shared.activate(ignoringOtherApps: true)
            manager.requestWhenInUseAuthorization()
            let deadline = Date().addingTimeInterval(timeout)
            while !decided && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
        }
        return status()
    }
    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        if m.authorizationStatus != .notDetermined { decided = true }
    }
}

// ---------------------------------------------------------------- Wi-Fi helpers

func band(_ ch: CWChannel?) -> String {
    switch ch?.channelBand {
    case .band2GHz: return "2.4GHz"
    case .band5GHz: return "5GHz"
    case .band6GHz: return "6GHz"
    default: return "?"
    }
}

func width(_ ch: CWChannel?) -> Int {
    switch ch?.channelWidth {
    case .width20MHz: return 20
    case .width40MHz: return 40
    case .width80MHz: return 80
    case .width160MHz: return 160
    default: return 0
    }
}

/// 802.11 BSS Load element (ID 11): station count, channel utilization (0-255), admission capacity.
func bssLoad(_ ie: Data?) -> [String: Any]? {
    guard let ie = ie else { return nil }
    let b = [UInt8](ie)
    var i = 0
    while i + 2 <= b.count {
        let id = b[i], len = Int(b[i + 1])
        if i + 2 + len > b.count { break }
        if id == 11 && len >= 3 {
            let stations = Int(b[i + 2]) | Int(b[i + 3]) << 8
            let util = Int(b[i + 4])
            return ["stations": stations, "utilization_pct": Int((Double(util) / 255.0 * 100).rounded())]
        }
        i += 2 + len
    }
    return nil
}

func describe(_ n: CWNetwork) -> [String: Any] {
    var d: [String: Any] = [
        "ssid": n.ssid ?? NSNull(), "bssid": n.bssid ?? NSNull(),
        "rssi": n.rssiValue, "noise": n.noiseMeasurement,
        "channel": n.wlanChannel?.channelNumber ?? 0, "band": band(n.wlanChannel), "width_mhz": width(n.wlanChannel),
        "enterprise": n.supportsSecurity(.wpa2Enterprise) || n.supportsSecurity(.wpa3Enterprise) || n.supportsSecurity(.wpaEnterprise),
    ]
    if let load = bssLoad(n.informationElementData) { d["load"] = load }
    return d
}

func currentInfo(_ iface: CWInterface) -> [String: Any] {
    [
        "ssid": iface.ssid() ?? NSNull(), "bssid": iface.bssid() ?? NSNull(),
        "rssi": iface.rssiValue(), "noise": iface.noiseMeasurement(), "tx_rate": iface.transmitRate(),
        "channel": iface.wlanChannel()?.channelNumber ?? 0, "band": band(iface.wlanChannel()), "width_mhz": width(iface.wlanChannel()),
    ]
}

// ---------------------------------------------------------------- main

var args = Array(CommandLine.arguments.dropFirst())
if let i = args.firstIndex(of: "--out"), i + 1 < args.count { outPath = args[i + 1]; args.removeSubrange(i...(i + 1)) }
let command = args.first ?? "scan"

let auth = Auth()
output["location"] = command == "authorize" ? auth.request(timeout: 180) : auth.refresh()
if command == "authorize" { finish(output["location"] as? String == "authorized" ? 0 : 3) }

guard let iface = CWWiFiClient.shared().interface() else { output["error"] = "no Wi-Fi interface"; finish(1) }
output["current"] = currentInfo(iface)

func scanOnce(_ iface: CWInterface) throws -> [[String: Any]] {
    try iface.scanForNetworks(withSSID: nil).sorted { $0.rssiValue > $1.rssiValue }.map(describe)
}

switch command {
case "current":
    finish(0)

case "scan":
    do { output["networks"] = try scanOnce(iface); finish(0) }
    catch { output["error"] = "scan failed: \(error.localizedDescription)"; finish(1) }

case "watch":
    // Stream one JSON object per line to --out every --interval seconds, until <out>.stop
    // appears or --duration runs out. Used by `eduroam-boost seat`.
    guard let path = outPath else { output["error"] = "watch needs --out"; finish(64) }
    func opt(_ name: String, _ dflt: Double) -> Double {
        if let i = args.firstIndex(of: name), i + 1 < args.count, let v = Double(args[i + 1]) { return v }
        return dflt
    }
    let interval = max(2.0, opt("--interval", 4)), duration = min(3600.0, opt("--duration", 600))
    FileManager.default.createFile(atPath: path, contents: nil)
    let fh = FileHandle(forWritingAtPath: path)!
    let end = Date().addingTimeInterval(duration)
    while Date() < end && !FileManager.default.fileExists(atPath: path + ".stop") {
        var line: [String: Any] = ["location": output["location"] ?? "", "current": currentInfo(iface),
                                   "ts": ISO8601DateFormatter().string(from: Date())]
        do { line["networks"] = try scanOnce(iface) } catch { line["error"] = error.localizedDescription }
        if let data = try? JSONSerialization.data(withJSONObject: line) {
            fh.seekToEndOfFile(); fh.write(data); fh.write("\n".data(using: .utf8)!)
        }
        Thread.sleep(forTimeInterval: interval)
    }
    try? FileManager.default.removeItem(atPath: path + ".stop")
    exit(0)

default:
    output["error"] = "unknown command \(command)"
    finish(64)
}
