//
//  RemotePairing.swift
//  MacStroke
//
//  The QR payload the mini program scans, and the bitmap that shows it on the
//  About pane.
//

import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// `macstroke://pair?host=…&port=…&token=…`
///
/// A custom scheme rather than a mini program code: `wxacode.getUnlimited`
/// needs a published app plus an AppID/Secret round-trip to a server, which a
/// self-hosted Mac cannot do at the click of a switch. Scanning this text with
/// `wx.scanCode` inside the mini program gives the same one-tap pairing.
public enum RemotePairing {
    public struct Target: Equatable {
        public var host: String
        public var port: Int
        public var token: String
    }

    public static let scheme = "macstroke"

    public static func payload(host: String, port: Int, token: String) -> String {
        "macstroke://pair?host=\(host)&port=\(port)&token=\(token)"
    }

    /// Lenient reader: the phone may hand back the payload with percent-encoded
    /// or reordered parameters, and a user may paste it instead of scanning.
    public static func parse(_ text: String) -> Target? {
        guard let components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == scheme else { return nil }
        var items: [String: String] = [:]
        for item in components.queryItems ?? [] {
            items[item.name] = item.value
        }
        guard let host = items["host"], !host.isEmpty,
              let portText = items["port"], let port = Int(portText),
              let token = items["token"], !token.isEmpty else { return nil }
        return Target(host: host, port: port, token: token.uppercased())
    }
}

public enum RemoteQRCode {
    /// Renders a QR code as a fixed-size bitmap-backed image, so the About pane
    /// scales it without blurring the modules.
    public static func image(from text: String, side: CGFloat = 180) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard side > 0, let code = filter.outputImage else { return nil }
        let scale = max(1, side / code.extent.width)
        let scaled = code.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSBitmapImageRep(ciImage: scaled)
        let image = NSImage(size: NSSize(width: side, height: side))
        image.addRepresentation(rep)
        return image
    }
}
