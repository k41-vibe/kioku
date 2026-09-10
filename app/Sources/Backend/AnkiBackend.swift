import Foundation
import AnkiRustLib
import SwiftProtobuf

/// Error surfaced by the Rust backend (decoded `anki.backend.BackendError`)
/// or by the FFI layer itself.
struct BackendError: Error, LocalizedError, CustomStringConvertible {
    enum Kind: Equatable {
        case backend(Anki_Backend_BackendError.Kind)
        case ffi
        case encoding
    }

    let kind: Kind
    let message: String
    let context: String

    init(kind: Kind, message: String, context: String = "") {
        self.kind = kind
        self.message = message
        self.context = context
    }

    init(errorBytes: Data) {
        if let err = try? Anki_Backend_BackendError(serializedBytes: errorBytes) {
            self.kind = .backend(err.kind)
            self.message = err.message.isEmpty ? "backend error (\(err.kind))" : err.message
            self.context = err.context
        } else {
            self.kind = .backend(.invalidInput)
            self.message = "backend error (undecodable, \(errorBytes.count) bytes)"
            self.context = ""
        }
    }

    var isNotFound: Bool { kind == .backend(.notFoundError) }
    var isUndoEmpty: Bool { kind == .backend(.undoEmpty) }
    var errorDescription: String? { message }
    var description: String { context.isEmpty ? message : "\(message) [\(context)]" }
}

/// Thin, thread-safe wrapper over the four C functions exported by the Rust
/// bridge. All calls are serialized with a lock; callers should stay off the
/// main thread for anything heavier than a counts query.
final class AnkiBackend: @unchecked Sendable {
    private let handle: Int64
    private let lock = NSLock()

    init(preferredLangs: [String] = ["ja", "en"]) throws {
        var initMsg = Anki_Backend_BackendInit()
        initMsg.preferredLangs = preferredLangs
        initMsg.server = false
        let bytes = try initMsg.serializedData()

        var ptr: Int64 = 0
        let status = bytes.withUnsafeBytes { buf -> Int32 in
            anki_open_backend(buf.baseAddress?.assumingMemoryBound(to: UInt8.self), buf.count, &ptr)
        }
        guard status == 0, ptr != 0 else {
            throw BackendError(kind: .ffi, message: "Anki backend の初期化に失敗しました (status \(status))")
        }
        handle = ptr
    }

    deinit {
        anki_close_backend(handle)
    }

    static var bridgeVersion: String {
        String(cString: anki_bridge_version())
    }

    // MARK: - Raw call

    func call(service: UInt32, method: UInt32, input: Data = Data()) throws -> Data {
        lock.lock()
        defer { lock.unlock() }

        var outPtr: UnsafeMutablePointer<UInt8>? = nil
        var outLen: Int = 0
        let status: Int32
        if input.isEmpty {
            status = anki_run_method(handle, service, method, nil, 0, &outPtr, &outLen)
        } else {
            status = input.withUnsafeBytes { buf -> Int32 in
                anki_run_method(
                    handle, service, method,
                    buf.baseAddress?.assumingMemoryBound(to: UInt8.self), buf.count,
                    &outPtr, &outLen
                )
            }
        }
        defer {
            if let outPtr { anki_free_response(outPtr, outLen) }
        }
        let response: Data
        if let outPtr, outLen > 0 {
            response = Data(bytes: outPtr, count: outLen)
        } else {
            response = Data()
        }
        switch status {
        case 0: return response
        case 1: throw BackendError(errorBytes: response)
        default: throw BackendError(kind: .ffi, message: "FFI error (status \(status)) service=\(service) method=\(method)")
        }
    }

    // MARK: - Typed helpers

    func invoke<Req: SwiftProtobuf.Message, Resp: SwiftProtobuf.Message>(
        _ service: UInt32, _ method: UInt32, _ request: Req
    ) throws -> Resp {
        let input: Data
        do { input = try request.serializedData() } catch {
            throw BackendError(kind: .encoding, message: "encode failed: \(error)")
        }
        let out = try call(service: service, method: method, input: input)
        do { return try Resp(serializedBytes: out) } catch {
            throw BackendError(kind: .encoding, message: "decode failed: \(error)")
        }
    }

    func invoke<Resp: SwiftProtobuf.Message>(_ service: UInt32, _ method: UInt32) throws -> Resp {
        let out = try call(service: service, method: method)
        do { return try Resp(serializedBytes: out) } catch {
            throw BackendError(kind: .encoding, message: "decode failed: \(error)")
        }
    }

    func invokeVoid<Req: SwiftProtobuf.Message>(_ service: UInt32, _ method: UInt32, _ request: Req) throws {
        let input: Data
        do { input = try request.serializedData() } catch {
            throw BackendError(kind: .encoding, message: "encode failed: \(error)")
        }
        _ = try call(service: service, method: method, input: input)
    }

    func invokeVoid(_ service: UInt32, _ method: UInt32) throws {
        _ = try call(service: service, method: method)
    }
}
