import CTractandaPlatform
import Foundation
import NIOPosix
import TractandaClient
import TractandaHTTPSIdentity

@testable import TractandaCore
@testable import TractandaServer

final class PublicHTTPClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()
    func now() -> Date { lock.withLock { value } }
    func advance(_ seconds: Double) { lock.withLock { value += seconds } }
}
final class PublicHTTPAccounts: AccountDirectory, @unchecked Sendable {
    let uid = tractanda_uid()
    func user(forUID uid: UInt32) throws -> AccountIdentity {
        guard uid == self.uid else {
            throw TractandaError("unresolvedPrincipal", "Unknown fixture identity.")
        }
        return .init(uid: uid, name: "fixture", primaryGroupName: "staff", groupIDs: [20, 80])
    }
    func user(named name: String) throws -> AccountIdentity {
        guard name == "fixture" else { throw TractandaError("unresolvedPrincipal", "Unknown fixture name.") }
        return try user(forUID: uid)
    }
    func groupID(named name: String) throws -> UInt32 {
        guard let id: UInt32 = ["staff": 20, "admin": 80, "operators": 80, "wheel": 0][name] else {
            throw TractandaError("unresolvedPrincipal", "Unknown fixture group.")
        }
        return id
    }
}
struct PublicHTTPPassword: PasswordAuthenticating {
    let uid: UInt32
    func authenticate(username: String, password: String) throws -> UInt32 {
        guard username == "fixture", password == "private-fixture-password" else {
            throw TractandaError("invalidCredentials", "Rejected.")
        }
        return uid
    }
}
private actor PublicHTTPCallbacks: JMAPCallbackTransport {
    func validate(url: String) throws { _ = try JMAPCallbackEndpoint(url) }
    func post(url: String, body: Data, encrypted: Bool, ttlSeconds: Int, expiresAt: Date)
        -> JMAPCallbackResponse
    { .init(status: 201) }
    func close() {}
}
private actor PublicHTTPApplicationSlot {
    var application: PublicJMAPApplication?
    func set(_ app: PublicJMAPApplication) { application = app }
    func begin(_ head: PublicJMAPRequestHead) async throws -> any PublicJMAPRequestSink {
        guard let application else { throw TractandaError("serviceBusy", "Fixture is not ready.") }
        return try await application.begin(head)
    }
}
struct PublicHTTPWireRequest: Encodable, Sendable {
    var method: String
    var path: String
    var headers: [[String]] = []
    var body = Data()
    var fragmentBytes = 0
    var chunked = false
    var readEvents = 0
    var slowReadMilliseconds = 0
}
struct PublicHTTPWireResponse: Decodable, Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data?
    let size: Int
    let sha256: String
    let incomplete: Bool?
    let error: String?
    func json() throws -> [String: Any] {
        guard let body, let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw TractandaError("fixtureFailure", "Expected JSON response.")
        }
        return object
    }
}
private struct PublicHTTPClientInput: Encodable, Sendable {
    let port: Int
    let ca: String
    let serverName: String
    let requests: [PublicHTTPWireRequest]
    let pipeline: Bool
}

final class PublicHTTPFixture: @unchecked Sendable {
    let root: URL
    let coordinator: ServiceCoordinator
    let sessions: SessionAuthority
    let hub: JMAPEventHub
    let application: PublicJMAPApplication
    let listener: DaemonListener
    let group: MultiThreadedEventLoopGroup
    let accounts: PublicHTTPAccounts
    let clock: PublicHTTPClock
    let port: Int
    let baseURL: String
    let script: URL
    let ca: URL
    let key: URL
    let chain: URL
    let identity: HTTPSIdentityContextStore

    private init(
        root: URL, coordinator: ServiceCoordinator, sessions: SessionAuthority, hub: JMAPEventHub,
        application: PublicJMAPApplication, listener: DaemonListener, group: MultiThreadedEventLoopGroup,
        accounts: PublicHTTPAccounts, clock: PublicHTTPClock, script: URL, ca: URL, key: URL, chain: URL,
        identity: HTTPSIdentityContextStore
    ) {
        self.root = root
        self.coordinator = coordinator
        self.sessions = sessions
        self.hub = hub
        self.application = application
        self.listener = listener
        self.group = group
        self.accounts = accounts
        self.clock = clock
        port = listener.port!
        baseURL = "https://localhost:\(port)"
        self.script = script
        self.ca = ca
        self.key = key
        self.chain = chain
        self.identity = identity
    }
    static func open(maximumUpload: Int64 = 2 * 1024 * 1024) async throws -> PublicHTTPFixture {
        try PeerFixtureCapacity.requireFree()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "public-http-" + Identifier.make())
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        // Estimated PKI/store/control files + two retained2MiB originals remain below the128MiB fixture cap.
        guard 12 * 1024 * 1024 < PeerFixtureCapacity.fixtureCapBytes else {
            throw TractandaError("resourceLimit", "HTTP fixture cap insufficient.")
        }
        let accounts = PublicHTTPAccounts()
        let clock = PublicHTTPClock()
        let storeRoot = root.appendingPathComponent("store")
        let key = root.appendingPathComponent("server.key")
        let chain = root.appendingPathComponent("chain.pem")
        let ca = root.appendingPathComponent("root.pem")
        var coordinator: ServiceCoordinator?
        var group: MultiThreadedEventLoopGroup?
        var listener: DaemonListener?
        var hub: JMAPEventHub?
        do {
            try PeerFixtureCapacity.requireFree(at: root)
            try await Task.detached {
                try command(
                    "/usr/bin/openssl",
                    [
                        "req", "-sha256", "-x509", "-newkey", "ec", "-pkeyopt",
                        "ec_paramgen_curve:prime256v1", "-pkeyopt", "ec_param_enc:named_curve", "-nodes",
                        "-keyout", "root.key", "-out", "root.pem", "-subj", "/CN=HTTP Fixture Root", "-days",
                        "1", "-addext", "basicConstraints=critical,CA:TRUE", "-addext",
                        "keyUsage=critical,keyCertSign,cRLSign", "-addext", "subjectKeyIdentifier=hash",
                    ], directory: root)
                try command(
                    "/usr/bin/openssl",
                    [
                        "req", "-sha256", "-new", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1",
                        "-pkeyopt", "ec_param_enc:named_curve", "-nodes", "-keyout", "server.key", "-out",
                        "server.csr", "-subj", "/CN=localhost",
                    ], directory: root)
                try Data(
                    "subjectAltName=DNS:localhost\nkeyUsage=digitalSignature\nextendedKeyUsage=serverAuth\nbasicConstraints=critical,CA:FALSE\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid:always,issuer\n"
                        .utf8
                ).write(to: root.appendingPathComponent("extensions.txt"))
                try command(
                    "/usr/bin/openssl",
                    [
                        "x509", "-sha256", "-req", "-in", "server.csr", "-CA", "root.pem", "-CAkey",
                        "root.key", "-CAcreateserial", "-out", "server.pem", "-days", "1", "-extfile",
                        "extensions.txt",
                    ], directory: root)
                try (Data(contentsOf: root.appendingPathComponent("server.pem")) + Data(contentsOf: ca))
                    .write(to: chain)
                _ = try ItemStore(
                    personalRoot: storeRoot,
                    opening: .fresh(
                        .object([
                            "profile": .text(AccessConfiguration.profile), "users": .list([.text("fixture")]),
                        ])),
                    accounts: accounts,
                    attachmentUploadPolicy: .init(
                        maximumStagedBytes: 16 * 1024 * 1024,
                        minimumFreeBytes: Int64(PeerFixtureCapacity.reserveBytes)))
            }.value
            let owner = try await ServiceCoordinator(
                opening: storeRoot,
                attachmentUploadPolicy: .init(
                    maximumStagedBytes: 16 * 1024 * 1024,
                    minimumFreeBytes: Int64(PeerFixtureCapacity.reserveBytes)),
                makeAccountDirectory: { accounts })
            coordinator = owner
            let sessions = SessionAuthority(
                authenticator: PublicHTTPPassword(uid: accounts.uid),
                identity: { try await owner.accountIdentity(forUID: $0) },
                handle: { try await owner.handle($0, forUID: $1) }, now: { clock.now() })
            let blobs = JMAPBlobService(
                coordinator: owner,
                limits: try .init(
                    maxSizeUpload: maximumUpload, maximumStagedBytesPerUser: 8 * 1024 * 1024,
                    minimumFreeBytes: Int64(PeerFixtureCapacity.reserveBytes)))
            let events = try JMAPEventHub(
                stateProvider: { try await owner.jmapVisibleStates(authentication: $0) },
                callbackTransport: PublicHTTPCallbacks(),
                credentialResolver: { [weak sessions] id in
                    try await sessions?.authentication(credentialID: id)
                })
            hub = events
            let identity = HTTPSIdentityContextStore()
            try identity.reload {
                try HTTPSIdentityLoader().loadPEM(
                    certificateChainFile: chain.path, privateKeyFile: key.path,
                    configuration: .init(hostnames: ["localhost"]))
            }
            let loops = MultiThreadedEventLoopGroup(numberOfThreads: 2)
            group = loops
            let slot = PublicHTTPApplicationSlot()
            // Only this fixture binds ephemeralport0. No Session is served until the actual port is known.
            let configuration = PublicJMAPConfiguration(
                baseURL: "https://localhost",
                transport: .builtinTLS(
                    host: "127.0.0.1", port: 0,
                    identity: .pem(certificateChainFile: chain.path, privateKeyFile: key.path)))
            let server = try await DaemonListeners.publicJMAP(
                group: loops, configuration: configuration, identity: identity, managed: false,
                begin: { try await slot.begin($0) })
            listener = server
            let app = try PublicJMAPApplication(
                coordinator: owner, sessions: sessions, blobs: blobs, notifications: events,
                baseURL: "https://localhost:\(server.port!)")
            await slot.set(app)
            let script = root.appendingPathComponent("client.py")
            try Data(clientScript.utf8).write(to: script)
            return PublicHTTPFixture(
                root: root, coordinator: owner, sessions: sessions, hub: events, application: app,
                listener: server, group: loops, accounts: accounts, clock: clock, script: script, ca: ca,
                key: key, chain: chain, identity: identity)
        } catch {
            try? await listener?.close()
            await hub?.close()
            await coordinator?.close()
            try? await group?.shutdownGracefully()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }
    func close() async {
        try? await listener.close()
        await application.close()
        await sessions.close()
        await coordinator.close()
        try? await group.shutdownGracefully()
        try? FileManager.default.removeItem(at: root)
    }
    func call(_ requests: [PublicHTTPWireRequest], pipeline: Bool = false, serverName: String = "localhost")
        async throws -> [PublicHTTPWireResponse]
    {
        let input = try JSON.encode(
            PublicHTTPClientInput(
                port: port, ca: ca.path, serverName: serverName, requests: requests, pipeline: pipeline))
        let script = script
        let root = root
        let result = try await Task.detached {
            try Self.command("/usr/bin/env", ["python3", script.path], directory: root, input: input)
        }.value
        return try JSON.decode([PublicHTTPWireResponse].self, result)
    }
    func login() async throws -> String {
        let result = try await call([
            .init(
                method: "POST", path: "/auth/login", headers: [["Content-Type", "application/json"]],
                body: JSON.encode(["username": "fixture", "password": "private-fixture-password"]))
        ])
        guard result.first?.status == 200, let token = try result.first?.json()["token"] as? String else {
            let status = result.first?.status ?? -1
            let transport = result.first?.error ?? "none"
            let problem = (try? result.first?.json()["type"] as? String) ?? "none"
            throw TractandaError(
                "fixtureFailure",
                "HTTPS login failed: status=\(status), transport=\(transport), problem=\(problem).")
        }
        return token
    }
    func session(_ token: String) async throws -> PublicHTTPWireResponse {
        try await call([
            .init(method: "GET", path: "/jmap/session", headers: [["Authorization", "Bearer " + token]])
        ])[0]
    }
    func api(_ token: String, calls: [[Any]], using: [String] = TractandaJMAP.using) async throws
        -> PublicHTTPWireResponse
    {
        try await call([
            .init(
                method: "POST", path: "/jmap/api",
                headers: [["Authorization", "Bearer " + token], ["Content-Type", "application/json"]],
                body: JSONSerialization.data(withJSONObject: ["using": using, "methodCalls": calls]))
        ])[0]
    }
    @discardableResult static func command(
        _ executable: String, _ args: [String], directory: URL, input: Data = Data()
    ) throws -> Data {
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.currentDirectoryURL = directory
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        try stdin.fileHandleForWriting.write(contentsOf: input)
        try stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let error = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0, output.count <= 1024 * 1024 else {
            throw TractandaError(
                "fixtureFailure",
                "Independent fixture command failed: " + String(decoding: error.prefix(1024), as: UTF8.self))
        }
        return output
    }
    /// Base64 is test-process control framing only. The independent SSL client sends raw binary HTTP bodies.
    private static let clientScript = #"""
        import sys,json,ssl,socket,base64,hashlib,time,os
        c=json.load(sys.stdin)
        context=ssl.create_default_context(cafile=c['ca'])
        results=[]
        def encode(r):
            body=base64.b64decode(r.get('body',''))
            headers=list(r.get('headers',[]))
            has=lambda n:any(k.lower()==n for k,v in headers)
            if not has('host'):headers.append(['Host','localhost:'+str(c['port'])])
            if not has('connection'):headers.append(['Connection','close'])
            if r.get('chunked') and not has('transfer-encoding'):headers.append(['Transfer-Encoding','chunked'])
            if not has('content-length') and not has('transfer-encoding'):headers.append(['Content-Length',str(len(body))])
            raw=(r['method']+' '+r['path']+' HTTP/1.1\r\n'+''.join(k+': '+v+'\r\n' for k,v in headers)+'\r\n').encode('ascii')
            if r.get('chunked'):
                raw+=b''.join(('%x\r\n'%len(body[i:i+8191])).encode()+body[i:i+8191]+b'\r\n' for i in range(0,len(body),8191))+b'0\r\n\r\n'
            else:raw+=body
            return raw
        def send(sock,raw,n):
            if n:
                for i in range(0,len(raw),n):sock.sendall(raw[i:i+n])
            else:sock.sendall(raw)
        def read_response(f,r):
            while True:
                line=f.readline(16385)
                if not line:raise EOFError('HTTP response ended before a status')
                status=int(line.split()[1]);headers={}
                while True:
                    line=f.readline(16385)
                    if line==b'\r\n':break
                    if not line or len(line)>16384:raise ValueError('invalid response headers')
                    k,v=line.decode('latin1').split(':',1);headers[k.lower()]=v.strip()
                if status!=100:break
            size=0;h=hashlib.sha256();small=bytearray();incomplete=False;events=0
            def append(chunk):
                nonlocal size,small,events
                size+=len(chunk)
                if size>16*1024*1024:raise ValueError('fixture response cap')
                h.update(chunk)
                if size<=131072:small.extend(chunk)
                else:small=bytearray()
                if r.get('slowReadMilliseconds'):time.sleep(r['slowReadMilliseconds']/1000)
            if headers.get('transfer-encoding','').lower()=='chunked':
                while True:
                    line=f.readline(128)
                    if not line:incomplete=True;break
                    n=int(line.split(b';')[0].strip(),16)
                    if not n:
                        for _ in range(64):
                            trailer=f.readline(16385)
                            if trailer==b'\r\n':break
                            if not trailer:raise EOFError('response trailers truncated')
                        else:raise ValueError('response trailers exceed bound')
                        break
                    chunk=f.read(n)
                    if len(chunk)!=n:append(chunk);incomplete=True;break
                    append(chunk)
                    if f.read(2)!=b'\r\n':incomplete=True;break
                    if r.get('readEvents') and bytes(small).count(b'\n\n')>=r['readEvents']:break
            elif 'content-length' in headers:
                remaining=int(headers['content-length'])
                while remaining:
                    chunk=f.read(min(65536,remaining))
                    if not chunk:incomplete=True;break
                    append(chunk);remaining-=len(chunk)
            else:
                while True:
                    chunk=f.read(65536)
                    if not chunk:break
                    append(chunk)
            return dict(status=status,headers=headers,body=base64.b64encode(small).decode() if size<=131072 else None,size=size,sha256=h.hexdigest(),incomplete=incomplete)
        try:
            with socket.create_connection(('127.0.0.1',c['port']),timeout=float(os.getenv('TRACTANDA_JMAP_HTTP_FIXTURE_SECONDS','900'))) as tcp:
                with context.wrap_socket(tcp,server_hostname=c.get('serverName','localhost')) as sock:
                    f=sock.makefile('rb')
                    if c.get('pipeline'):
                        send(sock,b''.join(encode(r) for r in c['requests']),0)
                        for r in c['requests']:results.append(read_response(f,r))
                    else:
                        for r in c['requests']:
                            send(sock,encode(r),r.get('fragmentBytes',0));results.append(read_response(f,r))
        except Exception as e:
            results.append(dict(status=0,headers={},body=None,size=0,sha256='',error=str(e)[:1024]))
        print(json.dumps(results,separators=(',',':')))
        """#
}
