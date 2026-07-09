import Darwin
import Foundation

enum CMUXSocketError: LocalizedError {
    case unavailable(String)
    case rejected(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unavailable(let detail):
            return "CMUX is unavailable: \(detail)"
        case .rejected(let detail):
            return "CMUX rejected the request: \(detail)"
        case .invalidResponse:
            return "CMUX returned an invalid response."
        }
    }
}

final class CMUXSocketClient {
    private let path: String
    private var socketDescriptor: Int32 = -1

    init(path: String) {
        self.path = path
    }

    deinit {
        close()
    }

    func connect() throws {
        guard socketDescriptor == -1 else {
            return
        }
        var info = stat()
        let status = path.withCString { Darwin.lstat($0, &info) }
        guard status == 0 else {
            throw CMUXSocketError.unavailable("socket not found")
        }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK), info.st_uid == getuid() else {
            throw CMUXSocketError.unavailable("unsafe socket path")
        }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor != -1 else {
            throw CMUXSocketError.unavailable(lastSystemError())
        }
        socketDescriptor = descriptor
        configure(descriptor)
        try connect(descriptor)
    }

    private func configure(_ descriptor: Int32) {
        var noSigPipe: Int32 = 1
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout.size(ofValue: noSigPipe))
        )
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout.size(ofValue: timeout))
        )
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &timeout,
            socklen_t(MemoryLayout.size(ofValue: timeout))
        )
    }

    private func connect(_ descriptor: Int32) throws {
        var address = sockaddr_un()
        let pathBytes = Array(path.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            close()
            throw CMUXSocketError.unavailable("socket path is too long")
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { source in
                destination.copyBytes(from: source)
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(
                    descriptor,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard result == 0 else {
            let detail = lastSystemError()
            close()
            throw CMUXSocketError.unavailable(detail)
        }
    }

    func authenticate(password: String?) throws {
        guard let password, !password.isEmpty else {
            return
        }
        let response = try sendLine("auth \(password)")
        guard Self.isSuccessfulAuthResponse(response) else {
            throw CMUXSocketError.rejected(response)
        }
    }

    static func isSuccessfulAuthResponse(_ response: String) -> Bool {
        response.hasPrefix("OK")
    }

    @discardableResult
    func request(method: String, params: [String: Any] = [:]) throws -> [String: Any] {
        let request: [String: Any] = [
            "id": UUID().uuidString,
            "method": method,
            "params": params
        ]
        guard JSONSerialization.isValidJSONObject(request) else {
            throw CMUXSocketError.invalidResponse
        }
        let data = try JSONSerialization.data(withJSONObject: request)
        guard let line = String(data: data, encoding: .utf8) else {
            throw CMUXSocketError.invalidResponse
        }
        return try decodeResponse(try sendLine(line))
    }

    private func decodeResponse(_ rawResponse: String) throws -> [String: Any] {
        if rawResponse.hasPrefix("ERROR:") {
            throw CMUXSocketError.rejected(rawResponse)
        }
        guard let data = rawResponse.data(using: .utf8),
              let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CMUXSocketError.invalidResponse
        }
        if response["ok"] as? Bool == true {
            return response["result"] as? [String: Any] ?? [:]
        }
        if let error = response["error"] as? [String: Any] {
            let message = error["message"] as? String ?? error["code"] as? String ?? "Unknown error"
            throw CMUXSocketError.rejected(message)
        }
        throw CMUXSocketError.invalidResponse
    }

    func close() {
        if socketDescriptor != -1 {
            Darwin.close(socketDescriptor)
            socketDescriptor = -1
        }
    }

    private func sendLine(_ line: String) throws -> String {
        guard socketDescriptor != -1 else {
            throw CMUXSocketError.unavailable("not connected")
        }
        try write(Data((line + "\n").utf8))
        return try readLine()
    }

    private func write(_ payload: Data) throws {
        try payload.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return
            }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    socketDescriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                guard count > 0 else {
                    throw CMUXSocketError.unavailable(lastSystemError())
                }
                offset += count
            }
        }
    }

    private func readLine() throws -> String {
        var response = Data()
        while !response.contains(0x0A) {
            var buffer = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(socketDescriptor, &buffer, buffer.count)
            guard count > 0 else {
                throw CMUXSocketError.unavailable(
                    count == 0 ? "socket closed before replying" : lastSystemError()
                )
            }
            response.append(buffer, count: count)
        }
        guard let newline = response.firstIndex(of: 0x0A),
              let text = String(data: response[..<newline], encoding: .utf8) else {
            throw CMUXSocketError.invalidResponse
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func lastSystemError() -> String {
        String(cString: strerror(errno))
    }
}
