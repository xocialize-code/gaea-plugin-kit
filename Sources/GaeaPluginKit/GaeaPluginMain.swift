import Foundation
import GaeaProtocol

/// A plugin's `main`:
///
///     <worker>                       serve GPP on stdin and stdout (what Gaea launches)
///     <worker> --manifest            print manifest.json, generated from the definition
///     <worker> --manifest <file>     write it to <file> (the build does this before it signs)
public enum GaeaPluginMain {
    public static func run(_ definition: GaeaPluginDefinition,
                           arguments: [String] = CommandLine.arguments) async -> Never {
        let args = Array(arguments.dropFirst())
        if args.first == "--manifest" {
            do {
                let data = try definition.manifest().encoded()
                if args.count > 1 {
                    try data.write(to: URL(fileURLWithPath: args[1]))
                } else {
                    FileHandle.standardOutput.write(data)
                }
                exit(0)
            } catch {
                log("\(error)")
                exit(1)
            }
        }
        if !args.isEmpty {
            log("usage: \(arguments.first ?? "worker") [--manifest [file]]")
            exit(2)
        }
        await serve(definition)
    }

    /// The bundle's sealed manifest.json; without a bundle (a development run), the generated one.
    static func manifestBytes(_ definition: GaeaPluginDefinition) -> Data {
        if let url = Bundle.main.url(forResource: "manifest", withExtension: "json"),
           let data = try? Data(contentsOf: url) {
            return data
        }
        log("no manifest.json in \(Bundle.main.bundlePath); hello carries the generated manifest's digest")
        return (try? definition.manifest().encoded()) ?? Data()
    }

    static func serve(_ definition: GaeaPluginDefinition) async -> Never {
        // A host that goes away mid-write must not kill the worker with SIGPIPE before it can clean up.
        signal(SIGPIPE, SIG_IGN)
        let worker = GPPWorker(definition: definition, manifest: manifestBytes(definition),
                               connection: .standardOutput(), onExit: { status in exit(status) })
        await worker.sendHello()
        let lines = AsyncStream<String> { continuation in
            Thread.detachNewThread {
                while let line = readLine(strippingNewline: true) { continuation.yield(line) }
                continuation.finish()
            }
        }
        for await line in lines {
            await worker.handle(line: line)
        }
        await worker.endOfInput()
        exit(0)
    }
}
