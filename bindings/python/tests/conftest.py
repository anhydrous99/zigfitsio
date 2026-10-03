"""Shared fixtures; ``--installed-package`` verifies the wheel's import and library provenance."""

import os
import sys
import sysconfig
from pathlib import Path

import pytest

_REPO = Path(__file__).resolve().parents[3]
_SRC = _REPO / "bindings" / "python" / "src"

def pytest_addoption(parser):
    parser.addoption("--installed-package", action="store_true", help="Require installed package and bundled native library")


def pytest_configure(config):
    installed = config.getoption("--installed-package")
    if installed:
        os.environ.pop("ZIGFITSIO_LIBRARY", None)
        # Do not let a caller's PYTHONPATH redirect an installed-wheel check to source.
        sys.path[:] = [p for p in sys.path if Path(p).resolve() != _SRC]
    else:
        sys.path.insert(0, str(_SRC))
        if "ZIGFITSIO_LIBRARY" not in os.environ:
            for sub, name in (("lib", "libzigfitsio_capi.dylib"), ("lib", "libzigfitsio_capi.so"), ("bin", "zigfitsio_capi.dll")):
                cand = _REPO / "zig-out" / sub / name
                if cand.exists():
                    os.environ["ZIGFITSIO_LIBRARY"] = str(cand)
                    break
    try:
        import zigfitsio
        from zigfitsio import lowlevel
    except (ImportError, OSError) as exc:
        raise pytest.UsageError(f"zigfitsio is unavailable; build/install the native library before testing: {exc}") from exc
    if installed:
        package = Path(zigfitsio.__file__).resolve().parent
        library = Path(lowlevel.lib._name).resolve()
        install_roots = {Path(sysconfig.get_paths()[key]).resolve() for key in ("purelib", "platlib")}
        if not any(package.is_relative_to(root) for root in install_roots) or not library.is_relative_to(package):
            raise pytest.UsageError(f"installed-package provenance failed: package={package}, library={library}")
        print(f"installed-package provenance: {package}; bundled library: {library}")


@pytest.fixture
def tmp_fits(tmp_path):
    def _path(name="test.fits"):
        return str(tmp_path / name)

    return _path


GOLDEN = _REPO / "test" / "golden"


@pytest.fixture
def golden_dir():
    if not GOLDEN.exists():
        pytest.skip("golden corpus not present")
    return GOLDEN
