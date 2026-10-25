import Foundation

enum FixtureError: Error {
    case badNPY(String)
}

/// A numpy array loaded from an uncompressed `.npy` file.
struct NPYArray {
    let shape: [Int]
    let values: [Double]

    var floats: [Float] { values.map(Float.init) }
}

enum Fixtures {
    /// `Tests/Fixtures`, located relative to this source file.
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

    static func url(_ path: String) -> URL {
        root.appendingPathComponent(path)
    }

    /// Reads a little-endian float32 or float64 `.npy` file (format versions 1 and 2).
    static func npy(_ path: String) throws -> NPYArray {
        let data = try Data(contentsOf: url(path))
        guard data.count > 10, data.prefix(6) == Data([0x93] + Array("NUMPY".utf8)) else {
            throw FixtureError.badNPY("\(path): bad magic")
        }
        let major = data[6]
        let lengthBytes = major == 1 ? 2 : 4
        var headerLength = 0
        for i in 0..<lengthBytes { headerLength |= Int(data[8 + i]) << (8 * i) }
        let bodyStart = 8 + lengthBytes + headerLength
        let header = String(decoding: data[(8 + lengthBytes)..<bodyStart], as: UTF8.self)

        guard let descr = header.firstMatch(of: /'descr':\s*'([^']+)'/)?.1,
            let shapeText = header.firstMatch(of: /'shape':\s*\(([^)]*)\)/)?.1,
            header.contains("'fortran_order': False")
        else { throw FixtureError.badNPY("\(path): unsupported header \(header)") }
        let shape = shapeText.split(separator: ",").compactMap {
            Int($0.trimmingCharacters(in: .whitespaces))
        }
        let count = shape.reduce(1, *)
        let body = data.subdata(in: bodyStart..<data.count)
        let values: [Double]
        switch descr {
        case "<f4":
            values = body.withUnsafeBytes { raw in
                (0..<count).map { Double(raw.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self)) }
            }
        case "<f8":
            values = body.withUnsafeBytes { raw in
                (0..<count).map { raw.loadUnaligned(fromByteOffset: $0 * 8, as: Double.self) }
            }
        default:
            throw FixtureError.badNPY("\(path): unsupported dtype \(descr)")
        }
        guard values.count == count else { throw FixtureError.badNPY("\(path): truncated") }
        return NPYArray(shape: shape, values: values)
    }
}
