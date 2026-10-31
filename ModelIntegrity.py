"""Verify pinned local model files before inference without trusting file metadata."""

import fnmatch
import hashlib
import json
import os
import pathlib
import stat


CHUNK_SIZE = 1024 * 1024
MAX_MODEL_FILE_SIZE = 2_000_000_000
MAX_MODEL_TREE_ENTRIES = 256
MANIFEST_PATH = pathlib.Path(__file__).resolve().with_name("model-integrity-manifest.json")


class ModelIntegrityError(RuntimeError):
    pass


def _inside(path, parent):
    try:
        path.relative_to(parent)
        return True
    except ValueError:
        return False


def _cache_repo_root(repo, home=None):
    home_path = pathlib.Path(home or pathlib.Path.home()).resolve()
    cache_root = home_path / ".cache" / "huggingface" / "hub"
    repo_cache = "models--" + repo.replace("/", "--")
    return cache_root / repo_cache


def _manifest_entry(model_id, repo, revision, manifest_path=None):
    path = pathlib.Path(manifest_path or MANIFEST_PATH)
    try:
        manifest = json.loads(path.read_text(encoding="utf-8"))
        if manifest.get("schema_version") != 1:
            raise ModelIntegrityError("Unsupported model integrity manifest version.")
        entry = manifest["models"][model_id]
    except ModelIntegrityError:
        raise
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise ModelIntegrityError("The pinned model integrity manifest is missing or invalid.") from error
    if entry.get("repo") != repo or entry.get("revision") != revision:
        raise ModelIntegrityError("The model integrity manifest does not match the selected pinned revision.")
    files = entry.get("files")
    if not isinstance(files, dict) or not files:
        raise ModelIntegrityError("The model integrity manifest has no file entries.")
    return files


def _expected_relpath(raw):
    rel = pathlib.PurePosixPath(raw)
    if rel.is_absolute() or not rel.parts or any(part in ("", ".", "..") for part in rel.parts) or "\\" in raw:
        raise ModelIntegrityError("The model integrity manifest contains an unsafe path.")
    return rel


def _allowed_root_for(target, roots):
    for root in roots:
        if _inside(target, root):
            return root
    raise ModelIntegrityError("A model file resolves outside the selected model cache and pinned snapshot.")


def _hash_file_no_follow(target, allowed_root, expected_size):
    relative = target.relative_to(allowed_root)
    flags_dir = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    flags_file = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    directory_fd = os.open(allowed_root, flags_dir)
    try:
        for component in relative.parts[:-1]:
            next_fd = os.open(component, flags_dir, dir_fd=directory_fd)
            os.close(directory_fd)
            directory_fd = next_fd
        file_fd = os.open(relative.parts[-1], flags_file, dir_fd=directory_fd)
    except OSError as error:
        raise ModelIntegrityError("A model file could not be opened safely.") from error
    finally:
        os.close(directory_fd)

    try:
        before = os.fstat(file_fd)
        if not stat.S_ISREG(before.st_mode) or before.st_size != expected_size or before.st_size > MAX_MODEL_FILE_SIZE:
            raise ModelIntegrityError("A model file has an unexpected type or size.")
        digest = hashlib.sha256()
        total_read = 0
        with os.fdopen(file_fd, "rb", closefd=False) as stream:
            while True:
                remaining = expected_size - total_read
                block = stream.read(min(CHUNK_SIZE, remaining + 1))
                if not block:
                    break
                if len(block) > remaining or total_read + len(block) > MAX_MODEL_FILE_SIZE:
                    raise ModelIntegrityError("A model file grew beyond its pinned size while being verified.")
                total_read += len(block)
                digest.update(block)
        after = os.fstat(file_fd)
        if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (
            after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns
        ):
            raise ModelIntegrityError("A model file changed while it was being verified.")
        return digest.hexdigest()
    finally:
        os.close(file_fd)


def verify_model(model_id, repo, revision, root, safe_patterns, manifest_path=None, home=None):
    """Hash every selected artifact on each model process start; never trust stat-only cache state."""
    files = _manifest_entry(model_id, repo, revision, manifest_path)
    root_path = pathlib.Path(root).expanduser().resolve(strict=True)
    model_path = root_path.joinpath(*pathlib.PurePosixPath(repo).parts)
    try:
        model_real = model_path.resolve(strict=True)
    except OSError as error:
        raise ModelIntegrityError("The selected model directory is missing.") from error
    cache_repo_root = _cache_repo_root(repo, home=home).resolve()
    _allowed_root_for(model_real, [root_path, cache_repo_root])
    if not model_real.is_dir():
        raise ModelIntegrityError("The selected model path is not a directory.")

    expected_paths = set()
    for raw_path in files:
        rel = _expected_relpath(raw_path)
        expected_paths.add(rel.as_posix())
        if not any(fnmatch.fnmatchcase(rel.as_posix(), pattern) for pattern in safe_patterns):
            raise ModelIntegrityError("The model integrity manifest contains a file outside the safe file allowlist.")

    actual_paths = set()
    scanned_entries = 0
    for current, dirs, names in os.walk(model_real, followlinks=False):
        current_path = pathlib.Path(current)
        for name in list(dirs):
            scanned_entries += 1
            if scanned_entries > MAX_MODEL_TREE_ENTRIES:
                raise ModelIntegrityError("The model directory contains too many entries to verify safely.")
            directory = current_path / name
            if directory.is_symlink():
                raise ModelIntegrityError("A model directory contains an unexpected directory symlink.")
        for name in names:
            scanned_entries += 1
            if scanned_entries > MAX_MODEL_TREE_ENTRIES:
                raise ModelIntegrityError("The model directory contains too many entries to verify safely.")
            candidate = current_path / name
            relative = candidate.relative_to(model_real).as_posix()
            if any(fnmatch.fnmatchcase(relative, pattern) for pattern in safe_patterns):
                if relative not in expected_paths:
                    raise ModelIntegrityError("The model directory contains an unpinned allowed file.")
                actual_paths.add(relative)
    if actual_paths != expected_paths:
        raise ModelIntegrityError("The model files do not match the pinned manifest.")

    for raw_path, record in files.items():
        rel = _expected_relpath(raw_path)
        candidate = model_real.joinpath(*rel.parts)
        try:
            target = candidate.resolve(strict=True)
        except OSError as error:
            raise ModelIntegrityError("A pinned model file is missing or has a broken link.") from error
        allowed_root = _allowed_root_for(target, [model_real, cache_repo_root])
        expected_size = record.get("size_bytes")
        expected_hash = record.get("sha256")
        if not isinstance(expected_size, int) or isinstance(expected_size, bool) or expected_size < 0 or expected_size > MAX_MODEL_FILE_SIZE:
            raise ModelIntegrityError("The model integrity manifest contains an invalid file size.")
        if not isinstance(expected_hash, str) or len(expected_hash) != 64 or any(c not in "0123456789abcdef" for c in expected_hash):
            raise ModelIntegrityError("The model integrity manifest contains an invalid SHA-256 value.")
        actual_hash = _hash_file_no_follow(target, allowed_root, expected_size)
        if actual_hash != expected_hash:
            raise ModelIntegrityError("A model file failed its SHA-256 integrity check.")
    return True
