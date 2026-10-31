import importlib.util
import os
import pathlib
import re
import signal
import subprocess
import sys
import time
import unittest
import hashlib
import io
import tempfile
import json
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("local_model_runner", ROOT / "LocalModelRunner.py")
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)


class RunnerTests(unittest.TestCase):
    def test_all_repositories_have_pinned_full_revisions(self):
        for repo, revision in [*RUNNER.SPEECH.values(), *RUNNER.CLEANUP.values()]:
            self.assertTrue(repo.startswith("mlx-community/"))
            self.assertEqual(len(revision), 40)

    def test_integrity_manifest_matches_every_supported_repository_revision(self):
        manifest = json.loads((ROOT / "model-integrity-manifest.json").read_text())
        expected = {**RUNNER.SPEECH, **RUNNER.CLEANUP}
        self.assertEqual(set(manifest["models"]), set(expected))
        for model_id, (repo, revision) in expected.items():
            entry = manifest["models"][model_id]
            self.assertEqual((entry["repo"], entry["revision"]), (repo, revision))
            self.assertTrue(entry["files"])
            for record in entry["files"].values():
                self.assertEqual(len(record["sha256"]), 64)
                self.assertGreater(record["size_bytes"], 0)

    def test_models_are_allowlisted_and_no_remote_code_is_allowed(self):
        self.assertEqual(len(RUNNER.SPEECH), 3)
        self.assertEqual(len(RUNNER.CLEANUP), 2)
        self.assertNotIn("*.py", RUNNER.SAFE_MODEL_PATTERNS)

    def test_integrity_verifier_detects_tampering_and_inventory_changes(self):
        from ModelIntegrity import MAX_MODEL_TREE_ENTRIES, ModelIntegrityError, verify_model
        with tempfile.TemporaryDirectory() as temporary:
            base = pathlib.Path(temporary)
            root = base / "models"
            model = root / "mlx-community" / "demo"
            model.mkdir(parents=True)
            payload = b"trusted-model"
            weight = model / "weights.npz"
            weight.write_bytes(payload)
            entry = {
                "repo": "mlx-community/demo",
                "revision": "1" * 40,
                "files": {"weights.npz": {"size_bytes": len(payload), "sha256": hashlib.sha256(payload).hexdigest()}},
            }
            manifest = base / "manifest.json"

            def write_manifest():
                manifest.write_text(json.dumps({"schema_version": 1, "models": {"demo": entry}}))

            def verify():
                return verify_model("demo", "mlx-community/demo", "1" * 40, root, ["*.npz", "*.json"], manifest_path=manifest, home=base / "home")

            write_manifest()
            self.assertTrue(verify())
            weight.write_bytes(b"tampered-model")
            with self.assertRaises(ModelIntegrityError):
                verify()
            weight.write_bytes(payload)
            (model / "extra.json").write_text("{}")
            with self.assertRaises(ModelIntegrityError):
                verify()
            (model / "extra.json").unlink()
            weight.unlink()
            with self.assertRaises(ModelIntegrityError):
                verify()
            weight.write_bytes(payload)
            entry["files"]["weights.npz"]["size_bytes"] += 1
            write_manifest()
            with self.assertRaises(ModelIntegrityError):
                verify()

            entry["files"]["weights.npz"]["size_bytes"] = len(payload)
            write_manifest()
            for index in range(MAX_MODEL_TREE_ENTRIES + 1):
                (model / f"ignored-{index}.data").touch()
            with self.assertRaisesRegex(ModelIntegrityError, "too many entries"):
                verify()

    def test_integrity_read_stops_when_file_grows_past_manifest_size(self):
        import ModelIntegrity
        from ModelIntegrity import ModelIntegrityError
        with tempfile.TemporaryDirectory() as temporary:
            path = pathlib.Path(temporary) / "weights.npz"
            payload = b"1234"
            path.write_bytes(payload)
            real_fstat = os.fstat
            calls = 0

            def append_after_initial_stat(fd):
                nonlocal calls
                result = real_fstat(fd)
                if calls == 0:
                    with path.open("ab") as stream:
                        stream.write(b"x")
                calls += 1
                return result

            with mock.patch.object(ModelIntegrity.os, "fstat", side_effect=append_after_initial_stat), mock.patch.object(ModelIntegrity, "CHUNK_SIZE", 2):
                with self.assertRaisesRegex(ModelIntegrityError, "grew beyond"):
                    ModelIntegrity._hash_file_no_follow(path, path.parent, len(payload))

    def test_integrity_verifier_rejects_path_escape_and_accepts_pinned_hub_symlink(self):
        from ModelIntegrity import ModelIntegrityError, verify_model
        with tempfile.TemporaryDirectory() as temporary:
            base = pathlib.Path(temporary)
            home = base / "home"
            root = base / "models"
            model = root / "mlx-community" / "demo"
            model.mkdir(parents=True)
            payload = b"trusted-model"
            digest = hashlib.sha256(payload).hexdigest()
            manifest = base / "manifest.json"
            manifest.write_text(json.dumps({"schema_version": 1, "models": {"demo": {
                "repo": "mlx-community/demo", "revision": "1" * 40,
                "files": {"weights.npz": {"size_bytes": len(payload), "sha256": digest}},
            }}}))
            outside = base / "outside.npz"
            outside.write_bytes(payload)
            (model / "weights.npz").symlink_to(outside)
            with self.assertRaises(ModelIntegrityError):
                verify_model("demo", "mlx-community/demo", "1" * 40, root, ["*.npz"], manifest_path=manifest, home=home)
            (model / "weights.npz").unlink()
            snapshot = home / ".cache/huggingface/hub/models--mlx-community--demo/snapshots" / ("1" * 40)
            snapshot.mkdir(parents=True)
            (snapshot / "weights.npz").write_bytes(payload)
            (model / "weights.npz").symlink_to(snapshot / "weights.npz")
            self.assertTrue(verify_model("demo", "mlx-community/demo", "1" * 40, root, ["*.npz"], manifest_path=manifest, home=home))

    def test_install_and_both_inference_paths_require_integrity_verification(self):
        events = []
        calls = []
        fake_hub = type("FakeHub", (), {"snapshot_download": staticmethod(lambda **kwargs: (events.append("download"), calls.append(kwargs)))})
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary) / "models"
            runtime = pathlib.Path(temporary) / "runtime"
            python = RUNNER.runtime_python(runtime)
            python.parent.mkdir(parents=True)
            python.touch()
            with mock.patch.dict(sys.modules, {"huggingface_hub": fake_hub}), mock.patch.object(RUNNER, "verify_model", side_effect=lambda *args: events.append("verify")):
                RUNNER.install_model(runtime, root, "whisper-tiny-en")
                self.assertEqual(events, ["download", "verify"])
                self.assertIs(calls[0]["token"], False)
                self.assertEqual(calls[0]["revision"], RUNNER.SPEECH["whisper-tiny-en"][1])
                self.assertEqual(calls[0]["repo_id"], RUNNER.SPEECH["whisper-tiny-en"][0])

            audio = pathlib.Path(temporary) / "audio.wav"
            audio.touch()
            speech_model_path = root / RUNNER.SPEECH["whisper-tiny-en"][0]
            speech_model_path.mkdir(parents=True)
            cleanup_model_path = root / RUNNER.CLEANUP["qwen3-0.6b"][0]
            cleanup_model_path.mkdir(parents=True)
            events.clear()
            fake_speech = type("FakeSpeech", (), {"transcribe": staticmethod(lambda *args, **kwargs: (events.append("speech-load") or {"text": "ok"}))})
            fake_soundfile = type("FakeSoundFile", (), {"read": staticmethod(lambda *args, **kwargs: ([], 16000))})
            with mock.patch.dict(sys.modules, {"mlx_whisper": fake_speech, "soundfile": fake_soundfile}), mock.patch.object(RUNNER, "verify_model", side_effect=lambda *args: events.append("verify")):
                RUNNER.transcribe(runtime, root, "whisper-tiny-en", audio)
            self.assertEqual(events, ["verify", "speech-load"])

            events.clear()
            tokenizer = type("FakeTokenizer", (), {"apply_chat_template": staticmethod(lambda *args, **kwargs: "prompt")})()
            fake_mlx = type("FakeMLX", (), {
                "load": staticmethod(lambda *args, **kwargs: (events.append("cleanup-load") or (object(), tokenizer))),
                "generate": staticmethod(lambda *args, **kwargs: "ok"),
            })
            with mock.patch.dict(sys.modules, {"mlx_lm": fake_mlx}), mock.patch.object(RUNNER, "verify_model", side_effect=lambda *args: events.append("verify")), mock.patch("sys.stdin", io.StringIO('{"text":"hello"}')):
                RUNNER.cleanup(runtime, root, "qwen3-0.6b")
            self.assertEqual(events, ["verify", "cleanup-load"])

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
