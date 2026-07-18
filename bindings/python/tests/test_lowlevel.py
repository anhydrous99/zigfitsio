"""Low-level ctypes binding tests (no numpy required)."""

import ctypes as c

import pytest

import zigfitsio.lowlevel as ll


def test_version():
    assert ll.version().count(".") == 2


def test_fingerprint_one_shot_matches_streaming():
    one_shot = (c.c_ubyte * 16)()
    ll.check(ll.lib.zf_fingerprint128_v1(b"abc", 3, one_shot))

    state = c.c_void_p()
    ll.check(ll.lib.zf_fingerprint128_begin_v1(c.byref(state)))
    try:
        ll.check(ll.lib.zf_fingerprint128_update_v1(state, b"a", 1))
        ll.check(ll.lib.zf_fingerprint128_update_v1(state, b"bc", 2))
        streamed = (c.c_ubyte * 16)()
        ll.check(ll.lib.zf_fingerprint128_final_v1(state, streamed))
    finally:
        ll.lib.zf_fingerprint128_free_v1(state)

    assert bytes(one_shot).hex() == "6437b3ac38465133ffb63b75273a8db5"
    assert bytes(streamed) == bytes(one_shot)


def test_create_memory_image_roundtrip():
    h = c.c_void_p()
    ll.check(ll.lib.zf_create_memory(None, c.byref(h)))
    try:
        axes = (c.c_long * 2)(4, 3)
        ll.check(ll.lib.zf_create_img(h, -32, 2, axes))
        pix = (c.c_float * 12)(*[float(i) for i in range(12)])
        ll.check(ll.lib.zf_write_img(h, ll.ZF_FLOAT32, 1, 12, None, None, pix))
        out = (c.c_float * 12)()
        ll.check(ll.lib.zf_read_img(h, ll.ZF_FLOAT32, 1, 12, None, None, out))
        assert list(out) == list(pix)
    finally:
        ll.lib.zf_close(h)


def test_keyword_not_found_is_typed():
    h = c.c_void_p()
    ll.check(ll.lib.zf_create_memory(None, c.byref(h)))
    try:
        ll.check(ll.lib.zf_create_img(h, 8, 0, None))
        v = c.c_double()
        with pytest.raises(ll.KeywordNotFound) as ei:
            ll.check(ll.lib.zf_read_key_dbl(h, b"NOPE", 4, c.byref(v)))
        assert ei.value.status == 202
        # KeywordNotFound is also a KeyError for dict-like ergonomics.
        assert isinstance(ei.value, KeyError)
    finally:
        ll.lib.zf_close(h)
