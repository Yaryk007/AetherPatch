import Foundation
import Metal
import MetalKit
import UIKit
import Security

// Helper: log immediately
func aelog(_ msg: String) {
    NSLog("[AetherPS4] %@", msg)
    fflush(stdout)
    fflush(stderr)
}

// ── Entitlement + JIT-debug-state checking ──

private typealias SecTaskRef = OpaquePointer

@_silgen_name("SecTaskCopyValueForEntitlement")
private func SecTaskCopyValueForEntitlement(
    _ task: SecTaskRef,
    _ entitlement: NSString,
    _ error: NSErrorPointer
) -> CFTypeRef?

@_silgen_name("SecTaskCreateFromSelf")
private func SecTaskCreateFromSelf(_ allocator: CFAllocator?) -> SecTaskRef?

@_silgen_name("CFRelease")
private func aetherps4_CFRelease(_ cf: CFTypeRef?)

func checkAppEntitlement(_ ent: String) -> Bool {
    guard let task = SecTaskCreateFromSelf(nil) else { return false }
    defer { aetherps4_CFRelease(unsafeBitCast(task, to: CFTypeRef.self)) }

    guard let entitlement = SecTaskCopyValueForEntitlement(task, ent as NSString, nil) else { return false }

    if let number = entitlement as? NSNumber { return number.boolValue }
    if let bool = entitlement as? Bool { return bool }
    return false
}

private let AE_CS_DEBUGGED: Int32 = 0x10000000

@_silgen_name("csops")
private func aetherps4_csops(pid: Int32, ops: Int32, useraddr: UnsafeMutableRawPointer?, usersize: Int32) -> Int32

func checkDebugged() -> Bool {
    if checkAppEntitlement("dynamic-codesigning") { return true }
    var flags: Int32 = 0
    return aetherps4_csops(pid: getpid(), ops: 0, useraddr: &flags, usersize: Int32(MemoryLayout.size(ofValue: flags))) == 0
        && (flags & AE_CS_DEBUGGED) != 0
}

enum JITEnabler {
    static func requestStikDebugJIT() {
        // '+', '/' and '=' are legal in a query but get mangled by form-style decoding.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+/=&")
        guard let scriptData = script.addingPercentEncoding(withAllowedCharacters: allowed) else {
            aelog("JITEnabler: failed to percent-encode script")
            return
        }

        let target: String
        guard let bundleId = Bundle.main.bundleIdentifier else {
            aelog("JITEnabler: no bundle identifier, cannot request JIT")
            return
        }
        target = "bundle-id=\(bundleId)"

        // StikDebug base64-decodes script-data and runs it verbatim against this app.
        let urlScheme = "stikjit://enable-jit?\(target)&script-data=\(scriptData)"
        guard let url = URL(string: urlScheme) else {
            aelog("JITEnabler: failed to construct URL")
            return
        }
        aelog("JITEnabler: opening StikDebug with JIT26 script (\(scriptSource.count) chars, target=\(target))")
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    fileprivate static var script: String { Data(scriptSource.utf8).base64EncodedString() }

    // Services the two BreakpointJIT commands this app issues (brk #0xf00d):
    //   x16 = 1  prepare region. x0 == 0 asks the debugger to allocate a fresh RX region of
    //            x1 bytes first (`_M`), which is the only form AetherPS4 uses -- the previous
    //            script skipped that step and so handed every request back as a null pointer.
    //   x16 = 0  detach. AetherPS4 claims its whole JIT pool once at launch and then detaches
    //            (shadps4_jit_prewarm), so iOS suspending StikDebug in the background can no
    //            longer freeze the game on the next signal.
    // Any other stop is passed straight back to the app with its original signal.
    private static let scriptSource = #"""
function leHexToBigInt(hex) {
    let num = 0n;
    for (let i = hex.length - 2; i >= 0; i -= 2) {
        num = (num << 8n) | BigInt(parseInt(hex.substr(i, 2), 16));
    }
    return num;
}

function bigIntToLeHex(num) {
    let out = '';
    for (let i = 0; i < 8; i++) {
        out += Number(num & 0xFFn).toString(16).padStart(2, '0');
        num >>= 8n;
    }
    return out;
}

function reg(response, index) {
    const m = new RegExp(`(?:^|;)${index}:([0-9a-f]{16});`).exec(response);
    return m ? leHexToBigInt(m[1]) : null;
}

const pid = get_pid();
log(`attach = ${send_command(`vAttach;${pid.toString(16)}`)}`);

let detached = false;
while (!detached) {
    try {
        handleStop(send_command('c'));
    } catch (err) {
        log(`AetherPS4 JIT script error: ${err && err.message}`);
    }
}

function handleStop(response) {
    const tidMatch = /T[0-9a-f]+thread:([0-9a-f]+);/.exec(response);
    const tid = tidMatch ? tidMatch[1] : null;
    const pc = reg(response, '20');
    const x16 = reg(response, '10');
    if (!tid || pc === null || x16 === null) {
        log(`unparsed stop: ${response}`);
        if (/^[WX]/.test(response)) {
            detached = true; // process exited
        }
        return;
    }

    const insn = parseInt(send_command(`m${pc.toString(16)},4`).match(/../g).reverse().join(''), 16);
    const isBrk = ((insn & 0xFFE0001F) >>> 0) === 0xD4200000;
    if (!isBrk || ((insn >>> 5) & 0xFFFF) !== 0xf00d) {
        const sig = /^T([0-9a-f]{2})/.exec(response);
        if (sig) {
            send_command(`vCont;S${sig[1]}:${tid}`);
        }
        return;
    }

    send_command(`P20=${bigIntToLeHex(pc + 4n)};thread:${tid};`);

    if (x16 === 0n) {
        log('detaching');
        send_command('D');
        detached = true;
        return;
    }
    if (x16 !== 1n) {
        log(`unknown JIT command ${x16}`);
        return;
    }

    let addr = reg(response, '00');
    const size = reg(response, '01');
    if (addr === null || size === null || size === 0n) {
        send_command(`P0=${bigIntToLeHex(0n)};thread:${tid};`);
        return;
    }
    if (addr === 0n) {
        const allocated = send_command(`_M${size.toString(16)},rx`);
        if (!allocated || !/^[0-9a-f]+$/.test(allocated)) {
            log(`RX allocation of ${size} bytes failed: ${allocated}`);
            send_command(`P0=${bigIntToLeHex(0n)};thread:${tid};`);
            return;
        }
        addr = BigInt(`0x${allocated}`);
    }
    log(`prepare 0x${addr.toString(16)} (${size} bytes) = ${prepare_memory_region(addr, size)}`);
    send_command(`P0=${bigIntToLeHex(addr)};thread:${tid};`);
}
"""#
}

enum DeviceCpu {
    case mseries
    case aseries
}

struct ChipInfo {
    let series: DeviceCpu
    let number: Int
}

private extension FileManager {
    func filePath(atPath path: String, withLength length: Int) -> String? {
        guard let file = try? contentsOfDirectory(atPath: path).filter({ $0.count == length }).first else { return nil }
        return "\(path)/\(file)"
    }
}

extension ProcessInfo {
    var hasTXMClassic: Bool {
        ProcessInfo.processInfo.isiOSAppOnMac ? false :
        { if let boot = FileManager.default.filePath(atPath: "/System/Volumes/Preboot", withLength: 36), let file = FileManager.default.filePath(atPath: "\(boot)/boot", withLength: 96) { return access("\(file)/usr/standalone/firmware/FUD/Ap,TrustedExecutionMonitor.img4", F_OK) == 0 } else { return (FileManager.default.filePath(atPath: "/private/preboot", withLength: 96).map { access("\($0)/usr/standalone/firmware/FUD/Ap,TrustedExecutionMonitor.img4", F_OK) == 0 }) ?? false } }()
    }

    var hasTXM: Bool {
        if #available(iOS 27, *) {
            let lastNonTXM = 12 // A12
            let chipInfo = parseChipInfo()

            if let info = chipInfo, info.series == .aseries {
                return info.number > lastNonTXM
            }

            return true
        }

        if #available(iOS 26.6, *), !hasTXMClassic {
            let firstTXM = 15 // A15
            let iPadTXM = 2 // M2
            let chipInfo = parseChipInfo()

            if let info = chipInfo {
                if info.series == .mseries {
                    return info.number >= iPadTXM
                } else {
                    return info.number >= firstTXM
                }
            }

            return false
        }

        return hasTXMClassic
    }

    private func parseChipInfo() -> ChipInfo? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }

        let name = device.name.uppercased()

        if name.contains("APPLE M") {
            let numString = name.dropFirst("APPLE M".count).prefix(while: { $0.isNumber })
            if let number = Int(numString) {
                return ChipInfo(series: .mseries, number: number)
            }
        }

        if name.contains("APPLE A") {
            let numString = name.dropFirst("APPLE A".count).prefix(while: { $0.isNumber })
            if let number = Int(numString) {
                return ChipInfo(series: .aseries, number: number)
            }
        }

        return nil
    }
}

/// Claims the JIT pool from StikDebug and detaches it (see shadps4_jit_prewarm). Only call once
/// checkDebugged() is true. Pool size and detaching can be overridden with the
/// "jitPoolSizeMB" and "jitKeepDebuggerAttached" user defaults.
@discardableResult
func prewarmJIT() -> Bool {
    let defaults = UserDefaults.standard
    let poolMB = defaults.integer(forKey: "jitPoolSizeMB")
    let keepAttached = defaults.bool(forKey: "jitKeepDebuggerAttached")
    let ok = shadps4_jit_prewarm(UInt32(poolMB > 0 ? poolMB : 128), keepAttached ? 0 : 1) != 0
    aelog("JIT pool prewarm \(ok ? "succeeded" : "failed") (keepAttached=\(keepAttached))")
    return ok
}

func configureJITEnvVars() {
    setenv("HAS_TXM", ProcessInfo.processInfo.hasTXM ? "1" : "0", 1)
    setenv("DUAL_MAPPED_JIT", "1", 1)
}
