"""Regression tests: state and transport are isolated from the installed inbox."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(os.environ.get("INBOX_SCRIPT_UNDER_TEST", Path(__file__).resolve().parents[1] / "scripts/herdr-inbox.ps1"))
PWSH = shutil.which("pwsh")
ID = "a" * 32
OTHER = "b" * 32


@unittest.skipUnless(PWSH, "PowerShell 7 is required")
class InboxTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="herdr-inbox-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.inbox = self.root / "inbox"
        self.inbox.mkdir()
        self.calls = self.root / "calls.jsonl"
        self.fake = self.root / "fake-herdr.ps1"
        self.fake.write_text("""
@{args=@($args)} | ConvertTo-Json -Compress | Add-Content -LiteralPath $env:INBOX_TEST_CALLS
if ($env:INBOX_TEST_DELAY) { Start-Sleep -Milliseconds ([int]$env:INBOX_TEST_DELAY) }
$global:LASTEXITCODE = [int]$env:INBOX_TEST_EXIT
""", encoding="utf-8")
        self.env = dict(os.environ, HERDR_BIN_PATH=str(self.fake), HERDR_PANE_ID="test:stale",
                        INBOX_TEST_CALLS=str(self.calls), INBOX_TEST_EXIT="0", INBOX_TEST_DELAY="")
        self.transcript = self.root / "transcript.jsonl"
        self.payload = {"session_id": "worker-session", "transcript_path": str(self.transcript)}

    def command(self, *args):
        return [PWSH, "-NoProfile", "-NonInteractive", "-File", str(SCRIPT), *args,
                "-InboxDirectory", str(self.inbox)]

    def run_script(self, *args, payload=None):
        return subprocess.run(self.command(*args), input=json.dumps(payload if payload is not None else self.payload),
                              text=True, capture_output=True, env=self.env, timeout=12)

    def marker(self, pane="test:worker", ident=ID):
        path = self.inbox / (re.sub(r"[^A-Za-z0-9_-]", "_", pane) + ".json")
        path.write_text(json.dumps(dict(version=2, id=ident, to=pane, replyTo="test:requester",
                                       created="fixture")), encoding="utf-8")
        return path

    def codex(self, ids=(ID,), role="user", session="worker-session", text=None):
        body = text if text is not None else "\n".join("[herdr-inbox:" + i + "]" for i in ids)
        records = [
            {"type": "session_meta", "payload": {"id": session, "session_id": session}},
            {"type": "response_item", "payload": {"type": "message", "role": role,
                                                 "content": [{"type": "input_text", "text": body}]}},
        ]
        self.transcript.write_text("\n".join(map(json.dumps, records)), encoding="utf-8")

    def logged(self):
        return [json.loads(line)["args"] for line in self.calls.read_text(encoding="utf-8-sig").splitlines()] if self.calls.exists() else []

    def test_codex_stale_environment_routes_verified_worker_once(self):
        marker = self.marker()
        stale = self.marker("test:stale", OTHER)
        self.codex()
        result = self.run_script("notify")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(marker.exists())
        self.assertTrue(stale.exists())
        calls = self.logged()
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][:3], ["agent", "prompt", "test:requester"])
        self.assertIn("herdr agent read test:worker ", calls[0][3])
        self.run_script("notify")
        self.assertEqual(len(self.logged()), 1)

    def test_delegate_and_claude_stop_round_trip(self):
        result = self.run_script("delegate", "-To", "test:worker", "-ReplyTo", "test:requester", "-Message", "Do the task")
        self.assertEqual(result.returncode, 0, result.stderr)
        prompt = self.logged()[0][3]
        self.assertRegex(prompt, r"\[herdr-inbox:[0-9a-f]{32}\]")
        self.transcript.write_text(json.dumps({"type": "user", "sessionId": "worker-session",
            "message": {"role": "user", "content": [{"type": "text", "text": prompt}]}}), encoding="utf-8")
        self.assertEqual(self.run_script("notify").returncode, 0)
        self.assertEqual(len(self.logged()), 2)
        self.assertFalse(list(self.inbox.glob("*.json")))

    def test_claude_string_content(self):
        marker = self.marker()
        self.transcript.write_text(json.dumps({"type": "user", "sessionId": "worker-session",
            "message": {"role": "user", "content": "[herdr-inbox:" + ID + "]"}}), encoding="utf-8")
        self.run_script("notify")
        self.assertFalse(marker.exists())

    def test_delivery_failure_retains_then_retries(self):
        marker = self.marker()
        self.codex()
        self.env["INBOX_TEST_EXIT"] = "7"
        result = self.run_script("notify")
        self.assertEqual(result.returncode, 0)
        self.assertTrue(marker.exists())
        self.assertIn("delivery failed", result.stderr)
        self.env["INBOX_TEST_EXIT"] = "0"
        self.run_script("notify")
        self.assertFalse(marker.exists())
        self.assertEqual(len(self.logged()), 2)

    def test_failed_delegation_preserves_pending_state(self):
        self.env["INBOX_TEST_EXIT"] = "7"
        result = self.run_script("delegate", "-To", "test:worker", "-ReplyTo", "test:requester", "-Message", "task")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(list(self.inbox.glob("*.json"))), 1)

    def test_duplicate_delegation_does_not_overwrite(self):
        marker = self.marker()
        before = marker.read_bytes()
        result = self.run_script("delegate", "-To", "test:worker", "-ReplyTo", "test:other", "-Message", "task")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(marker.read_bytes(), before)
        self.assertFalse(self.logged())

    def test_no_transcript_never_falls_back_to_environment(self):
        marker = self.marker("test:stale")
        result = self.run_script("notify", payload={})
        self.assertEqual(result.returncode, 0)
        self.assertTrue(marker.exists())
        self.assertFalse(self.logged())
        self.assertIn("lacks session_id", result.stderr)

    def test_subagent_stop_is_ignored(self):
        marker = self.marker()
        self.codex()
        self.run_script("notify", payload=dict(self.payload, agent_id="child"))
        self.assertTrue(marker.exists())
        self.assertFalse(self.logged())

    def test_assistant_and_tool_content_cannot_authorize(self):
        marker = self.marker()
        self.codex(role="assistant")
        self.run_script("notify")
        self.assertTrue(marker.exists())
        self.assertFalse(self.logged())
        self.transcript.write_text(json.dumps({"type": "user", "sessionId": "worker-session", "message":
            {"role": "user", "content": [{"type": "tool_result", "content": "[herdr-inbox:" + ID + "]"}]}}), encoding="utf-8")
        self.run_script("notify")
        self.assertTrue(marker.exists())
        self.assertFalse(self.logged())

    def test_wrong_session_retains_marker(self):
        marker = self.marker()
        self.codex(session="different-session")
        result = self.run_script("notify")
        self.assertTrue(marker.exists())
        self.assertFalse(self.logged())
        self.assertIn("session mismatch", result.stderr)

    def test_wrong_claude_session_retains_marker(self):
        marker = self.marker()
        self.transcript.write_text(json.dumps({"type": "user", "sessionId": "different-session",
            "message": {"role": "user", "content": "[herdr-inbox:" + ID + "]"}}), encoding="utf-8")
        self.run_script("notify")
        self.assertTrue(marker.exists())
        self.assertFalse(self.logged())

    def test_legacy_marker_is_retained_without_delivery(self):
        marker = self.inbox / "test_stale.json"
        marker.write_text(json.dumps({"to": "test:stale", "replyTo": "test:requester", "created": "fixture"}))
        self.codex()
        result = self.run_script("notify")
        self.assertTrue(marker.exists())
        self.assertFalse(self.logged())
        self.assertIn("legacy", result.stderr)

    def test_ambiguous_transcript_is_not_delivered(self):
        a = self.marker()
        b = self.marker("test:second", OTHER)
        self.codex(ids=(ID, OTHER))
        result = self.run_script("notify")
        self.assertTrue(a.exists() and b.exists())
        self.assertFalse(self.logged())
        self.assertIn("ambiguous", result.stderr)

    def test_malformed_transcript_diagnostic_does_not_echo_content(self):
        marker = self.marker()
        self.transcript.write_text('{"secret":"PRIVATE-FIXTURE", "[herdr-inbox:": broken')
        result = self.run_script("notify")
        self.assertEqual(result.returncode, 0)
        self.assertTrue(marker.exists())
        self.assertFalse(self.logged())
        self.assertIn("malformed", result.stderr)
        self.assertNotIn("PRIVATE-FIXTURE", result.stderr)

    def test_missing_transcript_is_safe(self):
        marker = self.marker()
        result = self.run_script("notify")
        self.assertTrue(marker.exists())
        self.assertFalse(self.logged())
        self.assertIn("unreadable", result.stderr)

    def test_bad_marker_routing_is_retained(self):
        marker = self.marker()
        data = json.loads(marker.read_text())
        data["to"] = "test:different"
        marker.write_text(json.dumps(data))
        self.codex()
        result = self.run_script("notify")
        self.assertTrue(marker.exists())
        self.assertFalse(self.logged())
        self.assertIn("routing", result.stderr)

    def test_concurrent_stops_deliver_once(self):
        marker = self.marker()
        self.codex()
        self.env["INBOX_TEST_DELAY"] = "600"
        first = subprocess.Popen(self.command("notify"), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, text=True, env=self.env)
        second = subprocess.Popen(self.command("notify"), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, text=True, env=self.env)
        first.stdin.write(json.dumps(self.payload))
        first.stdin.close()
        first.stdin = None
        second.communicate(json.dumps(self.payload), timeout=12)
        first.communicate(timeout=12)
        self.assertEqual(first.returncode, 0)
        self.assertEqual(second.returncode, 0)
        self.assertFalse(marker.exists())
        self.assertEqual(len(self.logged()), 1)

    def test_unrelated_corrupt_marker_does_not_block_valid_delivery(self):
        marker = self.marker()
        (self.inbox / "unrelated.json").write_text("{broken")
        self.codex()
        result = self.run_script("notify")
        self.assertFalse(marker.exists())
        self.assertEqual(len(self.logged()), 1)
        self.assertIn("malformed marker", result.stderr)

    def test_long_transcript_is_streamed_within_hook_deadline(self):
        marker = self.marker()
        self.codex()
        first_lines = self.transcript.read_text()
        filler = json.dumps({"type": "tool_result", "content": "x" * 100_000}) + "\n"
        with self.transcript.open("w", encoding="utf-8") as stream:
            stream.write(first_lines + "\n")
            for _ in range(500):
                stream.write(filler)
        import time
        started = time.monotonic()
        result = self.run_script("notify")
        self.assertLess(time.monotonic() - started, 12)
        self.assertFalse(marker.exists(), result.stderr)
        self.assertEqual(len(self.logged()), 1)

    def test_missing_delegation_after_compaction_is_retained(self):
        marker = self.marker()
        self.codex(ids=())
        result = self.run_script("notify")
        self.assertTrue(marker.exists())
        self.assertFalse(self.logged())
        self.assertIn("no pending delegation matched", result.stderr)

    def test_codex_id_only_metadata_is_supported(self):
        marker = self.marker()
        self.codex()
        records = [json.loads(line) for line in self.transcript.read_text().splitlines()]
        del records[0]["payload"]["session_id"]
        self.transcript.write_text("\n".join(map(json.dumps, records)), encoding="utf-8")
        self.run_script("notify")
        self.assertFalse(marker.exists())
        self.assertEqual(len(self.logged()), 1)

    def test_malformed_hook_json_never_blocks_stop(self):
        marker = self.marker()
        result = subprocess.run(self.command("notify"), input="{", text=True, capture_output=True,
                                env=self.env, timeout=12)
        self.assertEqual(result.returncode, 0)
        self.assertTrue(marker.exists())
        self.assertIn("invalid hook JSON", result.stderr)
        self.assertFalse(self.logged())

    def test_version_has_no_side_effects(self):
        result = self.run_script("version")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "1.2.0")
        self.assertFalse(self.logged())
        self.assertFalse(list(self.inbox.iterdir()))

    def test_opencode_verified_identity_routes_without_pane_environment(self):
        marker = self.marker()
        result = self.run_script("notify", payload={"source": "opencode", "session_id": "worker-session",
                                                  "delegation_ids": [ID, ID]})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(marker.exists())
        self.assertEqual(len(self.logged()), 1)
        self.assertIn("herdr agent read test:worker ", self.logged()[0][3])

    def test_opencode_invalid_id_retains_marker(self):
        marker = self.marker()
        result = self.run_script("notify", payload={"source": "opencode", "session_id": "worker-session",
                                                  "delegation_ids": [ID, "invalid"]})
        self.assertTrue(marker.exists())
        self.assertFalse(self.logged())
        self.assertIn("invalid OpenCode", result.stderr)

    def test_opencode_missing_session_is_rejected(self):
        marker = self.marker()
        self.run_script("notify", payload={"source": "opencode", "delegation_ids": [ID]})
        self.assertTrue(marker.exists())
        self.assertFalse(self.logged())

    def test_opencode_scalar_ids_are_rejected(self):
        marker = self.marker()
        self.run_script("notify", payload={"source": "opencode", "session_id": "worker-session", "delegation_ids": ID})
        self.assertTrue(marker.exists())
        self.assertFalse(self.logged())

    def test_opencode_ambiguous_markers_are_retained(self):
        first = self.marker()
        second = self.marker("test:second", OTHER)
        self.run_script("notify", payload={"source": "opencode", "session_id": "worker-session", "delegation_ids": [ID, OTHER]})
        self.assertTrue(first.exists() and second.exists())
        self.assertFalse(self.logged())


if __name__ == "__main__":
    unittest.main()
