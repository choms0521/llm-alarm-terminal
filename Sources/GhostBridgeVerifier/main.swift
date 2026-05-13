import Foundation
import GhosttyKit

// Day 2 spike: confirm that libghostty's embedding C API is callable from Swift
// via the GhosttyKit module map. This program intentionally stays under 30
// meaningful lines and exits 0 on success, non-zero on failure.

var argv: UnsafeMutablePointer<CChar>? = nil
let initRc = ghostty_init(0, &argv)
guard initRc == GHOSTTY_SUCCESS else {
    FileHandle.standardError.write(Data("ghostty_init failed rc=\(initRc)\n".utf8))
    exit(1)
}

guard let cfg: ghostty_config_t = ghostty_config_new() else {
    FileHandle.standardError.write(Data("ghostty_config_new returned NULL\n".utf8))
    exit(2)
}

ghostty_config_free(cfg)
print("OK: ghostty_init + config_new/free round-trip succeeded")
