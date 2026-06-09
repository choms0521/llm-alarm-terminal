import Foundation

// Dev CLI for the in-process daemon round-trip demo.
//
// P4 Day 6 fills this in with the real loopback WS round-trip:
//   connect to 127.0.0.1:<port> -> session.start(external) -> input -> output.
// This seed only establishes the `tool` target entry point so the build graph
// links a real executable from Day 0 onward.

let arguments = CommandLine.arguments
FileHandle.standardError.write(
    Data("DaemonDevCLI seed — round-trip demo lands in P4 Day 6. args=\(arguments.count)\n".utf8)
)
exit(0)
