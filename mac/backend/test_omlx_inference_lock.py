#!/usr/bin/env python3
"""Tests for the cooperative oMLX lock wrapper. These tests never call oMLX."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

import omlx_inference_lock as lock


WRAPPER = Path(__file__).resolve().parent / "omlx_inference_lock.py"


def run_wrapper(lock_dir, extra, timeout=5):
    env = os.environ.copy()
    env["PODS_OMLX_LOCK_DIR"] = str(lock_dir)
    env.pop("PODS_OMLX_LOCK", None)
    return subprocess.run(
        [sys.executable, str(WRAPPER), "--lock-dir", str(lock_dir), *extra],
        capture_output=True,
        text=True,
        timeout=timeout,
        env=env,
    )


def wait_for_holder(lock_dir, proc, timeout=2):
    meta = Path(lock_dir) / lock.METADATA_FILE_NAME
    deadline = time.time() + timeout
    while time.time() < deadline:
        if proc.poll() is not None:
            return False
        if meta.is_file():
            return True
        time.sleep(0.05)
    return False


class WrapperTests(unittest.TestCase):
    def test_argument_preservation(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory) / "args.json"
            result = run_wrapper(directory, [
                "--", sys.executable, "-c",
                "import json,sys; json.dump(sys.argv[1:], open(sys.argv[1],'w'))",
                str(out), "a b", "--flag", "$USER",
            ])
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(out.read_text()), [str(out), "a b", "--flag", "$USER"])

    def test_mutual_exclusion(self):
        with tempfile.TemporaryDirectory() as directory:
            holder = subprocess.Popen(
                [sys.executable, str(WRAPPER), "--lock-dir", directory, "--owner", "script",
                 "--purpose", "chat", "--model", "unspecified", "--",
                 sys.executable, "-c", "import time; time.sleep(20)"],
            )
            try:
                self.assertTrue(wait_for_holder(directory, holder), "holder never acquired the lock")
                check = run_wrapper(directory, ["--check"])
                self.assertEqual(check.returncode, lock.EX_TEMPFAIL)
                self.assertIn("busy", check.stdout)
                second = run_wrapper(directory, ["--", sys.executable, "-c", "print('nope')"])
                self.assertEqual(second.returncode, lock.EX_TEMPFAIL)
                self.assertIn("omlx_busy", second.stderr)
            finally:
                holder.kill()
                holder.wait(timeout=5)

    def test_release_removes_own_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            result = run_wrapper(directory, ["--", sys.executable, "-c", "print('ok')"])
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((Path(directory) / lock.METADATA_FILE_NAME).exists())
            self.assertTrue((Path(directory) / lock.LOCK_FILE_NAME).exists())

    def test_exit_code_propagation(self):
        with tempfile.TemporaryDirectory() as directory:
            result = run_wrapper(directory, ["--", sys.executable, "-c", "import sys; sys.exit(3)"])
            self.assertEqual(result.returncode, 3)

    def test_crash_release_without_omlx(self):
        with tempfile.TemporaryDirectory() as directory:
            holder = subprocess.Popen(
                [sys.executable, str(WRAPPER), "--lock-dir", directory, "--",
                 sys.executable, "-c", "import time; time.sleep(30)"],
            )
            if not wait_for_holder(directory, holder):
                holder.kill()
                holder.wait(timeout=5)
                self.fail("holder never acquired the lock")
            os.kill(holder.pid, signal.SIGKILL)
            holder.wait(timeout=5)
            deadline = time.time() + 2
            while time.time() < deadline:
                check = run_wrapper(directory, ["--check"])
                if check.returncode == 0:
                    break
                time.sleep(0.05)
            self.assertEqual(check.returncode, 0, check.stdout + check.stderr)
            self.assertIn("available", check.stdout)
            follow = run_wrapper(directory, ["--", sys.executable, "-c", "print('ok')"])
            self.assertEqual(follow.returncode, 0, follow.stderr)

    def test_metadata_redaction(self):
        with tempfile.TemporaryDirectory() as directory:
            holder = subprocess.Popen(
                [sys.executable, str(WRAPPER), "--lock-dir", directory,
                 "--owner", "pi", "--purpose", "chat", "--model", "unspecified", "--",
                 sys.executable, "-c", "import time; time.sleep(20)"],
            )
            try:
                path = Path(directory) / lock.METADATA_FILE_NAME
                deadline = time.time() + 2
                while time.time() < deadline and not path.is_file():
                    time.sleep(0.05)
                body = json.loads(path.read_text())
                self.assertEqual(set(body), set(lock.METADATA_FIELDS))
                self.assertEqual(body["owner"], "pi")
                raw = path.read_text()
                self.assertNotIn("http", raw)
                self.assertNotIn("sk-", raw)
                self.assertNotIn("prompt", raw)
            finally:
                holder.kill()
                holder.wait(timeout=5)

    def test_check_does_not_write_or_steal_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            check = run_wrapper(directory, ["--check"])
            self.assertEqual(check.returncode, 0)
            self.assertIn("available", check.stdout)
            self.assertFalse((Path(directory) / lock.METADATA_FILE_NAME).exists())
            holder = subprocess.Popen(
                [sys.executable, str(WRAPPER), "--lock-dir", directory,
                 "--owner", "pi", "--purpose", "chat", "--model", "unspecified", "--",
                 sys.executable, "-c", "import time; time.sleep(20)"],
            )
            try:
                self.assertTrue(wait_for_holder(directory, holder))
                before = (Path(directory) / lock.METADATA_FILE_NAME).read_text()
                busy = run_wrapper(directory, ["--check"])
                self.assertEqual(busy.returncode, lock.EX_TEMPFAIL)
                self.assertEqual((Path(directory) / lock.METADATA_FILE_NAME).read_text(), before)
                self.assertIn('"owner": "pi"', busy.stdout)
            finally:
                holder.kill()
                holder.wait(timeout=5)

    def test_signal_exit_code(self):
        with tempfile.TemporaryDirectory() as directory:
            result = run_wrapper(directory, [
                "--", sys.executable, "-c",
                "import os,signal; os.kill(os.getpid(), signal.SIGKILL)",
            ], timeout=5)
            self.assertEqual(result.returncode, 128 + signal.SIGKILL)

    def test_does_not_read_credentials(self):
        source = Path(lock.__file__).read_text()
        self.assertNotIn("models.json", source)
        self.assertNotIn("PODS_OMLX_KEY", source)
        self.assertNotIn("apiKey", source)
        self.assertNotIn("Authorization", source)


if __name__ == "__main__":
    unittest.main()
