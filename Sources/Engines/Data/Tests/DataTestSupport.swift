import Foundation

// Helpers shared by the data self-tests: running system tools, building raw zip files byte by byte (crafted names, flags, attributes), file comparisons.

enum DataTestKit {
    /// Runs a tool synchronously with stdin closed. Returns (exit status, stdout + stderr).
    @discardableResult
    static func run(_ exe: String, _ args: [String], cwd: URL? = nil) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "en_US.UTF-8"; env["LANG"] = "en_US.UTF-8"         // names are printed as UTF-8, not as octal escapes
        env["COPYFILE_DISABLE"] = "1"                                       // tar / zip on a Mac add ._ AppleDouble entries without this
        p.environment = env
        if let cwd { p.currentDirectoryURL = cwd }
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe; p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static func read(_ url: URL) -> Data { (try? Data(contentsOf: url)) ?? Data() }

    /// Resident memory of this process in MB (mach task info).
    static func residentMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
        return kr == KERN_SUCCESS ? Int(info.resident_size / 1_048_576) : -1
    }

    static func listDir(_ url: URL) -> [String] {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { return [] }
        var out: [String] = []
        for case let u as URL in e {
            let rel = String(u.path.dropFirst(url.path.count + 1))
            out.append(rel)
        }
        return out.sorted()
    }

    /// A deterministic, compressible text blob of about `bytes` bytes.
    static func compressibleText(bytes: Int) -> Data {
        var s = ""
        var i = 0
        while s.utf8.count < bytes { s += "line \(i % 97) of the swamp converter test payload, repeated a lot\n"; i += 1 }
        return Data(s.utf8.prefix(bytes))
    }

    /// Pseudo-random bytes (incompressible).
    static func noise(bytes: Int, seed: UInt64 = 7) -> Data {
        var rng = SplitMix(seed: seed)
        var d = Data(capacity: bytes)
        while d.count < bytes { var v = rng.next(); withUnsafeBytes(of: &v) { d.append(contentsOf: $0) } }
        return d.prefix(bytes)
    }
}

/// Builds a zip file byte by byte (stored entries only) so tests can craft names in any code page, hostile paths, encryption flags and unix attributes.
enum RawZip {
    struct Entry {
        var name: Data
        var data: Data = Data()
        var flags: UInt16 = 0
        /// 0 = MS-DOS (Windows tools), 3 = Unix.
        var host: UInt8 = 0
        var external: UInt32 = 0
        init(name: Data, data: Data = Data(), flags: UInt16 = 0, host: UInt8 = 0, external: UInt32 = 0) {
            self.name = name; self.data = data; self.flags = flags; self.host = host; self.external = external
        }
        init(_ name: String, _ data: String = "", flags: UInt16 = 0, host: UInt8 = 0, external: UInt32 = 0) {
            self.init(name: Data(name.utf8), data: Data(data.utf8), flags: flags, host: host, external: external)
        }
    }

    static func build(_ entries: [Entry], junkPrefix: Int = 0) -> Data {
        var out = ByteBuilder()
        out.append([UInt8](repeating: 0x20, count: junkPrefix))
        var central = ByteBuilder()
        for e in entries {
            let offset = out.bytes.count - junkPrefix
            let crc = Checksum.crc32(e.data)
            out.u32(0x0403_4B50); out.u16(20); out.u16(e.flags); out.u16(0); out.u16(0); out.u16(0x2821)
            out.u32(crc); out.u32(UInt32(e.data.count)); out.u32(UInt32(e.data.count)); out.u16(UInt16(e.name.count)); out.u16(0)
            out.append(e.name); out.append(e.data)
            central.u32(0x0201_4B50); central.u16(UInt16(e.host) << 8 | 20); central.u16(20); central.u16(e.flags); central.u16(0); central.u16(0); central.u16(0x2821)
            central.u32(crc); central.u32(UInt32(e.data.count)); central.u32(UInt32(e.data.count)); central.u16(UInt16(e.name.count))
            central.u16(0); central.u16(0); central.u16(0); central.u16(0); central.u32(e.external); central.u32(UInt32(offset))
            central.append(e.name)
        }
        let cdOffset = out.bytes.count - junkPrefix
        out.append(central.bytes)
        out.u32(0x0605_4B50); out.u16(0); out.u16(0); out.u16(UInt16(entries.count)); out.u16(UInt16(entries.count))
        out.u32(UInt32(central.bytes.count)); out.u32(UInt32(cdOffset)); out.u16(0)
        return Data(out.bytes)
    }
}
