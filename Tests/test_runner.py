import importlib.util
import os
import pathlib
import re
import signal
import subprocess
import sys
import time
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("local_model_runner", ROOT / "LocalModelRunner.py")
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)


class RunnerTests(unittest.TestCase):
    def test_all_repositories_have_pinned_full_revisions(self):
        for repo, revision in [*RUNNER.SPEECH.values(), *RUNNER.CLEANUP.values()]:
            self.assertTrue(repo.startswith("mlx-community/"))
            self.assertEqual(len(revision), 40)

    def test_models_are_allowlisted_and_no_remote_code_is_allowed(self):
        self.assertEqual(len(RUNNER.SPEECH), 3)
        self.assertEqual(len(RUNNER.CLEANUP), 2)
        self.assertNotIn("*.py", RUNNER.SAFE_MODEL_PATTERNS)

    def test_unknown_models_are_rejected_before_downloading(self):
        with self.assertRaises(ValueError):
            RUNNER.install_model("/missing", "/tmp/models", "not-a-model")

    def test_mac_arm_python312_runtime_profiles_are_hashed_and_compatible(self):
        def locked_packages(path):
            lines = path.read_text().splitlines()
            package_lines = [(i, re.match(r"^([A-Za-z0-9_.-]+)==([0-9][^ ]*)", line)) for i, line in enumerate(lines)]
            package_lines = [(i, match) for i, match in package_lines if match]
            self.assertTrue(package_lines)
            packages = {}
            for position, (index, match) in enumerate(package_lines):
                end = package_lines[position + 1][0] if position + 1 < len(package_lines) else len(lines)
                block = "\n".join(lines[index:end])
                self.assertIn("--hash=sha256:", block, match.group(1))
                packages[match.group(1).lower().replace("_", "-")] = match.group(2)
            return packages

        speech = locked_packages(RUNNER.PROFILE_LOCKS["speech"])
        cleanup = locked_packages(RUNNER.PROFILE_LOCKS["cleanup"])
        self.assertEqual(speech["mlx-whisper"], "0.4.3")
        self.assertEqual(speech["torch"], "2.15.0")
        self.assertEqual(cleanup["mlx-lm"], "0.31.2")
        self.assertEqual(cleanup["transformers"], "5.22.1")
        self.assertNotIn("torch", cleanup)
        shared = speech.keys() & cleanup.keys()
        self.assertEqual({name: (speech[name], cleanup[name]) for name in shared if speech[name] != cleanup[name]}, {})

    def test_cancellation_terminates_and_reaps_installer_child_group(self):
        harness = (
            "import sys;sys.path.insert(0,sys.argv[1]);import LocalModelRunner as m,subprocess;"
            "real=subprocess.Popen;"
            "subprocess.Popen=lambda *a,**k:(p:=real(*a,**k),print(p.pid,flush=True))[0];"
            "m.run_cancellable(['/usr/bin/python3','-c','import time;time.sleep(60)'])"
        )
        parent = subprocess.Popen([sys.executable, "-c", harness, str(ROOT)], stdout=subprocess.PIPE, text=True)
        self.assertIsNotNone(parent.stdout)
        child_pid = int(parent.stdout.readline().strip())
        parent.send_signal(signal.SIGTERM)
        self.assertEqual(parent.wait(timeout=5), 130)
        parent.stdout.close()
        deadline = time.monotonic() + 1
        while time.monotonic() < deadline:
            try:
                os.killpg(child_pid, 0)
            except ProcessLookupError:
                break
            time.sleep(0.01)
        else:
            self.fail("installer child process group survived cancellation")


if __name__ == "__main__":
    unittest.main()
