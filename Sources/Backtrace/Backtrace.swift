//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftLinuxBacktrace open source project
//
// Copyright (c) 2019-2022 Apple Inc. and the SwiftLinuxBacktrace project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftLinuxBacktrace project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if os(Linux)
import CBacktrace
import Glibc
import Foundation

typealias CBacktraceErrorCallback = @convention(c) (_ data: UnsafeMutableRawPointer?, _ msg: UnsafePointer<CChar>?, _ errnum: CInt) -> Void
typealias CBacktraceFullCallback = @convention(c) (_ data: UnsafeMutableRawPointer?, _ pc: UInt, _ filename: UnsafePointer<CChar>?, _ lineno: CInt, _ function: UnsafePointer<CChar>?) -> CInt
typealias CBacktraceSimpleCallback = @convention(c) (_ data: UnsafeMutableRawPointer?, _ pc: UInt) -> CInt
typealias CBacktraceSyminfoCallback = @convention(c) (_ data: UnsafeMutableRawPointer?, _ pc: UInt, _ filename: UnsafePointer<CChar>?, _ symval: UInt, _ symsize: UInt) -> Void

private var crashout_path: String?
private var crashout = stderr
private var crashcycle = 0

private let state = backtrace_create_state(nil, /* BACKTRACE_SUPPORTS_THREADS */ 1, nil, nil)

private func checkCrashOutFile() {
    guard crashcycle < 10 else { fatalError("cyclic backtrace detected") }
    crashcycle += 1
    
    guard let crashout_path = crashout_path else { return }
    guard crashout == stderr else { return }
    crashout = fopen(crashout_path, "w")
}

private let fullCallback: CBacktraceFullCallback? = {
    _, pc, filename, lineno, function in
    
    checkCrashOutFile()

    var str = "0x"
    str.append(String(pc, radix: 16))
    if let function = function {
        str.append(", ")
        var fn = String(cString: function)
        if fn.hasPrefix("$s") || fn.hasPrefix("$S") {
            fn = _stdlib_demangleName(fn)
        }
        str.append(fn)
    }
    if let filename = filename {
        str.append(" at ")
        str.append(String(cString: filename))
        str.append(":")
        str.append(String(lineno))
    }
    str.append("\n")

    str.withCString { ptr in
        _ = withVaList([ptr]) { vaList in
            vfprintf(crashout, "%s", vaList)
        }
    }
    return 0
}

private let errorCallback: CBacktraceErrorCallback? = {
    _, msg, errNo in
    if let msg = msg {
        checkCrashOutFile()
        
        _ = withVaList([msg, errNo]) { vaList in
            vfprintf(crashout, "SwiftBacktrace ERROR: %s (errno: %d)\n", vaList)
        }
    }
}

private func printBacktrace(signal: CInt) {
    _ = fputs("Received signal \(signal). Backtrace:\n", crashout)
    backtrace_full(state, /* skip */ 0, fullCallback, errorCallback, nil)
    fflush(crashout)
}

public enum Backtrace {
    /// Install the backtrace handler on default signals: `SIGILL`, `SIGSEGV`, `SIGBUS`, `SIGFPE`.
    public static func install(path: String? = nil) {
        Backtrace.install(signals: [SIGILL, SIGSEGV, SIGBUS, SIGFPE],
                          path: path)
    }

    /// Install the backtrace handler when any of `signals` happen.
    public static func install(signals: [CInt],
                               path: String? = nil) {
        crashout_path = path

        for signal in signals {
            Backtrace.signal(signal) { signal in
                printBacktrace(signal: signal)
                raise(signal)
            }
        }
    }

    @available(*, deprecated, message: "This method will be removed in the next major version.")
    public static func print() {
        backtrace_full(state, /* skip */ 0, fullCallback, errorCallback, nil)
    }
}

extension Backtrace {
    public static func signal(_ signal: Int32, handler: @escaping @convention(c) (CInt) -> Void) {
        typealias sigaction_t = sigaction
        let sa_flags = CInt(SA_NODEFER) | CInt(bitPattern: CUnsignedInt(SA_RESETHAND))
        var sa = sigaction_t(__sigaction_handler: unsafeBitCast(handler, to: sigaction.__Unnamed_union___sigaction_handler.self),
                             sa_mask: sigset_t(),
                             sa_flags: sa_flags,
                             sa_restorer: nil)
        withUnsafePointer(to: &sa) { ptr -> Void in
            sigaction(signal, ptr, nil)
        }
    }
}

#else

import Foundation

public enum Backtrace {
    /// Install the backtrace handler on default signals. Available on Windows and Linux only.
    public static func install(path: String? = nil) {}

    /// Install the backtrace handler on specific signals. Available on Linux only.
    public static func install(signals: [CInt],
                               path: String? = nil) {}

    @available(*, deprecated, message: "This method will be removed in the next major version.")
    public static func print() {}
}

extension Backtrace {
    public static func signal(_ signal: Int32, handler: @escaping @convention(c) (CInt) -> Void) {
        typealias sigaction_t = sigaction
        let sa_flags = CInt(SA_NODEFER) | CInt(bitPattern: CUnsignedInt(SA_RESETHAND))
        var sa = sigaction_t(__sigaction_u: unsafeBitCast(handler, to: __sigaction_u.self),
                             sa_mask: sigset_t(),
                             sa_flags: sa_flags)
        withUnsafePointer(to: &sa) { ptr -> Void in
            sigaction(signal, ptr, nil)
        }
    }
}

#endif
