// Copyright (c) 2026 KaizenTrick. SPDX-License-Identifier: MIT
import Foundation

@main struct VerifyCodexUsage {
    static func main() async throws {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) { checks += 1; precondition(value(), label) }
        let now = Date(timeIntervalSince1970: 1_000_000)
        let sample = #"{"rateLimits":{"primary":{"usedPercent":99,"windowDurationMins":300,"resetsAt":2000000}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":28,"windowDurationMins":10080,"resetsAt":2000000},"secondary":null},"other":{"primary":{"usedPercent":10,"windowDurationMins":300,"resetsAt":2000000},"secondary":{"usedPercent":80.2,"windowDurationMins":10080,"resetsAt":2000000}}},"ordinaryUsageAllowed":false}"#
        let value = try CodexUsageSnapshot.decode(Data(sample.utf8), at: now)
        check(value.buckets.count == 2, "prefer all authoritative buckets over legacy")
        check(value.buckets[0].windows.count == 1, "null window is not invented")
        check(value.buckets[0].windows[0].remainingPercent == 72, "remaining is 100 minus used")
        check(value.buckets[0].windows[0].title == "7 días", "periods come from the server, never assumed")
        check(value.buckets[1].limitingWindow(at: now)?.remainingPercent == 19, "compact uses the tightest remaining quota, rounded down")
        check(value.ordinaryUsageAllowed == false, "backend denial survives nonzero percentages")
        check(value.buckets[0].limitingWindow(at: Date(timeIntervalSince1970: 2_000_001)) == nil, "reset time is not fabricated recovery")
        check(value.isFresh(at: now) && !value.isFresh(at: now.addingTimeInterval(181)), "stale data is explicitly unavailable")
        check(!value.isFresh(at: now.addingTimeInterval(-1)), "clock going backwards cannot make stale data fresh")
        let missing = try CodexUsageSnapshot.decode(Data(#"{"rateLimitsByLimitId":{"codex":{"primary":null,"secondary":null}}}"#.utf8), at: now)
        check(missing.buckets[0].limitingWindow(at: now) == nil, "missing usage never becomes zero usage")
        let legacy = try CodexUsageSnapshot.decode(Data(#"{"rateLimits":{"primary":{"usedPercent":110,"windowDurationMins":null,"resetsAt":null}}}"#.utf8), at: now)
        check(legacy.buckets[0].windows[0].remainingPercent == 0, "remaining quota is clamped")
        check(legacy.buckets[0].windows[0].title == "Límite", "unknown duration is labeled honestly")
        for json in [#"{"rateLimits":{"primary":{"usedPercent":-1}}}"#, #"{"rateLimits":{"primary":{"usedPercent":"bad"}}}"#, #"{"rateLimits":{"primary":{"usedPercent":1,"windowDurationMins":0}}}"#] {
            do { _ = try CodexUsageSnapshot.decode(Data(json.utf8)); preconditionFailure("invalid window accepted") }
            catch { checks += 1 }
        }
        var frames = CodexUsageFrames()
        check(tryFrames(&frames, Data("{\"id\":".utf8)).isEmpty, "partial JSON is buffered")
        check(tryFrames(&frames, Data("1}\n{\"id\":2}\n".utf8)).count == 2, "split/coalesced pipe frames")
        do { _ = try frames.append(Data(repeating: 65, count: CodexUsageFrames.maximumBytes)); preconditionFailure("unbounded frame") }
        catch { checks += 1 }

        // Exercise the real subprocess transport with a local fake server. No
        // Codex account, user settings or network access is used by regression CI.
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let server = root.appendingPathComponent("fake-codex")
        defer { try? FileManager.default.removeItem(at: server) }
        func script(_ body: String) throws {
            try ("#!/usr/bin/python3\n" + body).write(to: server, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: server.path)
        }
        try script("""
        import sys,json
        assert sys.argv[1:]==['app-server','--listen','stdio://']
        first=json.loads(sys.stdin.readline()); assert first['method']=='initialize'
        print(json.dumps({'id':1,'result':{}}),flush=True)
        assert json.loads(sys.stdin.readline())['method']=='initialized'
        request=json.loads(sys.stdin.readline()); assert request['method']=='account/rateLimits/read'
        print(json.dumps({'method':'account/rateLimits/updated','params':{}}),flush=True)
        print(json.dumps({'id':2,'result':{'rateLimits':{'primary':{'usedPercent':34,'windowDurationMins':300,'resetsAt':2000000000}}}}),flush=True)
        sys.stdin.read()
        """)
        let live = try await CodexUsageRequest().read(executable: server)
        check(live.buckets[0].windows[0].remainingPercent == 66, "real handshake/read/notification handling")
        try script("import time\ntime.sleep(30)\n")
        let timeoutStart = Date()
        do { _ = try await CodexUsageRequest().read(executable: server, timeout: 0.2); preconditionFailure("timeout") }
        catch { check(error as? CodexUsageError == .timeout, "timeout is actionable") }
        check(Date().timeIntervalSince(timeoutStart) < 2, "unresponsive child does not hang UI")
        let request = CodexUsageRequest()
        let task = Task { try await request.read(executable: server) }
        try await Task.sleep(for: .milliseconds(100)); task.cancel()
        do { _ = try await task.value; preconditionFailure("cancellation") }
        catch { check(error as? CodexUsageError == .cancelled, "disconnect cancels in-flight process") }
        let cancelled = CodexUsageRequest(); cancelled.shutdown()
        do { _ = try await cancelled.read(executable: server); preconditionFailure("cancel before launch") }
        catch { check(error as? CodexUsageError == .cancelled, "pre-launch cancellation cannot start a child") }
        try script("import sys\nprint('x'*1100000,flush=True)\nsys.stdin.read()\n")
        do { _ = try await CodexUsageRequest().read(executable: server); preconditionFailure("oversized output") }
        catch { check(error as? CodexUsageError == .invalidResponse, "subprocess output is bounded") }
        print("PASS: \(checks) Codex usage checks: buckets, freshness, quotas, real stdio handshake, timeout, cancellation and output bounds.")
    }
    static func tryFrames(_ frames: inout CodexUsageFrames, _ bytes: Data) -> [Data] { try! frames.append(bytes) }
}
