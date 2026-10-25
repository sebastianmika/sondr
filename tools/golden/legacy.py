"""Load selected legacy sample_vault modules straight from a git tag.

Only the pure-Python modules needed for reference values are loaded, by file path,
so the legacy package (and its heavy imports) never runs.
"""

import importlib.util
import io
import os
import subprocess
import tarfile
import tempfile
from pathlib import Path
from types import ModuleType

DEFAULT_REPO = Path(os.environ.get("SAMPLE_VAULT_LEGACY", "~/repos/sample_vault")).expanduser()
DEFAULT_TAG = "legacy-python-v0.2"
_PKG = "backend/sample_vault"


def export_tag(repo: Path = DEFAULT_REPO, tag: str = DEFAULT_TAG) -> Path:
    """Extract the legacy package at ``tag`` into a fresh temp dir.

    Args:
        repo: Path to the legacy git repository.
        tag: Tag or commit to export.

    Returns:
        Path to the exported ``sample_vault`` package directory.

    Raises:
        RuntimeError: If git cannot export the tag.
    """
    proc = subprocess.run(
        ["git", "-C", str(repo), "archive", tag, _PKG],
        capture_output=True,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"git archive {tag} failed: {proc.stderr.decode()}")
    dest = Path(tempfile.mkdtemp(prefix="sondr_legacy_"))
    with tarfile.open(fileobj=io.BytesIO(proc.stdout)) as tar:
        tar.extractall(dest, filter="data")
    return dest / _PKG


def load_module(pkg_dir: Path, name: str) -> ModuleType:
    """Import ``sample_vault/core/<name>.py`` by path under a private module name."""
    path = pkg_dir / "core" / f"{name}.py"
    spec = importlib.util.spec_from_file_location(f"legacy_{name}", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module
