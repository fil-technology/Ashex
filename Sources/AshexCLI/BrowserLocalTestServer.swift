import AshexCore
import Darwin
import Foundation

final class BrowserLocalTestServer: @unchecked Sendable {
    let baseURL: URL

    private let socketFD: Int32
    private var task: Task<Void, Never>?

    private init(socketFD: Int32, port: Int) {
        self.socketFD = socketFD
        self.baseURL = URL(string: "http://127.0.0.1:\(port)")!
    }

    static func start() throws -> BrowserLocalTestServer {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw BrowserBackendError.startupFailed("Unable to create local browser test server socket.")
        }

        var reuse: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                bind(socketFD, pointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(socketFD)
            throw BrowserBackendError.startupFailed("Unable to bind local browser test server socket.")
        }

        guard listen(socketFD, 16) == 0 else {
            close(socketFD)
            throw BrowserBackendError.startupFailed("Unable to listen on local browser test server socket.")
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                getsockname(socketFD, pointer, &length)
            }
        }
        guard nameResult == 0 else {
            close(socketFD)
            throw BrowserBackendError.startupFailed("Unable to inspect local browser test server port.")
        }

        let server = BrowserLocalTestServer(socketFD: socketFD, port: Int(UInt16(bigEndian: boundAddress.sin_port)))
        server.startAccepting()
        return server
    }

    func stop() {
        task?.cancel()
        shutdown(socketFD, SHUT_RDWR)
        close(socketFD)
    }

    private func startAccepting() {
        task = Task.detached { [socketFD] in
            while !Task.isCancelled {
                var clientAddress = sockaddr()
                var length = socklen_t(MemoryLayout<sockaddr>.size)
                let clientFD = accept(socketFD, &clientAddress, &length)
                guard clientFD >= 0 else {
                    if Task.isCancelled { break }
                    continue
                }
                BrowserLocalTestServer.handle(clientFD: clientFD)
            }
        }
    }

    private static func handle(clientFD: Int32) {
        defer { close(clientFD) }
        var noSigPipe: Int32 = 1
        setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        let count = read(clientFD, &buffer, buffer.count)
        let request: String
        if count > 0 {
            request = String(decoding: buffer.prefix(Int(count)), as: UTF8.self)
        } else {
            request = ""
        }

        let response = response(for: requestPath(from: request))
        response.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            _ = write(clientFD, baseAddress, response.count)
        }
    }

    private static func requestPath(from request: String) -> String {
        let firstLine = request.split(separator: "\r\n", maxSplits: 1).first ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return "/" }
        return String(parts[1])
    }

    private static func response(for path: String) -> Data {
        let body: String
        switch path {
        case "/", "/index.html":
            body = """
            <!doctype html>
            <html>
            <head><title>ASHEX Browser Local Test</title></head>
            <body>
              <main>
                <h1>ASHEX Browser Local Test</h1>
                <p id="static">Static content is visible.</p>
                <p id="dynamic"></p>
                <button id="button">Button</button>
                <script>
                  document.getElementById('dynamic').textContent = 'JavaScript content is visible.';
                </script>
              </main>
            </body>
            </html>
            """
        case "/large.html":
            body = """
            <!doctype html>
            <html><head><title>ASHEX Large Page</title></head><body>
            <h1>Large content</h1>
            \(Array(repeating: "<p>Repeated local fixture content.</p>", count: 200).joined(separator: "\n"))
            </body></html>
            """
        case "/delayed.html":
            body = """
            <!doctype html>
            <html>
            <head><title>ASHEX Delayed Page</title></head>
            <body>
              <h1>Delayed content</h1>
              <p id="delayed">Waiting</p>
              <script>
                setTimeout(() => { document.getElementById('delayed').textContent = 'Delayed JavaScript content is visible.'; }, 100);
              </script>
            </body>
            </html>
            """
        default:
            return httpResponse(status: "404 Not Found", body: "not found", contentType: "text/plain")
        }
        return httpResponse(status: "200 OK", body: body, contentType: "text/html; charset=utf-8")
    }

    private static func httpResponse(status: String, body: String, contentType: String) -> Data {
        let bodyData = Data(body.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        var data = Data(header.utf8)
        data.append(bodyData)
        return data
    }
}
