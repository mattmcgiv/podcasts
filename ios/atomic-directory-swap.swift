import Darwin

func fail(_ message: String, status: Int32) -> Never {
    _ = message.withCString { pointer in
        fputs(pointer, stderr)
    }
    exit(status)
}

guard CommandLine.arguments.count == 3 else {
    fail("usage: atomic-directory-swap.swift <first> <second>\n", status: 64)
}

let first = CommandLine.arguments[1]
let second = CommandLine.arguments[2]

func rename(flags: UInt32) -> Int32 {
    first.withCString { firstPath in
        second.withCString { secondPath in
            renamex_np(firstPath, secondPath, flags)
        }
    }
}

for _ in 0..<8 {
    if rename(flags: UInt32(RENAME_EXCL)) == 0 {
        exit(0)
    }
    var code = errno
    guard code == EEXIST else {
        let description = String(cString: strerror(code))
        fail("error: atomic directory activation failed: \(description)\n", status: code == 0 ? 1 : code)
    }

    if rename(flags: UInt32(RENAME_SWAP)) == 0 {
        exit(0)
    }
    code = errno
    if code == ENOENT {
        continue
    }
    let description = String(cString: strerror(code))
    fail("error: atomic directory activation failed: \(description)\n", status: code == 0 ? 1 : code)
}

let code = errno
let description = String(cString: strerror(code))
fail("error: atomic directory activation did not stabilize: \(description)\n", status: code == 0 ? 1 : code)
