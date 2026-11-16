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
        check(!value.canReportRemaining(at: now), "nonzero quota must not imply current entitlement when the account is blocked")
        check(value.nextDisplayChange(after: now) == now.addingTimeInterval(180), "account block expires with the snapshot")
        check(value.buckets[0].limitingWindow(at: Date(timeIntervalSince1970: 2_000_001)) == nil, "reset time is not fabricated recovery")
        check(value.isFresh(at: now) && !value.isFresh(at: now.addingTimeInterval(181)), "stale data is explicitly unavailable")
        check(!value.isFresh(at: now.addingTimeInterval(-1)), "clock going backwards cannot make stale data fresh")
        check(!value.isFresh(at: now.addingTimeInterval(180)), "the display deadline marks the reading stale immediately")
        let impending = try CodexUsageSnapshot.decode(Data(#"{"rateLimits":{"primary":{"usedPercent":70,"resetsAt":1000012},"secondary":{"usedPercent":50,"resetsAt":1000050}}}"#.utf8), at: now)
        check(impending.nextDisplayChange(after: now) == now.addingTimeInterval(12), "display updates at the first reset, before the next poll")
        let firstReset = now.addingTimeInterval(12)
        check(impending.buckets[0].limitingWindow(at: firstReset)?.remainingPercent == 50 && impending.nextDisplayChange(after: firstReset) == now.addingTimeInterval(50),
              "an expired window is excluded while another valid window remains")
        let missing = try CodexUsageSnapshot.decode(Data(#"{"rateLimitsByLimitId":{"codex":{"primary":null,"secondary":null}}}"#.utf8), at: now)
        check(missing.buckets[0].limitingWindow(at: now) == nil, "missing usage never becomes zero usage")
        let legacy = try CodexUsageSnapshot.decode(Data(#"{"rateLimits":{"primary":{"usedPercent":110,"windowDurationMins":null,"resetsAt":null}}}"#.utf8), at: now)
        check(legacy.buckets[0].windows[0].remainingPercent == 0, "remaining quota is clamped")
        check(legacy.buckets[0].windows[0].title == "Límite", "unknown duration is labeled honestly")
        let legacyWithNullMap = try CodexUsageSnapshot.decode(Data(#"{"rateLimits":{"primary":{"usedPercent":40}},"rateLimitsByLimitId":{"codex":null}}"#.utf8), at: now)
        check(legacyWithNullMap.buckets.first?.limitingWindow(at: now)?.remainingPercent == 60, "an empty named map preserves authoritative legacy data")
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
        let unsafeBinary = root.appendingPathComponent("unsafe-codex")
        let safeHome = root.appendingPathComponent("safe-home", isDirectory: true)
        let symlinkHome = root.appendingPathComponent("symlink-home")
        defer {
            try? FileManager.default.removeItem(at: unsafeBinary)
            try? FileManager.default.removeItem(at: safeHome)
            try? FileManager.default.removeItem(at: symlinkHome)
        }
        try "#!/bin/sh\nexit 0\n".write(to: unsafeBinary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: unsafeBinary.path)
        check(!CodexExecutable.isSafeExecutable(unsafeBinary), "world-writable executable rejected")
        check(CodexExecutable.isSafeExecutable(server), "owner-only executable accepted")
        try FileManager.default.createDirectory(at: safeHome, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: symlinkHome, withDestinationURL: safeHome)
        check(CodexExecutable.validatedHome(safeHome.path) != nil, "valid owner-only CODEX_HOME accepted")
        check(CodexExecutable.validatedHome(symlinkHome.path) == nil, "symlink CODEX_HOME rejected")
        check(CodexExecutable.validatedHome(safeHome.path + "/../safe-home") == nil, "traversal CODEX_HOME rejected")
        check(CodexExecutable.validatedHome("relative/path") == nil, "relative CODEX_HOME rejected")
        print("PASS: \(checks) Codex usage checks: buckets, freshness, quotas, real stdio handshake, timeout, cancellation, executable/home hardening and output bounds.")

        let cursor = try CursorUsageSnapshot.decode("""
        Opened a background tab.
        ORUVI_CURSOR_USAGE {"status":"ok","usedPercent":1,"resetLabel":"Nov 21"}
        Background tab closed.
        """, at: now)
        checks = 0
        check(cursor.remainingPercent == 99 && cursor.resetLabel == "Nov 21" && cursor.fetchedAt == now,
              "Cursor usage survives Aside's tab messages and keeps the dashboard reset date")
        check(cursor.isFresh(at: now) && cursor.isFresh(at: now.addingTimeInterval(299)), "recent Cursor readings can be reused when reopening Conexiones")
        check(!cursor.isFresh(at: now.addingTimeInterval(300)) && !cursor.isFresh(at: now.addingTimeInterval(-1)),
              "expired or future-dated Cursor readings never show as current")
        for reading in [
            #"{"status":"ok","usedPercent":-1,"resetLabel":"Nov 21"}"#,
            #"{"status":"ok","usedPercent":101,"resetLabel":"Nov 21"}"#,
            #"{"status":"ok","usedPercent":1}"#,
            #"{"status":"unavailable"}"#
        ] {
            do {
                _ = try CursorUsageSnapshot.decode("ORUVI_CURSOR_USAGE " + reading)
                preconditionFailure("Missing or invalid data must not become a valid quota")
            } catch CursorUsageError.dashboardUnavailable { checks += 1 }
        }
        do {
            _ = try CursorUsageSnapshot.decode(#"ORUVI_CURSOR_USAGE {"status":"signIn"}"#)
            preconditionFailure("A signed-out dashboard must not publish a quota")
        } catch CursorUsageError.signInRequired { checks += 1 }
        print("PASS: \(checks) Cursor usage checks: dashboard data, invalid quotas and sign-in.")
    }
    static func tryFrames(_ frames: inout CodexUsageFrames, _ bytes: Data) -> [Data] { try! frames.append(bytes) }
}
