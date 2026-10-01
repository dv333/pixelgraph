import ArgumentParser
import Foundation
@preconcurrency import Network

/// `pixelgraph mcp`: PixelGraph as tools for Claude, ChatGPT and Codex,
/// over the Model Context Protocol. Over stdio for apps on this Mac (Claude
/// Desktop, Claude Code, Codex); over HTTP behind a secret URL for ChatGPT
/// on the web through a tunnel, where nothing can be deleted.
struct MCPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp", abstract: "Run PixelGraph as an MCP server for Claude, ChatGPT or Codex.")

    @Flag(help: "Serve over HTTP on this Mac, for a tunnel to ChatGPT on the web, instead of stdio.")
    var http = false

    @Option(help: "Port for --http.")
    var port: UInt16 = 8765

    @Flag(help: "Refuse to delete; moves only go to PGDuplicates. Always on with --http.")
    var noTrash = false

    func run() async throws {
        let server = MCPServer(allowTrash: !noTrash && !http)
        if http { try await server.serveHTTP(port: port) } else { await server.serveStdio() }
    }
}

typealias JSON = [String: Any]

final class MCPServer: @unchecked Sendable {
    private let allowTrash: Bool

    init(allowTrash: Bool) {
        self.allowTrash = allowTrash
    }

    static let instructions = """
        PixelGraph finds near-identical photos on this Mac (Apple Photos, folders, drives), \
        picks the best of each group and moves the rest to the PGDuplicates album or folder. \
        Typical flow: list_sources → scan → list_groups → show_photos on groups worth a look → \
        set_pick where you'd choose differently → move with dry_run true, tell the person what \
        will happen, then move with dry_run false. Photos in a group are lettered A, B, C. \
        Keep photos that are genuinely different moments. Never delete unless the person asked \
        for it in so many words. Every move can be undone with undo. The nightly run works in \
        the "nightly" workspace and leaves close calls there for you.
        """

    // MARK: - Transports

    /// One JSON-RPC message per line on stdin and stdout.
    func serveStdio() async {
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let reply = await handle(Data(line.utf8)) {
                FileHandle.standardOutput.write(reply + Data("\n".utf8))
            }
        }
    }

    /// Streamable HTTP on 127.0.0.1 only, answering at /mcp/<secret>; plain
    /// JSON replies, no event stream. Put a tunnel in front for ChatGPT.
    func serveHTTP(port: UInt16) async throws {
        let token = Self.token()
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw ValidationError("Bad port \(port).") }
        let listener = try NWListener(using: parameters, on: nwPort)
        listener.newConnectionHandler = { [self] connection in
            connection.start(queue: .global())
            receive(connection, Data(), token: token)
        }
        listener.start(queue: .global())
        print("""
            PixelGraph MCP server on http://127.0.0.1:\(port)/mcp/\(token)

            For ChatGPT on the web, expose it with a tunnel, for example:
              cloudflared tunnel --url http://127.0.0.1:\(port)
            then add a connector in ChatGPT (Settings → Apps & Connectors → Developer mode) with
              https://<your-tunnel-host>/mcp/\(token)
            The long code in the path is the password: anyone with the full URL can reach your
            photos, so keep it private. Deleting is switched off here. ctrl-c to stop.
            """)
        while true { try await Task.sleep(for: .seconds(3600)) }
    }

    /// A random secret, made once and kept in PixelGraph's data folder.
    static func token() -> String {
        let file = Paths.root.appendingPathComponent("mcp-token")
        if let saved = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), saved.count >= 32 {
            return saved
        }
        let token = (0..<24).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        try? token.write(to: file, atomically: true, encoding: .utf8)
        chmod(file.path, 0o600)
        return token
    }

    private func receive(_ connection: NWConnection, _ buffer: Data, token: String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [self] data, _, complete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = HTTPRequest(buffer) {
                Task {
                    let response = await self.respond(to: request, token: token)
                    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                }
            } else if complete || error != nil || buffer.count > 8 << 20 {
                connection.cancel()
            } else {
                receive(connection, buffer, token: token)
            }
        }
    }

    private func respond(to request: HTTPRequest, token: String) async -> Data {
        let path = request.path.split(separator: "?").first.map(String.init) ?? request.path
        guard path == "/mcp/\(token)" else { return HTTPRequest.response(404, "Not found") }
        switch request.method {
        case "POST":
            guard let reply = await handle(request.body) else { return HTTPRequest.response(202, "") }
            return HTTPRequest.response(200, reply, type: "application/json")
        case "DELETE": return HTTPRequest.response(200, "")
        default: return HTTPRequest.response(405, "Use POST", extra: ["Allow": "POST"])
        }
    }

    // MARK: - JSON-RPC

    func handle(_ data: Data) async -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"] as JSON] as JSON)
        }
        if let batch = object as? [[String: Any]] {
            var replies: [[String: Any]] = []
            for message in batch { if let reply = await reply(message) { replies.append(reply) } }
            return replies.isEmpty ? nil : encode(replies)
        }
        guard let message = object as? [String: Any] else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32600, "message": "Invalid request"] as JSON] as JSON)
        }
        return await reply(message).flatMap(encode)
    }

    private func encode(_ object: Any) -> Data? { try? JSONSerialization.data(withJSONObject: object) }

    private func reply(_ message: [String: Any]) async -> [String: Any]? {
        // Notifications (no id) get no reply.
        guard let id = message["id"] else { return nil }
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]
        func result(_ value: Any) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": value] }
        switch method {
        case "initialize":
            return result([
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "pixelgraph", "version": "0.3.0"],
                "instructions": Self.instructions,
            ] as JSON)
        case "ping":
            return result([String: Any]())
        case "tools/list":
            return result(["tools": tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                return result(["content": try await call(name, arguments)])
            } catch {
                return result(["content": [["type": "text", "text": error.localizedDescription]], "isError": true] as JSON)
            }
        default:
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Unknown method \(method)"] as JSON]
        }
    }

    // MARK: - Tools

    private var tools: [[String: Any]] {
        let workspace: [String: Any] = ["type": "string", "enum": ["main", "nightly"],
                                        "description": "main: the scan reviewed in the terminal (default). nightly: the nightly run's scan."]
        func tool(_ name: String, _ description: String, _ properties: [String: Any] = [:], required: [String] = [],
                  readOnly: Bool, destructive: Bool = false) -> [String: Any] {
            [
                "name": name,
                "description": description,
                "inputSchema": ["type": "object", "properties": properties, "required": required] as [String: Any],
                "annotations": ["readOnlyHint": readOnly, "destructiveHint": destructive],
            ]
        }
        var destinations = ["duplicates"]
        if allowTrash { destinations.append("trash") }
        return [
            tool("list_sources", "Apple Photos albums, how far back the library goes, and recently scanned places.", readOnly: true),
            tool("scan", "Scan photos for near-identical groups and pick the best of each. Give one of: album, months, from/to, folder. With none, scans the whole library. Takes seconds to minutes.", [
                "album": ["type": "string", "description": "Apple Photos album name, as list_sources shows it."],
                "months": ["type": "array", "items": ["type": "string"], "description": "Months to scan, e.g. [\"2024-01\", \"2024-07\"]."] as JSON,
                "from": ["type": "string", "description": "Start: 2024, 2024-06 or 2024-06-15."],
                "to": ["type": "string", "description": "End, inclusive."],
                "folder": ["type": "string", "description": "A folder on this Mac or a drive."],
            ], readOnly: false),
            tool("list_groups", "The groups from the last scan, each photo with its state (best, keep, move, moved), PixelGraph's note and any flag (eyes closed, blurry…).", [
                "workspace": workspace,
                "pending_only": ["type": "boolean", "description": "Only groups with photos still to move (default true)."],
                "offset": ["type": "integer"], "limit": ["type": "integer", "description": "Default 20."],
            ], readOnly: true),
            tool("show_photos", "Look at a group's photos, lettered A, B, C…", [
                "workspace": workspace,
                "group": ["type": "string", "description": "Group id from list_groups, e.g. g3."],
                "photos": ["type": "array", "items": ["type": "string"], "description": "Letters; default the first 8."] as JSON,
            ], required: ["group"], readOnly: true),
            tool("set_pick", "Change who's kept in a group: best becomes the one ★, keep are kept too, move go when you move.", [
                "workspace": workspace,
                "group": ["type": "string"],
                "best": ["type": "string", "description": "Letter of the best photo."],
                "keep": ["type": "array", "items": ["type": "string"]] as JSON,
                "move": ["type": "array", "items": ["type": "string"]] as JSON,
                "reason": ["type": "string", "description": "Why the moved ones go, e.g. eyes closed."],
            ], required: ["group"], readOnly: false),
            tool("move", "Move the photos selected to move. duplicates: into the PGDuplicates album or folder, can be undone. "
                 + (allowTrash ? "trash: Recently Deleted in Photos or the Trash, only when the person asked to delete (set confirm_delete). " : "Deleting is switched off here. ")
                 + "Use dry_run true first to see what would move.", [
                "workspace": workspace,
                "groups": ["type": "array", "items": ["type": "string"], "description": "Group ids; default every group with photos selected."] as JSON,
                "destination": ["type": "string", "enum": destinations] as JSON,
                "dry_run": ["type": "boolean", "description": "Default true."],
                "confirm_delete": ["type": "boolean"],
            ], readOnly: false, destructive: allowTrash),
            tool("undo", "Put back the photos from the last move.", readOnly: false),
            tool("stats", "How PixelGraph's picks compare with the person's own review decisions.", readOnly: true),
            tool("nightly_status", "What the last nightly run did and how many close calls it left.", readOnly: true),
        ]
    }

    private func text(_ value: Any) -> [[String: Any]] {
        [["type": "text", "text": value as? String ?? Agent.json(value)]]
    }

    private func call(_ name: String, _ args: [String: Any]) async throws -> [[String: Any]] {
        let workspace = try Agent.Workspace(args["workspace"])
        switch name {
        case "list_sources":
            try await Library.requestAccess()
            let albums = Library.albums().prefix(40).map { ["album": $0.title, "photos": $0.count] as [String: Any] }
            var info: [String: Any] = ["albums": Array(albums), "library_photos": Library.totalCount()]
            if let oldest = Library.oldestDate() { info["oldest_photo"] = oldest.formatted(.iso8601) }
            info["recent"] = Recents.all().prefix(8).map { $0.source.description }
            return text(info)

        case "scan":
            let source = try Agent.source(album: args["album"] as? String, months: args["months"] as? [String],
                                          from: args["from"] as? String, to: args["to"] as? String, folder: args["folder"] as? String)
            if source.isPhotos { try await Library.requestAccess() }
            let run = try await Agent.scan(source, into: .main, quiet: true)
            return text(Agent.summary(run))

        case "list_groups":
            let run = try Run.load(from: workspace.runFile)
            let places = Agent.places(run, pendingOnly: args["pending_only"] as? Bool ?? true)
            let offset = max(0, args["offset"] as? Int ?? 0), limit = max(1, min(50, args["limit"] as? Int ?? 20))
            let page = places.dropFirst(offset).prefix(limit).map { Agent.describe(Agent.group(run, $0), place: $0) }
            return text(["scope": run.scope, "total": places.count, "offset": offset, "groups": Array(page)] as JSON)

        case "show_photos":
            guard let id = args["group"] as? String else { throw Agent.Failure("Which group? Give its id, e.g. g3.") }
            let run = try Run.load(from: workspace.runFile)
            let place = try Agent.place(id, in: run)
            var content = text(Agent.describe(Agent.group(run, place), place: place))
            for (letter, data) in try Agent.thumbnails(workspace, place, letters: args["photos"] as? [String]) {
                content.append(["type": "text", "text": "Photo \(letter):"])
                content.append(["type": "image", "data": data.base64EncodedString(), "mimeType": "image/jpeg"])
            }
            return content

        case "set_pick":
            guard let id = args["group"] as? String else { throw Agent.Failure("Which group? Give its id, e.g. g3.") }
            var run = try Run.load(from: workspace.runFile)
            let place = try Agent.place(id, in: run)
            try Agent.setPick(&run, place, best: args["best"] as? String, keep: args["keep"] as? [String] ?? [],
                              move: args["move"] as? [String] ?? [], reason: args["reason"] as? String)
            try run.save(to: workspace.runFile)
            return text(Agent.describe(Agent.group(run, place), place: place))

        case "move":
            let destination = args["destination"] as? String ?? "duplicates"
            let trash = destination == "trash"
            if trash && !allowTrash { throw Agent.Failure("Deleting is switched off for this connection; move to duplicates instead.") }
            if trash && args["confirm_delete"] as? Bool != true {
                throw Agent.Failure("Deleting needs confirm_delete: true, and only when the person asked to delete.")
            }
            let dryRun = args["dry_run"] as? Bool ?? true
            let moved = try await Agent.move(workspace, groups: args["groups"] as? [String], to: trash ? .trash : .duplicates, dryRun: dryRun)
            let verb = dryRun ? "Would move" : "Moved"
            let place = trash ? "to Recently Deleted / the Trash" : "to PGDuplicates"
            return text(["summary": "\(verb) \(moved.photos) photos \(place) from \(moved.groups.count) groups.", "groups": moved.preview] as JSON)

        case "undo":
            return text(try await Agent.undo())

        case "stats":
            return text(Eval.report())

        case "nightly_status":
            guard let last = Agent.lastNightly() else { return text("The nightly run hasn't run yet. Set it up with `pixelgraph schedule`.") }
            return text(last)

        default:
            throw Agent.Failure("No tool called \(name).")
        }
    }
}

/// Just enough HTTP/1.1 for one request per connection.
struct HTTPRequest: Sendable {
    let method: String
    let path: String
    let body: Data

    /// Nil until the whole request (headers and body) has arrived.
    init?(_ data: Data) {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let start = head.first?.split(separator: " ") ?? []
        guard start.count >= 2 else { return nil }
        var length = 0
        for line in head.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "content-length" { length = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0 }
        }
        let body = data[end.upperBound...]
        guard body.count >= length else { return nil }
        method = String(start[0])
        path = String(start[1])
        self.body = Data(body.prefix(length))
    }

    static func response(_ status: Int, _ body: String, extra: [String: String] = [:]) -> Data {
        response(status, Data(body.utf8), type: "text/plain; charset=utf-8", extra: extra)
    }

    static func response(_ status: Int, _ body: Data, type: String, extra: [String: String] = [:]) -> Data {
        let reason = [200: "OK", 202: "Accepted", 404: "Not Found", 405: "Method Not Allowed"][status] ?? "OK"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (key, value) in extra { head += "\(key): \(value)\r\n" }
        return Data((head + "\r\n").utf8) + body
    }
}
