import CryptoKit
import Darwin
import Foundation
import GaeaProtocol
import LightweightCodeRequirements
import Security

// gaea-plugin-check — a tiny Gaea host for a built .gaeaplugin. MLX-free, like the real host.
//
//   gaea-plugin-check <bundle.gaeaplugin> [--operation <op>] [--params '<json>']
//                     [--budget <bytes>] [--session <file.gpp>] [--no-run]
//
// 1. checks the bundle's signature statically: strict, nested code, every architecture, against a
//    Developer ID requirement pinned to GPP.trustedTeam, the one team v1 trusts (G-7, G-22);
// 2. launches the manifest's executable with Process.launchRequirement pinned to the same team, so the
//    kernel enforces it at exec;
// 3. checks hello against the manifest (plugin, models, engine, manifest_sha256);
// 4. drives configure → prepare → run (the first helper or offer, or --operation) → memory.query →
//    shutdown, printing every line, and samples the worker's phys_footprint from outside;
// 5. writes the session as a GPP transcript (--session) for tools/validate.py --transcript.
//
// --no-run stops after configure (memory.query, shutdown): for a machine with no Metal device, where
// only the signature, the launch and hello can be checked.
//
// Exits 0 only if every step passed.

struct Failure: Error, CustomStringConvertible { let description: String }

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("FAIL \(message)\n".utf8))
    exit(1)
}

func ok(_ message: String) { print("PASS \(message)") }

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}
// v1 trusts one team and nothing overrides it (G-22, AB-D-0184).
let team = GPP.trustedTeam
if args.contains("--team") { fail("--team is gone: Gaea v1 trusts only \(team) (G-22)") }
let operationArg = option("--operation")
let paramsArg = option("--params") ?? "{}"
let budget = UInt64(option("--budget") ?? "") ?? 8_000_000_000
let sessionPath = option("--session")
let noRun = args.contains("--no-run")
args.removeAll { $0 == "--no-run" }
guard let bundlePath = args.first else {
    fail("usage: gaea-plugin-check <bundle.gaeaplugin> [--operation op] [--params json] [--budget bytes] [--session file]")
}
let bundle = URL(fileURLWithPath: bundlePath).standardizedFileURL

// MARK: manifest

let manifestURL = bundle.appending(path: "Contents/Resources/manifest.json")
guard let manifestData = try? Data(contentsOf: manifestURL) else { fail("no \(manifestURL.path)") }
let manifest: PluginManifest
do { manifest = try JSONDecoder().decode(PluginManifest.self, from: manifestData) } catch {
    fail("manifest.json doesn't decode: \(error)")
}
let digest = SHA256.hash(data: manifestData).map { String(format: "%02x", $0) }.joined()
ok("manifest \(manifest.id) \(manifest.version), sha256 \(digest.prefix(12))…")
guard manifest.team == team else { fail("manifest team \(manifest.team) is not the trusted team \(team)") }

// MARK: static signature check (install time)

do {
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else { fail("not code") }
    let text = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists "
        + "and certificate leaf[field.1.2.840.113635.100.6.1.13] exists "
        + "and certificate leaf[subject.OU] = \"\(team)\""
    var requirement: SecRequirement?
    SecRequirementCreateWithString(text as CFString, [], &requirement)
    var error: Unmanaged<CFError>?
    let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
    let status = SecStaticCodeCheckValidityWithErrors(code, flags, requirement, &error)
    guard status == errSecSuccess else {
        fail("signature rejected (\(status)): \(error?.takeRetainedValue().localizedDescription ?? "")")
    }
    var info: CFDictionary?
    SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
    let dict = info as? [String: Any] ?? [:]
    let flagsValue = (dict[kSecCodeInfoFlags as String] as? UInt32) ?? 0
    let hardened = flagsValue & 0x10000 != 0  // CS_RUNTIME
    guard hardened else { fail("the signature has no hardened runtime") }
    ok("signature: Developer ID, team \(dict[kSecCodeInfoTeamIdentifier as String] ?? "?"), "
        + "id \(dict[kSecCodeInfoIdentifier as String] ?? "?"), hardened runtime, requirement `\(text)` satisfied")
}

// MARK: launch

let executable = bundle.appending(path: "Contents/MacOS/\(manifest.executable)")
let scratch = FileManager.default.temporaryDirectory.appending(path: "gaea-plugin-check-\(UUID().uuidString)")
let modelsRoot = scratch.appending(path: "models"), cacheRoot = scratch.appending(path: "cache")
try? FileManager.default.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)

final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var lines: [String] = []
    private let ready = DispatchSemaphore(value: 0)
    var exited = false

    func ingest(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var count = 0
        while let nl = buffer.firstIndex(of: 0x0A) {
            lines.append(String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...nl)
            count += 1
        }
        lock.unlock()
        for _ in 0..<count { ready.signal() }
    }

    func close() { lock.lock(); exited = true; lock.unlock(); ready.signal() }

    func next(timeout: TimeInterval) -> String? {
        guard ready.wait(timeout: .now() + timeout) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return lines.isEmpty ? nil : lines.removeFirst()
    }
}

let process = Process()
process.executableURL = executable
process.currentDirectoryURL = cacheRoot
do {
    process.launchRequirement = try LaunchCodeRequirement.allOf {
        TeamIdentifier(team)
        ValidationCategory(.developerID)
    }
} catch { fail("launch requirement: \(error)") }
let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
process.standardInput = stdinPipe
process.standardOutput = stdoutPipe
process.standardError = stderrPipe
let lines = Lines()
stdoutPipe.fileHandleForReading.readabilityHandler = { h in
    let d = h.availableData
    if d.isEmpty { h.readabilityHandler = nil } else { lines.ingest(d) }
}
stderrPipe.fileHandleForReading.readabilityHandler = { h in
    let d = h.availableData
    if d.isEmpty { h.readabilityHandler = nil } else { FileHandle.standardError.write(d) }
}
let exitedSemaphore = DispatchSemaphore(value: 0)
process.terminationHandler = { _ in lines.close(); exitedSemaphore.signal() }  // a refused launch is a SIGKILL
let launched = Date()
do { try process.run() } catch { fail("launch: \(error)") }
ok("launched \(manifest.executable) with launchRequirement (team \(team), developerID), pid \(process.processIdentifier)")

var session: [String] = []
func send(_ message: [String: JSONValue]) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try! encoder.encode(message)
    session.append("H " + String(decoding: data, as: UTF8.self))
    print("H " + String(decoding: data, as: UTF8.self))
    stdinPipe.fileHandleForWriting.write(data + Data([0x0A]))
}

var peakFootprint: UInt64 = 0
func footprint() -> UInt64 {
    var info = rusage_info_v4()
    let r = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(process.processIdentifier, RUSAGE_INFO_V4, $0)
        }
    }
    return r == 0 ? info.ri_phys_footprint : 0
}

/// Read worker lines until `done` says the conversation step ended.
@discardableResult
func receive(timeout: TimeInterval = 120, until done: ([String: JSONValue]) -> Bool) -> [[String: JSONValue]] {
    var got: [[String: JSONValue]] = []
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        peakFootprint = max(peakFootprint, footprint())
        guard let line = lines.next(timeout: 0.05) else {
            if lines.exited { fail("the worker exited (status \(process.terminationStatus), reason \(process.terminationReason.rawValue))") }
            continue
        }
        print("W " + line)
        session.append("W " + line)
        guard let m = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)).objectValue else {
            fail("the worker wrote a line that isn't a JSON object: \(line)")
        }
        got.append(m)
        if m["type"]?.stringValue == "error" { fail("the worker answered an error: \(line)") }
        if done(m) { return got }
    }
    fail("timed out waiting for the worker")
}

// hello
let hello = receive(timeout: 10) { $0["type"]?.stringValue == "hello" }.last!
ok(String(format: "hello after %.0f ms", Date().timeIntervalSince(launched) * 1000))
guard hello["plugin"] == ["id": .string(manifest.id), "version": .string(manifest.version)] else { fail("hello plugin differs from the manifest") }
guard hello["models"] == .array(manifest.models.map { .string($0.id) }) else { fail("hello models differ from the manifest") }
guard hello["manifest_sha256"]?.stringValue == digest else { fail("hello manifest_sha256 isn't the bundle manifest's digest") }
if let engine = manifest.engine {
    guard hello["engine"] == ["version": .string(engine.version), "contract": .string(engine.contract)] else {
        fail("hello engine differs from the manifest")
    }
}
ok("hello matches the verified manifest (plugin, models, engine, manifest_sha256)")

// configure
send(["type": "configure", "id": "h1", "budget": ["ceilingBytes": .int(Int64(budget)), "wiresWeights": false],
      "models_root": .string(modelsRoot.path), "cache_root": .string(cacheRoot.path), "settings": [:]])
receive { $0["type"]?.stringValue == "configured" }

if !noRun {
    // pick the operation
    let target: (operation: String, model: String)
    if let operationArg {
        guard let model = manifest.helpers?.first(where: { $0.operation == operationArg })?.model
            ?? manifest.offers.first(where: { $0.operation == operationArg })?.modelID else {
            fail("the manifest neither offers nor helps with \(operationArg)")
        }
        target = (operationArg, model)
    } else if let helper = manifest.helpers?.first {
        target = (helper.operation, helper.model)
    } else if let offer = manifest.offers.first, let model = offer.modelID {
        target = (offer.operation, model)
    } else {
        fail("nothing to run")
    }
    guard let model = manifest.models.first(where: { $0.id == target.model }),
          let lane = model.lanes.first(where: \.default) else { fail("no default lane of \(target.model)") }

    // prepare
    send(["type": "prepare", "id": "h2", "model": .string(model.id), "lane": .string(lane.id)])
    receive { $0["type"]?.stringValue == "memory" }

    // run
    guard let params = try? JSONDecoder().decode(JSONValue.self, from: Data(paramsArg.utf8)), params.objectValue != nil else {
        fail("--params is not a JSON object")
    }
    let outputDir = scratch.appending(path: "spool/job_check/out")
    let ran = Date()
    send(["type": "run", "id": "h3", "job": "job_check", "operation": .string(target.operation), "model": .string(model.id),
          "lane": .string(lane.id), "inputs": [:], "params": params, "output_dir": .string(outputDir.path)])
    let runLines = receive { $0["type"]?.stringValue == "memory" }
    guard let result = runLines.first(where: { $0["type"]?.stringValue == "result" }) else { fail("no result") }
    let progressCount = runLines.filter { $0["type"]?.stringValue == "progress" }.count
    ok(String(format: "%@ ran in %.2f s (wall %.2f s), %d progress lines; outputs %@", target.operation,
              result["seconds"]?.doubleValue ?? -1, Date().timeIntervalSince(ran), progressCount,
              String(describing: (try? JSONEncoder().encode(result["outputs"])).map { String(decoding: $0, as: UTF8.self) } ?? "?")))
} else {
    ok("--no-run: no prepare or run")
}

// memory.query
send(["type": "memory.query", "id": "h4"])
let memory = receive { $0["type"]?.stringValue == "memory" && $0["re"] != nil }.last!
let reported = memory["report"]?["physFootprintBytes"]?.intValue ?? -1
ok("memory report: worker says phys_footprint \(reported) B; host read \(footprint()) B now, peak \(peakFootprint) B")

// shutdown
send(["type": "shutdown", "id": "h5"])
guard exitedSemaphore.wait(timeout: .now() + 10) == .success else { fail("no exit within 10 s of shutdown") }
guard process.terminationReason == .exit, process.terminationStatus == 0 else {
    fail("exit status \(process.terminationStatus), reason \(process.terminationReason.rawValue)")
}
ok("shutdown: exit 0")

if let sessionPath {
    let text = "# manifest: \(manifestURL.path)\n# gaea-plugin-check session against \(bundle.lastPathComponent)\n"
        + session.joined(separator: "\n") + "\n"
    do { try text.write(toFile: sessionPath, atomically: true, encoding: .utf8) } catch { fail("\(error)") }
    ok("session written to \(sessionPath)")
}
print("ALL PASS")
exit(0)
