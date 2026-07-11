"""Legacy Python raw-card parser retained only as an A/B benchmark baseline.

Production bindings materialize logical headers through the Zig snapshot ABI.  This module keeps
the former Python parsing path behaviorally comparable without shipping that duplicate FITS logic
as part of the ``zigfitsio`` package.
"""

from __future__ import annotations

import math
import re
from typing import Any


# FITS 4.0 section 4.2.4 real grammar (including the FORTRAN D exponent).  Bare ``float()`` also
# accepts tokens such as nan/inf and numeric underscores, which the legacy binding rejected.
_FITS_REAL = re.compile(r"[+-]?(?:\d+\.?\d*|\.\d+)(?:[EDed][+-]?\d+)?\Z")


class _Card:
    __slots__ = ("keyword", "value", "comment", "commentary")

    def __init__(self, keyword: str, value: Any, comment: str = "", commentary: bool = False):
        self.keyword = keyword
        self.value = value
        self.comment = comment
        self.commentary = commentary


def _parse_value_comment(field: str):
    """Parse a card value field (card columns 11-80) into ``(value, comment)``."""
    s = field
    i = 0
    while i < len(s) and s[i] == " ":
        i += 1
    if i >= len(s):
        return None, ""
    if s[i] == "/":
        return None, s[i + 1 :].strip()
    if s[i] == "'":
        i += 1
        out = []
        while i < len(s):
            ch = s[i]
            if ch == "'":
                if i + 1 < len(s) and s[i + 1] == "'":
                    out.append("'")
                    i += 2
                    continue
                i += 1
                break
            out.append(ch)
            i += 1
        rest = s[i:]
        comment = ""
        slash = rest.find("/")
        if slash >= 0:
            comment = rest[slash + 1 :].strip()
        return "".join(out).rstrip(), comment
    slash = s.find("/")
    token = (s if slash < 0 else s[:slash]).strip()
    comment = "" if slash < 0 else s[slash + 1 :].strip()
    if token == "T":
        return True, comment
    if token == "F":
        return False, comment
    try:
        return int(token), comment
    except ValueError:
        pass
    if _FITS_REAL.match(token):
        value = float(token.replace("D", "E").replace("d", "e"))
        if math.isfinite(value):
            return value, comment
    return token, comment


def _extract_raw_string(field: str):
    """Locate a quoted string without unescaping doubled quotes."""
    s = field
    i = 0
    while i < len(s) and s[i] == " ":
        i += 1
    if i >= len(s) or s[i] != "'":
        return None, "", False
    i += 1
    start = i
    while i < len(s):
        if s[i] == "'":
            if i + 1 < len(s) and s[i + 1] == "'":
                i += 2
                continue
            stripped = s[i + 1 :].lstrip(" ")
            if stripped == "" or stripped[0] == "/":
                comment = stripped[1:].strip() if stripped[:1] == "/" else ""
                return s[start:i], comment, True
            i += 1
        else:
            i += 1
    return s[start:], "", True


def _value_field(text: str) -> str | None:
    """Return the raw value field for a standard or HIERARCH card."""
    if text[8:10] == "= ":
        return text[10:]
    if text[0:8].rstrip() == "HIERARCH":
        rest = text[8:]
        eq = rest.find("=")
        if eq >= 0:
            return rest[eq + 1 :]
    return None


def parse_card(raw: bytes) -> _Card | None:
    """Parse one physical 80-byte card; return ``None`` for END."""
    text = raw.decode("ascii", "replace")
    name = text[0:8].rstrip()
    if name == "END":
        return None
    if name in ("COMMENT", "HISTORY") or text[0:8] == "        ":
        return _Card(name, text[8:].rstrip(), "", commentary=True)
    if text[8:10] == "= ":
        value, comment = _parse_value_comment(text[10:])
        return _Card(name, value, comment)
    if name == "HIERARCH":
        rest = text[8:]
        eq = rest.find("=")
        if eq >= 0:
            keyword = rest[:eq].strip()
            if keyword:
                value, comment = _parse_value_comment(rest[eq + 1 :])
                return _Card(keyword, value, comment)
    return _Card(name, text[8:].rstrip(), "", commentary=True)


def parse_cards(raws: list[bytes]) -> list[_Card]:
    """Parse physical cards and fold CONTINUE long-string runs like the legacy binding."""
    cards: list[_Card] = []
    i = 0
    n = len(raws)
    while i < n:
        card = parse_card(raws[i])
        base = i
        i += 1
        if card is None:
            continue
        field = _value_field(raws[base].decode("ascii", "replace")) if not card.commentary else None
        if isinstance(card.value, str) and field is not None:
            raw, comment, is_string = _extract_raw_string(field)
            if (
                is_string
                and raw.endswith("&")
                and i < n
                and raws[i][0:8].rstrip() == b"CONTINUE"
            ):
                parts = [raw[:-1]]
                while i < n and raws[i][0:8].rstrip() == b"CONTINUE":
                    frag, cont_comment, _ = _extract_raw_string(raws[i][8:].decode("ascii", "replace"))
                    i += 1
                    if cont_comment:
                        comment = cont_comment
                    frag = frag if isinstance(frag, str) else ""
                    if frag.endswith("&"):
                        parts.append(frag[:-1])
                    else:
                        parts.append(frag)
                        break
                card.value = "".join(parts).replace("''", "'").rstrip()
                card.comment = comment
        cards.append(card)
    return cards
