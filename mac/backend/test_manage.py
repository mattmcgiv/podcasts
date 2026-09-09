import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import socket
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import manage


def processing_db(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(path)
    db.executescript("""
        CREATE TABLE podcasts (
            id INTEGER PRIMARY KEY,
            feed_url TEXT NOT NULL UNIQUE,
            title TEXT NOT NULL DEFAULT '',
            is_subscribed INTEGER NOT NULL DEFAULT 1,
            created_at INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE episodes (
            id INTEGER PRIMARY KEY,
            podcast_id INTEGER NOT NULL,
            guid TEXT NOT NULL,
            title TEXT NOT NULL DEFAULT '',
            audio_url TEXT NOT NULL DEFAULT '',
            published_at INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE episode_state (
            episode_id INTEGER PRIMARY KEY,
            position_secs REAL NOT NULL DEFAULT 0,
            played_at INTEGER,
            archived_at INTEGER,
            updated_at INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE listen_episodes (episode_id INTEGER PRIMARY KEY);
    """)
    db.executescript((manage.ROOT / "backend/src/browser_schema.sql").read_text())
    return db


def add_episode(db, episode_id, podcast_id, guid, **job):
    db.execute("INSERT INTO episodes(id,podcast_id,guid,title,audio_url) VALUES(?,?,?,?,?)",
               (episode_id, podcast_id, guid, str(episode_id), "audio"))
    db.execute("INSERT INTO browser_jobs(episode_id,stage,attempts,error,priority) VALUES(?,?,?,?,?)",
               (episode_id, job.get("stage", "queued"), job.get("attempts", 0), job.get("error"), job.get("priority", 0)))


def job_rows(db):
    return db.execute("SELECT episode_id,stage,attempts,error,next_retry_at,priority FROM browser_jobs ORDER BY episode_id").fetchall()


class ManageTests(unittest.TestCase):
    def test_backup_includes_committed_wal_and_refuses_overwrite(self):
        with tempfile.TemporaryDirectory() as directory:
            source, dest = Path(directory) / "live.sqlite", Path(directory) / "backup.sqlite"
            with sqlite3.connect(source) as db:
                db.execute("PRAGMA journal_mode=WAL")
                for table in ("podcasts", "episodes", "episode_state"):
                    db.execute(f"CREATE TABLE {table}(id INTEGER)")
                    db.execute(f"INSERT INTO {table} VALUES(1)")
                db.commit()
                self.assertEqual(manage.backup(source, dest), {"podcasts": 1, "episodes": 1, "episode_state": 1})
                with self.assertRaises(RuntimeError): manage.backup(source, dest)

    def test_enrollment_preserves_credentials_and_creates_hashed_token(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(manage, "STATE", Path(directory)):
            (Path(directory) / "data").mkdir()
            with sqlite3.connect(Path(directory) / "data/pods.sqlite") as db:
                db.executescript("CREATE TABLE passkey_credentials(id TEXT); INSERT INTO passkey_credentials VALUES('existing'); CREATE TABLE auth_enroll_tokens(token_hash TEXT,expires_at INTEGER,used INTEGER);")
            output = io.StringIO()
            with contextlib.redirect_stdout(output): manage.enroll()
            token = output.getvalue().strip().split("#enroll=")[1]
            with sqlite3.connect(Path(directory) / "data/pods.sqlite") as db:
                self.assertEqual(db.execute("SELECT COUNT(*) FROM passkey_credentials").fetchone()[0], 1)
                self.assertEqual(db.execute("SELECT token_hash FROM auth_enroll_tokens").fetchone()[0], hashlib.sha256(token.encode()).hexdigest())

    def test_dns_always_specifies_both_address_families(self):
        with patch.object(manage, "dns_request", return_value="good") as request:
            manage.update_dns({"desec_token": "test-only"}, "192.168.1.20")
            self.assertIn("myipv4=192.168.1.20&myipv6=", request.call_args.args[0])
            manage.update_dns({"desec_token": "test-only"}, None)
            self.assertIn("myipv4=&myipv6=", request.call_args.args[0])

    def test_dns_transport_is_bounded_and_keeps_secret_off_argv(self):
        response = unittest.mock.Mock(returncode=0, stdout='{"ok":true}\n200')
        with patch.object(manage.subprocess, "run", return_value=response) as run:
            self.assertEqual(manage.json_request("https://desec.io/api/v1/domains/", "test-only"), {"ok": True})
            self.assertNotIn("test-only", " ".join(run.call_args.args[0]))
            self.assertIn("-4", run.call_args.args[0])
            self.assertEqual(run.call_args.kwargs["timeout"], 35)
            self.assertIn("test-only", run.call_args.kwargs["input"])

    def test_dns_error_does_not_expose_provider_response(self):
        response = unittest.mock.Mock(returncode=0, stdout='private-provider-body\n403')
        with patch.object(manage.subprocess, "run", return_value=response):
            with self.assertRaises(manage.urllib.error.HTTPError) as error:
                manage.json_request("https://desec.io/api/v1/domains/", "test-only")
            self.assertEqual(error.exception.code, 403)
            self.assertNotIn("private-provider-body", str(error.exception))

    def test_acme_waits_for_every_nameserver_and_resolver(self):
        found = unittest.mock.Mock(returncode=0, stdout='"test-proof"\n')
        missing = unittest.mock.Mock(returncode=0, stdout='')
        with patch.object(manage.subprocess, "run", side_effect=[found, missing, found, found] + [found] * 4) as run, patch.object(manage.time, "sleep") as sleep:
            manage.wait_for_acme_dns("test-proof")
            self.assertEqual(run.call_count, 8)
            sleep.assert_called_once_with(15)

    def test_acme_timeout_does_not_continue_to_validation(self):
        with patch.object(manage.time, "monotonic", side_effect=[0, 901]):
            with self.assertRaisesRegex(RuntimeError, "did not propagate"):
                manage.wait_for_acme_dns("test-proof")

    def test_jobs_hides_stale_rows_and_keeps_eligible_diagnostics(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(manage, "STATE", Path(directory)):
            path = Path(directory) / "data/pods.sqlite"
            with processing_db(path) as db:
                db.execute("INSERT INTO podcasts(id,feed_url,title,is_subscribed) VALUES(1,'https://a.example/feed','A',1),(2,'https://b.example/feed','B',0)")
                add_episode(db, 1, 1, "key")
                add_episode(db, 2, 1, "<![CDATA[key]]>")
                add_episode(db, 3, 1, "played")
                add_episode(db, 4, 1, "archived", stage="retry", attempts=4, error="download failed")
                add_episode(db, 5, 1, "blocked", stage="blocked", attempts=4, error="download failed")
                add_episode(db, 6, 1, "retry", stage="retry", attempts=3, error="classifier timeout")
                add_episode(db, 7, 1, "ready", stage="ready")
                add_episode(db, 8, 1, "priority", priority=2)
                add_episode(db, 9, 2, "unsubscribed")
                add_episode(db, 10, 2, "listen")
                db.execute("INSERT INTO episode_state(episode_id,played_at,updated_at) VALUES(3,123,123)")
                db.execute("INSERT INTO episode_state(episode_id,archived_at,updated_at) VALUES(4,123,123)")
                db.execute("INSERT INTO listen_episodes(episode_id) VALUES(10)")
                expected = [
                    {"episode_id": 8, "stage": "queued", "attempts": 0, "error": None},
                    {"episode_id": 1, "stage": "queued", "attempts": 0, "error": None},
                    {"episode_id": 5, "stage": "blocked", "attempts": 4, "error": "download failed"},
                    {"episode_id": 6, "stage": "retry", "attempts": 3, "error": "classifier timeout"},
                    {"episode_id": 10, "stage": "queued", "attempts": 0, "error": None},
                ]
                self.assertEqual(manage.list_jobs(db), expected)
                self.assertEqual(db.execute("SELECT COUNT(*) FROM browser_jobs").fetchone()[0], 10)
            output = io.StringIO()
            with contextlib.redirect_stdout(output), patch.object(sys, "argv", ["manage.py", "jobs"]):
                manage.main()
            printed = output.getvalue()
            self.assertNotIn("review", printed.lower())
            self.assertEqual([json.loads(line) for line in printed.splitlines()], expected)
            with sqlite3.connect(path) as db:
                self.assertEqual(db.execute("SELECT COUNT(*) FROM browser_jobs").fetchone()[0], 10)
                self.assertEqual(db.execute("SELECT stage FROM browser_jobs WHERE episode_id=2").fetchone()[0], "queued")

    def test_retry_rejects_unknown_ids_and_requeues_existing(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(manage, "STATE", Path(directory)):
            path = Path(directory) / "data/pods.sqlite"
            with processing_db(path) as db:
                db.execute("INSERT INTO podcasts(id,feed_url,title,is_subscribed) VALUES(1,'https://a.example/feed','A',1)")
                add_episode(db, 1, 1, "key", stage="retry", attempts=3, error="classifier timeout")
                add_episode(db, 2, 1, "other", stage="blocked", attempts=4, error="download failed")
                for invalid in (0, -1, 99, "nope"):
                    with self.assertRaises(ValueError):
                        manage.retry_job(db, invalid)
                self.assertEqual(db.execute("SELECT stage,error,next_retry_at,priority FROM browser_jobs WHERE episode_id=1").fetchone(),
                                 ("retry", "classifier timeout", 0, 0))
                manage.retry_job(db, 1)
                self.assertEqual(db.execute("SELECT stage,error,next_retry_at,priority,attempts FROM browser_jobs WHERE episode_id=1").fetchone(),
                                 ("queued", None, 0, 1, 3))
                self.assertEqual(db.execute("SELECT stage,error,priority,attempts FROM browser_jobs WHERE episode_id=2").fetchone(),
                                 ("blocked", "download failed", 0, 4))
            with self.assertRaises(ValueError), patch.object(sys, "argv", ["manage.py", "retry"]):
                manage.main()
            with self.assertRaises(ValueError), patch.object(sys, "argv", ["manage.py", "retry", "99"]):
                manage.main()
            with patch.object(sys, "argv", ["manage.py", "retry", "1"]):
                manage.main()
            with sqlite3.connect(path) as db:
                self.assertEqual(db.execute("SELECT COUNT(*) FROM browser_jobs").fetchone()[0], 2)
                self.assertEqual(db.execute("SELECT stage,priority FROM browser_jobs WHERE episode_id=1").fetchone(), ("queued", 1))

    def test_retry_rejects_ineligible_jobs_and_requeues_ready(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(manage, "STATE", Path(directory)):
            path = Path(directory) / "data/pods.sqlite"
            with processing_db(path) as db:
                db.execute("INSERT INTO podcasts(id,feed_url,title,is_subscribed) VALUES(1,'https://a.example/feed','A',1),(2,'https://b.example/feed','B',0)")
                add_episode(db, 1, 1, "key", stage="retry", attempts=3, error="classifier timeout")
                add_episode(db, 2, 1, "<![CDATA[key]]>", stage="queued", attempts=1, error="stale")
                add_episode(db, 3, 1, "played", stage="retry", attempts=2, error="played")
                add_episode(db, 4, 1, "archived", stage="queued", attempts=4, error="archived")
                add_episode(db, 5, 1, "ready", stage="ready", attempts=2)
                add_episode(db, 6, 2, "unsubscribed", stage="blocked", attempts=5, error="old")
                add_episode(db, 7, 2, "listen", stage="retry", attempts=1, error="classifier timeout")
                db.execute("INSERT INTO episode_state(episode_id,played_at,updated_at) VALUES(3,123,123)")
                db.execute("INSERT INTO episode_state(episode_id,archived_at,updated_at) VALUES(4,123,123)")
                db.execute("INSERT INTO listen_episodes(episode_id) VALUES(7)")
                before = job_rows(db)
                for ineligible in (2, 3, 4, 6):
                    with self.assertRaisesRegex(ValueError, "not eligible"):
                        manage.retry_job(db, ineligible)
                self.assertEqual(job_rows(db), before)
                manage.retry_job(db, 5)
                self.assertEqual(db.execute("SELECT stage,error,next_retry_at,priority,attempts FROM browser_jobs WHERE episode_id=5").fetchone(),
                                 ("queued", None, 0, 1, 2))
                manage.retry_job(db, 7)
                self.assertEqual(db.execute("SELECT stage,error,next_retry_at,priority,attempts FROM browser_jobs WHERE episode_id=7").fetchone(),
                                 ("queued", None, 0, 1, 1))
                manage.retry_job(db, 1)
                self.assertEqual(db.execute("SELECT stage,error,next_retry_at,priority,attempts FROM browser_jobs WHERE episode_id=1").fetchone(),
                                 ("queued", None, 0, 1, 3))
                self.assertEqual(db.execute("SELECT COUNT(*) FROM browser_jobs").fetchone()[0], 7)
            with self.assertRaisesRegex(ValueError, "not eligible"), patch.object(sys, "argv", ["manage.py", "retry", "2"]):
                manage.main()
            with sqlite3.connect(path) as db:
                self.assertEqual(job_rows(db), [
                    (1, "queued", 3, None, 0, 1),
                    (2, "queued", 1, "stale", 0, 0),
                    (3, "retry", 2, "played", 0, 0),
                    (4, "queued", 4, "archived", 0, 0),
                    (5, "queued", 2, None, 0, 1),
                    (6, "blocked", 5, "old", 0, 0),
                    (7, "queued", 1, None, 0, 1),
                ])

    def test_retry_blocked_job_starts_fresh_automatic_run(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(manage, "STATE", Path(directory)):
            path = Path(directory) / "data/pods.sqlite"
            artifact = Path(directory) / "data/AdRemovalData/AdRemoval/local/1/review.json"
            artifact.parent.mkdir(parents=True)
            artifact.write_text('{"must":"not-read"}')
            real_open = open

            def guarded_open(file, *args, **kwargs):
                name = file if isinstance(file, int) else str(file)
                if isinstance(name, str) and name.endswith("review.json"):
                    self.fail("retry must not inspect review.json")
                return real_open(file, *args, **kwargs)

            with processing_db(path) as db:
                db.execute("INSERT INTO podcasts(id,feed_url,title,is_subscribed) VALUES(1,'https://a.example/feed','A',1)")
                add_episode(db, 1, 1, "blocked", stage="blocked", attempts=4, error="download failed")
                add_episode(db, 2, 1, "retry", stage="retry", attempts=3, error="classifier timeout")
                add_episode(db, 3, 1, "cli", stage="blocked", attempts=4, error="classifier timeout")
                db.execute("UPDATE browser_jobs SET next_retry_at=999 WHERE episode_id IN (1,3)")
                with patch.object(manage.subprocess, "run") as run, patch("builtins.open", guarded_open):
                    manage.retry_job(db, 1)
                    run.assert_not_called()
                self.assertEqual(db.execute("SELECT stage,error,next_retry_at,priority,attempts FROM browser_jobs WHERE episode_id=1").fetchone(),
                                 ("queued", None, 0, 1, 0))
                self.assertEqual(db.execute("SELECT stage,error,next_retry_at,priority,attempts FROM browser_jobs WHERE episode_id=2").fetchone(),
                                 ("retry", "classifier timeout", 0, 0, 3))
            self.assertEqual(artifact.read_text(), '{"must":"not-read"}')
            with patch.object(sys, "argv", ["manage.py", "retry", "3"]), patch.object(manage.subprocess, "run") as run, patch("builtins.open", guarded_open):
                manage.main()
                run.assert_not_called()
            self.assertEqual(artifact.read_text(), '{"must":"not-read"}')
            with sqlite3.connect(path) as db:
                self.assertEqual(db.execute("SELECT stage,error,next_retry_at,priority,attempts FROM browser_jobs WHERE episode_id=1").fetchone(),
                                 ("queued", None, 0, 1, 0))
                self.assertEqual(db.execute("SELECT stage,error,next_retry_at,priority,attempts FROM browser_jobs WHERE episode_id=3").fetchone(),
                                 ("queued", None, 0, 1, 0))
                self.assertEqual(db.execute("SELECT COUNT(*) FROM browser_jobs").fetchone()[0], 3)

    def test_backend_env_merges_memory_keys_and_keeps_existing_config(self):
        # Merge keys into the existing config dict. Do not replace mac.json.
        with tempfile.TemporaryDirectory() as directory, patch.object(manage, "STATE", Path(directory)):
            config = {
                "desec_token": "placeholder-token",
                "acme_email": "ops@example.com",
                "whisper_model": "/models/whisper-large-v3-mlx",
                "memory_gate": False,
                "memory_whisper_defer_below_bytes": 1,
                "memory_whisper_resume_above_bytes": 2,
                "memory_omlx_defer_below_bytes": 3,
                "memory_omlx_resume_above_bytes": 4,
            }
            env = manage.backend_env(config)
            self.assertEqual(config["desec_token"], "placeholder-token")
            self.assertEqual(config["whisper_model"], "/models/whisper-large-v3-mlx")
            self.assertEqual(env["PODS_WHISPER_MODEL"], "/models/whisper-large-v3-mlx")
            self.assertEqual(env["PODS_MEMORY_GATE"], "0")
            self.assertEqual(env["PODS_MEMORY_GATE_NOTIFY"], "1")
            self.assertEqual(env["PODS_MEMORY_WHISPER_DEFER_BELOW_BYTES"], "1")
            self.assertEqual(env["PODS_MEMORY_WHISPER_RESUME_ABOVE_BYTES"], "2")
            self.assertEqual(env["PODS_MEMORY_OMLX_DEFER_BELOW_BYTES"], "3")
            self.assertEqual(env["PODS_MEMORY_OMLX_RESUME_ABOVE_BYTES"], "4")
            memory_env = {key: env[key] for key in env if key.startswith("PODS_MEMORY")}
            self.assertNotIn("placeholder-token", str(memory_env))

    def test_launch_starts_the_release_backend_binary(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(manage, "STATE", Path(directory)):
            current = Path(directory) / "current"
            current.mkdir()
            (current / "pods-backend").write_text("")
            (Path(directory) / "data").mkdir()
            with patch.object(manage, "read_config", return_value={"whisper_model": "/models/w"}), \
                 patch.object(manage, "wifi_address", return_value=None), \
                 patch.object(manage.signal, "signal"), \
                 patch.object(manage, "stop_process"), \
                 patch.object(manage.subprocess, "Popen") as popen, \
                 patch.object(manage.time, "sleep", side_effect=KeyboardInterrupt):
                process = unittest.mock.Mock()
                process.poll.return_value = None
                process.pid = 99
                popen.return_value = process
                with self.assertRaises(KeyboardInterrupt):
                    manage.launch()
                argv = popen.call_args[0][0]
                self.assertEqual(argv[0], str(current.resolve() / "pods-backend"))
                self.assertEqual(argv[1], str(Path(directory) / "data/pods.sqlite"))

    def test_launch_ticks_omlx_autostart(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(manage, "STATE", Path(directory)):
            current = Path(directory) / "current"
            current.mkdir()
            (current / "pods-backend").write_text("")
            (Path(directory) / "data").mkdir()
            with patch.object(manage, "read_config", return_value={"whisper_model": "/models/w"}), \
                 patch.object(manage, "wifi_address", return_value=None), \
                 patch.object(manage.signal, "signal"), \
                 patch.object(manage, "stop_process"), \
                 patch.object(manage.subprocess, "Popen") as popen, \
                 patch.object(manage, "maybe_start_omlx") as tick, \
                 patch.object(manage.time, "sleep", side_effect=KeyboardInterrupt):
                process = unittest.mock.Mock()
                process.poll.return_value = None
                process.pid = 99
                popen.return_value = process
                with self.assertRaises(KeyboardInterrupt):
                    manage.launch()
                tick.assert_called()
                self.assertTrue(tick.call_args.args[0].get("omlx_autostart") in (None, False))

    def test_omlx_autostart_is_off_by_default(self):
        self.assertFalse(manage.omlx_autostart_enabled({}))
        self.assertFalse(manage.omlx_autostart_enabled({"omlx_autostart": False}))
        self.assertFalse(manage.omlx_autostart_enabled({"omlx_autostart": 0}))
        self.assertFalse(manage.omlx_autostart_enabled({"omlx_autostart": "0"}))
        self.assertTrue(manage.omlx_autostart_enabled({"omlx_autostart": True}))

    def test_omlx_tcp_up_detects_loopback_listener(self):
        with socket.create_server(("127.0.0.1", 0)) as listener:
            host, port = listener.getsockname()[:2]
            with patch.object(manage, "OMLX_LOOPBACK", (host, port)):
                self.assertTrue(manage.omlx_tcp_up(timeout=0.2))
        with patch.object(manage, "OMLX_LOOPBACK", (host, port)):
            self.assertFalse(manage.omlx_tcp_up(timeout=0.2))

    def test_omlx_has_pending_inference_ignores_idle_and_ineligible_rows(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "pods.sqlite"
            with processing_db(path) as db:
                db.execute("INSERT INTO podcasts(id,feed_url,title,is_subscribed) VALUES(1,'https://a.example/feed','A',1),(2,'https://b.example/feed','B',0)")
                add_episode(db, 1, 1, "queued")
                add_episode(db, 2, 1, "transcribing", stage="transcribing")
                add_episode(db, 3, 1, "ready", stage="ready")
                add_episode(db, 4, 1, "blocked", stage="blocked", error="omlx_busy")
                add_episode(db, 5, 1, "played", stage="classifying", error="omlx_busy")
                add_episode(db, 6, 2, "unsubscribed", stage="classifying", error="omlx_busy")
                db.execute("INSERT INTO episode_state(episode_id,played_at,updated_at) VALUES(5,123,123)")
                db.commit()
                self.assertFalse(manage.omlx_has_pending_inference(path))
                add_episode(db, 7, 1, "classifying", stage="classifying", error="omlx_busy")
                db.commit()
                self.assertTrue(manage.omlx_has_pending_inference(path))
                db.execute("UPDATE browser_jobs SET error='memory_busy' WHERE episode_id=7")
                db.commit()
                self.assertFalse(manage.omlx_has_pending_inference(path))
                db.execute("UPDATE browser_jobs SET error='omlx_busy' WHERE episode_id=7")
                db.commit()
                self.assertTrue(manage.omlx_has_pending_inference(path))
            self.assertFalse(manage.omlx_has_pending_inference(Path(directory) / "missing.sqlite"))

    def test_omlx_cli_prefers_app_cli_over_homebrew_path(self):
        with tempfile.TemporaryDirectory() as directory:
            brew_dir = Path(directory) / "opt/homebrew/bin"
            brew_dir.mkdir(parents=True)
            brew = brew_dir / "omlx"
            brew.write_text("#!/bin/sh\necho brew\n")
            os.chmod(brew, 0o755)
            app = Path(directory) / "oMLX.app/Contents/MacOS/omlx-cli"
            app.parent.mkdir(parents=True)
            app.write_text("#!/bin/sh\nexit 0\n")
            os.chmod(app, 0o755)
            missing = Path(directory) / "missing-omlx"
            with patch.object(manage, "OMLX_APP_CLI", app), \
                 patch.object(manage, "omlx_user_cli", return_value=missing), \
                 patch.object(manage, "PATH", str(brew_dir)):
                self.assertEqual(manage.omlx_cli(), str(app))
            with patch.object(manage, "OMLX_APP_CLI", missing), \
                 patch.object(manage, "omlx_user_cli", return_value=missing), \
                 patch.object(manage, "PATH", str(brew_dir)):
                self.assertIsNone(manage.omlx_cli())
                self.assertTrue(brew.is_file())

    def test_request_omlx_start_uses_no_wait_and_keeps_secrets_off_argv(self):
        process = unittest.mock.Mock()
        process.poll.return_value = 0
        process.returncode = 0
        with patch.object(manage.subprocess, "Popen", return_value=process) as popen:
            manage.request_omlx_start("/Applications/oMLX.app/Contents/MacOS/omlx-cli")
            argv = popen.call_args[0][0]
            self.assertEqual(argv, ["/Applications/oMLX.app/Contents/MacOS/omlx-cli", "start", "--no-wait"])
            self.assertIs(popen.call_args.kwargs["stdout"], subprocess.DEVNULL)
            self.assertIsNot(popen.call_args.kwargs["stderr"], subprocess.PIPE)
            self.assertNotIn("start-key", " ".join(argv))
            joined = " ".join(argv)
            self.assertNotIn("omlx_key", joined.lower())

    def test_request_omlx_start_rejects_fast_nonzero_exit(self):
        with tempfile.TemporaryDirectory() as directory:
            cli = Path(directory) / "omlx-cli"
            cli.write_text("#!/bin/sh\necho unrecognized arguments: --no-wait >&2\nexit 2\n")
            os.chmod(cli, 0o755)
            stderr = io.StringIO()
            with patch.object(manage, "OMLX_FAST_FAIL_SECS", 5), \
                 contextlib.redirect_stderr(stderr), self.assertRaises(OSError):
                manage.request_omlx_start(str(cli))
            self.assertIn("unrecognized arguments", stderr.getvalue())
            self.assertNotIn("start-key", stderr.getvalue())

    def test_request_omlx_start_replaces_invalid_stderr_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            cli = Path(directory) / "omlx-cli"
            cli.write_bytes(b"#!/bin/sh\nprintf '\\xff\\xfe bad\\n' >&2\nexit 2\n")
            os.chmod(cli, 0o755)
            stderr = io.StringIO()
            with patch.object(manage, "OMLX_FAST_FAIL_SECS", 5), \
                 contextlib.redirect_stderr(stderr), self.assertRaises(OSError):
                manage.request_omlx_start(str(cli))
            self.assertIn("bad", stderr.getvalue())

    def test_request_omlx_start_leaves_slow_cli_running(self):
        process = unittest.mock.Mock()
        process.poll.return_value = None
        with patch.object(manage, "OMLX_FAST_FAIL_SECS", 0), \
             patch.object(manage.subprocess, "Popen", return_value=process) as popen:
            manage.request_omlx_start("/Applications/oMLX.app/Contents/MacOS/omlx-cli")
            process.communicate.assert_not_called()
            self.assertIs(popen.call_args.kwargs["stdout"], subprocess.DEVNULL)
            self.assertIsNot(popen.call_args.kwargs["stderr"], subprocess.PIPE)

    def test_maybe_start_omlx_requests_start_after_grace_and_respects_interval(self):
        config = {"omlx_autostart": True}
        state = manage.omlx_autostart_state()
        with tempfile.TemporaryDirectory() as directory, patch.object(manage, "STATE", Path(directory)), \
             patch.object(manage, "omlx_tcp_up", return_value=False), \
             patch.object(manage, "omlx_cli", return_value="/tmp/omlx"), \
             patch.object(manage, "omlx_has_pending_inference", return_value=True), \
             patch.object(manage, "request_omlx_start") as start, \
             patch.object(manage, "post_notification") as notify:
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                manage.maybe_start_omlx(config, 100, state)
                self.assertEqual(state["down_since"], 100)
                start.assert_not_called()
                manage.maybe_start_omlx(config, 159, state)
                start.assert_not_called()
                manage.maybe_start_omlx(config, 160, state)
                start.assert_called_once_with("/tmp/omlx")
                notify.assert_called_once_with("oMLX start requested")
                manage.maybe_start_omlx(config, 160 + manage.OMLX_START_INTERVAL_SECS - 1, state)
                start.assert_called_once()
                manage.maybe_start_omlx(config, 160 + manage.OMLX_START_INTERVAL_SECS, state)
                self.assertEqual(start.call_count, 2)
            self.assertIn("requested start", stderr.getvalue())
            self.assertNotIn("start-key", stderr.getvalue())

    def test_maybe_start_omlx_skips_live_server_idle_queue_and_disabled_config(self):
        state = manage.omlx_autostart_state()
        with patch.object(manage, "omlx_tcp_up", return_value=True) as tcp, \
             patch.object(manage, "request_omlx_start") as start:
            manage.maybe_start_omlx({}, 50, state)
            tcp.assert_not_called()
            start.assert_not_called()
            manage.maybe_start_omlx({"omlx_autostart": True}, 50, state)
            self.assertIsNone(state["down_since"])
            start.assert_not_called()
        state = manage.omlx_autostart_state()
        with patch.object(manage, "omlx_tcp_up", return_value=False), \
             patch.object(manage, "omlx_cli", return_value="/tmp/omlx"), \
             patch.object(manage, "omlx_has_pending_inference", return_value=False), \
             patch.object(manage, "request_omlx_start") as start:
            manage.maybe_start_omlx({"omlx_autostart": True}, 1, state)
            manage.maybe_start_omlx({"omlx_autostart": True}, 1 + manage.OMLX_DOWN_GRACE_SECS, state)
            start.assert_not_called()
            self.assertEqual(state["next_start_at"], 0)

    def test_maybe_start_omlx_logs_missing_cli_once(self):
        config = {"omlx_autostart": True}
        state = manage.omlx_autostart_state()
        with patch.object(manage, "omlx_tcp_up", return_value=False), \
             patch.object(manage, "omlx_cli", return_value=None), \
             patch.object(manage, "omlx_has_pending_inference", return_value=True), \
             patch.object(manage, "request_omlx_start") as start:
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                manage.maybe_start_omlx(config, 1, state)
                manage.maybe_start_omlx(config, 1 + manage.OMLX_DOWN_GRACE_SECS, state)
                manage.maybe_start_omlx(config, 1 + manage.OMLX_DOWN_GRACE_SECS + 5, state)
            self.assertEqual(stderr.getvalue().count("oMLX CLI was not found; will look again later."), 1)
            start.assert_not_called()

    def test_maybe_start_omlx_notifies_failure_and_applies_interval(self):
        config = {"omlx_autostart": True}
        state = manage.omlx_autostart_state()
        with patch.object(manage, "omlx_tcp_up", return_value=False), \
             patch.object(manage, "omlx_cli", return_value="/tmp/omlx"), \
             patch.object(manage, "omlx_has_pending_inference", return_value=True), \
             patch.object(manage, "request_omlx_start", side_effect=OSError("exec")), \
             patch.object(manage, "post_notification") as notify:
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                manage.maybe_start_omlx(config, 1, state)
                manage.maybe_start_omlx(config, 1 + manage.OMLX_DOWN_GRACE_SECS, state)
            notify.assert_called_once_with("oMLX start failed")
            self.assertEqual(state["next_start_at"], 1 + manage.OMLX_DOWN_GRACE_SECS + manage.OMLX_START_INTERVAL_SECS)
            self.assertIn("oMLX start failed", stderr.getvalue())

    def test_maybe_start_omlx_sets_interval_when_notification_fails(self):
        config = {"omlx_autostart": True}
        state = manage.omlx_autostart_state()
        with patch.object(manage, "omlx_tcp_up", return_value=False), \
             patch.object(manage, "omlx_cli", return_value="/tmp/omlx"), \
             patch.object(manage, "omlx_has_pending_inference", return_value=True), \
             patch.object(manage, "request_omlx_start"), \
             patch.object(manage, "post_notification", side_effect=OSError("notify")):
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                manage.maybe_start_omlx(config, 1, state)
                manage.maybe_start_omlx(config, 1 + manage.OMLX_DOWN_GRACE_SECS, state)
            self.assertEqual(state["next_start_at"], 1 + manage.OMLX_DOWN_GRACE_SECS + manage.OMLX_START_INTERVAL_SECS)
            self.assertIn("requested start", stderr.getvalue())

    def test_maybe_start_omlx_applies_interval_on_any_start_error(self):
        config = {"omlx_autostart": True}
        state = manage.omlx_autostart_state()
        error = UnicodeDecodeError("utf-8", b"\xff", 0, 1, "invalid")
        with patch.object(manage, "omlx_tcp_up", return_value=False), \
             patch.object(manage, "omlx_cli", return_value="/tmp/omlx"), \
             patch.object(manage, "omlx_has_pending_inference", return_value=True), \
             patch.object(manage, "request_omlx_start", side_effect=error), \
             patch.object(manage, "post_notification") as notify:
            manage.maybe_start_omlx(config, 1, state)
            manage.maybe_start_omlx(config, 1 + manage.OMLX_DOWN_GRACE_SECS, state)
            notify.assert_called_once_with("oMLX start failed")
            self.assertEqual(state["next_start_at"], 1 + manage.OMLX_DOWN_GRACE_SECS + manage.OMLX_START_INTERVAL_SECS)
