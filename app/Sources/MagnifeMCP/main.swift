import Foundation
import MagnifeKit

// magnife-mcp: Magnife's MCP server for coding agents (S-034, docs/mcp.md).
// The agent starts it and talks MCP over stdio, one JSON-RPC message per line;
// it reads Magnife's database read-only and exits when stdin closes.
//
//   magnife-mcp                  the store in ~/Library/Application Support/Magnife
//   magnife-mcp --store <file>   another store (APP_STORE=<file> too)
//   magnife-mcp --version

func usage() -> Never {
    FileHandle.standardError.write(Data("""
        usage: magnife-mcp [--store <magnife.sqlite>] [--version]
        Magnife's MCP server: start it from an MCP client, which talks to it over stdin and stdout.
        Claude Code: claude mcp add magnife -- \(CommandLine.arguments[0])

        """.utf8))
    exit(2)
}

/// CFBundleShortVersionString of the Magnife.app this program is inside
/// (Contents/Helpers/magnife-mcp), else "dev".
func appVersion() -> String {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let plist = executable.deletingLastPathComponent().deletingLastPathComponent().appending(path: "Info.plist")
    guard let info = NSDictionary(contentsOf: plist), let version = info["CFBundleShortVersionString"] as? String else { return "dev" }
    return version
}

var storeURL = StoreLocation.url()
var arguments = CommandLine.arguments.dropFirst()
while let argument = arguments.popFirst() {
    switch argument {
    case "--store":
        guard let path = arguments.popFirst() else { usage() }
        storeURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    case "--version":
        print("magnife-mcp \(appVersion())")
        exit(0)
    case "-h", "--help":
        usage()
    default:
        FileHandle.standardError.write(Data("magnife-mcp: unknown argument \(argument)\n".utf8))
        usage()
    }
}

let server = MCPServer(toolbox: MagnifeTools(store: StoreConnection(url: storeURL)), version: appVersion())
FileHandle.standardError.write(Data("magnife-mcp \(server.version): reading \(storeURL.path)\n".utf8))

// One message at a time, in order; stdout carries nothing but answers.
do {
    for try await line in FileHandle.standardInput.bytes.lines {
        if let answer = await server.handle(line: line) {
            FileHandle.standardOutput.write(Data((answer + "\n").utf8))
        }
    }
} catch {
    FileHandle.standardError.write(Data("magnife-mcp: stdin: \(error)\n".utf8))
    exit(1)
}
