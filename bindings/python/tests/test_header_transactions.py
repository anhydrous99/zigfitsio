"""Logical-header snapshot and one-commit edit transaction coverage."""

import ctypes as c

import numpy as np
import pytest

import zigfitsio as zf
from zigfitsio import lowlevel as ll


def test_header_v1_ctypes_layout_matches_c_abi():
    assert c.sizeof(ll.ZfHeaderSnapshotInfoV1) == 48
    assert c.sizeof(ll.ZfHeaderEntryV1) == 96
    assert c.sizeof(ll.ZfHeaderOpV1) == 88
    assert c.sizeof(ll.ZfHeaderApplyOptsV1) == 16
    assert c.sizeof(ll.ZfHeaderApplyResultV1) == 32


def test_header_edit_commits_one_batch_and_roundtrips(tmp_fits):
    path = tmp_fits("header-edit.fits")
    zf.writeto(path, np.arange(4, dtype="i2"), overwrite=True)

    with zf.open(path, mode="update") as hdul:
        header = hdul[0].header
        long_value = "value-" * 30
        calls = []
        real_apply = header._batch_apply

        def counted(ops, revision):
            calls.append(list(ops))
            return real_apply(ops, revision)

        header._batch_apply = counted
        with header.edit() as editing:
            assert editing is header
            header["OBSERVER"] = ("Ada", "operator")
            header["ESO DET LONG"] = long_value
            header.add_history("calibrated")

        assert len(calls) == 1
        assert header["OBSERVER"] == "Ada"
        assert header["ESO DET LONG"] == long_value

    with zf.open(path) as hdul:
        assert hdul[0].header["OBSERVER"] == "Ada"
        assert hdul[0].header.comment_of("OBSERVER") == "operator"
        assert hdul[0].header["ESO DET LONG"] == "value-" * 30
        assert list(hdul[0].header["HISTORY"]) == ["calibrated"]


def test_header_edit_rolls_back_python_and_file_on_commit_error(tmp_fits):
    path = tmp_fits("header-rollback.fits")
    zf.writeto(path, np.arange(3, dtype="i2"), overwrite=True)

    with zf.open(path, mode="update") as hdul:
        header = hdul[0].header
        with pytest.raises(zf.FitsHeaderError):
            with header.edit():
                header["GOOD"] = 7
                header["BITPIX"] = 8  # structural edits are rejected by the staged Zig engine
        assert "GOOD" not in header
        assert header["BITPIX"] == 16

    with zf.open(path) as hdul:
        assert "GOOD" not in hdul[0].header
        assert hdul[0].header["BITPIX"] == 16


def test_header_edit_body_exception_never_calls_backend(tmp_fits):
    path = tmp_fits("header-body-error.fits")
    zf.writeto(path, np.zeros(1, dtype="u1"), overwrite=True)
    with zf.open(path, mode="update") as hdul:
        header = hdul[0].header
        called = False
        real_apply = header._batch_apply

        def counted(ops, revision):
            nonlocal called
            called = True
            return real_apply(ops, revision)

        header._batch_apply = counted
        with pytest.raises(RuntimeError, match="stop"):
            with header.edit():
                header["TEMP"] = 1
                raise RuntimeError("stop")
        assert not called
        assert "TEMP" not in header


def test_checksum_flush_invalidates_materialized_header_revision(tmp_fits):
    """A checksum-updating flush must not strand the Python header on an old revision."""

    path = tmp_fits("checksum-revision.fits")
    zf.writeto(path, np.arange(4, dtype="i2"), overwrite=True, checksum=True)
    opts = ll.ZfOpenOpts()
    opts.checksum_on_close = 1

    with zf.open(path, mode="update", opts=opts) as hdul:
        header = hdul[0].header
        assert header._revision is not None

        hdul.flush()  # native checksum replacement advances the HDU's header revision
        assert header._revision is None
        header["EAGER"] = 1

        hdul.flush()
        assert header._revision is None
        with header.edit():
            header["BATCHED"] = 2

    with zf.open(path) as hdul:
        assert hdul[0].header["EAGER"] == 1
        assert hdul[0].header["BATCHED"] == 2

    with zf.open(path, mode="update") as hdul:
        header = hdul[0].header
        revision = header._revision
        hdul.flush()  # an ordinary flush does not mutate headers or weaken revision checks
        assert header._revision == revision


def test_plain_image_reconstruction_preserves_context_structural_cards():
    """Table-looking extras remain metadata on an image; real image layout stays data-derived."""

    hdu = zf.PrimaryHDU(np.arange(3, dtype="u1"))
    hdu.header["BEFORE"] = 1
    hdu.header["TFIELDS"] = (7, "context-inapplicable image metadata")
    hdu.header["MIDDLE"] = 2
    hdu.header["ZTABLE"] = True
    hdu.header["ZFORM1"] = "1J"
    hdu.header["ZCTYP1"] = "PIXEL"
    hdu.header["ZTILELEN"] = 32
    hdu.header["AFTER"] = 3
    hdu.header["BITPIX"] = 64  # a real image structural override must still be ignored

    with zf.from_bytes(zf.HDUList([hdu]).to_bytes()) as reopened:
        header = reopened[0].header
        assert header["TFIELDS"] == 7
        assert header.comment_of("TFIELDS") == "context-inapplicable image metadata"
        assert header["ZTABLE"] is True
        assert header["ZFORM1"] == "1J"
        assert header["ZCTYP1"] == "PIXEL"
        assert header["ZTILELEN"] == 32
        assert header["BITPIX"] == 8
        extras = {"BEFORE", "TFIELDS", "MIDDLE", "ZTABLE", "ZFORM1", "ZCTYP1", "ZTILELEN", "AFTER"}
        assert [key for key in header.keys() if key in extras] == [
            "BEFORE", "TFIELDS", "MIDDLE", "ZTABLE", "ZFORM1", "ZCTYP1", "ZTILELEN", "AFTER",
        ]
