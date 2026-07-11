"""A dict-like, ordered FITS :class:`Header`, modeled on ``astropy.io.fits.Header``.

Headers loaded from a file are materialized from the Zig core's logical snapshot. Edits update the
in-memory list and, when attached to a writable file, persist through an injected callback.
"""

from __future__ import annotations

from contextlib import contextmanager
from typing import Any, Callable, Iterator, Optional

_COMMENTARY = ("COMMENT", "HISTORY", "")


class _Card:
    __slots__ = ("keyword", "value", "comment", "commentary")

    def __init__(self, keyword: str, value: Any, comment: str = "", commentary: bool = False):
        self.keyword = keyword
        self.value = value
        self.comment = comment
        self.commentary = commentary


def _wrap_commentary(value: Any) -> "list[str]":
    """Split commentary text into physical-card chunks of ≤72 chars (a COMMENT/HISTORY/blank card
    holds free text in columns 9-80). Empty text yields one blank card, matching astropy — which
    splits long commentary into multiple cards at assignment time rather than truncating."""
    text = "" if value is None else str(value)
    if not text:
        return [""]
    return [text[i : i + 72] for i in range(0, len(text), 72)]


class Header:
    """An ordered, case-insensitive collection of FITS keyword records."""

    def __init__(self):
        self._cards: list[_Card] = []
        self._persist: Optional[Callable[[str, Any, Optional[str]], Optional[int]]] = None
        self._delete: Optional[Callable[[str], Optional[int]]] = None
        # Rewrites every commentary card of a keyword in an attached writable handle to the given
        # texts (delete-all-by-name then re-append). Used by in-place commentary edits/deletes and
        # list replace-all, where a single append is not enough. None on read-only/detached headers.
        self._resync: Optional[Callable[[str, "list[Any]"], Optional[int]]] = None
        # One-call transactional persistence hook installed by an attached writable HDU. The
        # payload is a sequence of small binding-neutral edit tuples assembled below.
        self._batch_apply: Optional[Callable[[list[tuple], Optional[int]], Optional[int]]] = None
        self._revision: Optional[int] = None
        self._edit_ops: "list[tuple] | None" = None
        # Called after an edit that is NOT persisted to an open handle (read-only mode), so the
        # owning HDUList can flag itself dirty and reconstruct rather than copy stale bytes on save.
        self._dirty_cb: Optional[Callable[[], None]] = None

    # ── construction ──────────────────────────────────────────────────────────────────────
    @classmethod
    def _from_cards(cls, cards: list[_Card]) -> "Header":
        h = cls()
        h._cards = cards
        return h

    # ── mapping protocol ──────────────────────────────────────────────────────────────────
    def _find(self, key: str) -> int:
        ku = key.upper()
        for i, c in enumerate(self._cards):
            if not c.commentary and c.keyword.upper() == ku:
                return i
        return -1

    def _is_commentary_key(self, key: Any) -> bool:
        return isinstance(key, str) and key.upper() in _COMMENTARY

    def __contains__(self, key: str) -> bool:
        """Return whether a valued or commentary keyword is present."""

        if self._is_commentary_key(key):
            ku = key.upper()
            return any(c.commentary and c.keyword.upper() == ku for c in self._cards)
        return self._find(key) >= 0

    def __getitem__(self, key: str) -> Any:
        """Return a keyword value or a mutable commentary-card view."""

        # A commentary keyword returns a mutable list-like view over all of its cards (astropy's
        # ``header['COMMENT']`` behavior), never raising: an absent keyword yields an empty view.
        if self._is_commentary_key(key):
            return _CommentaryCards(self, key.upper())
        i = self._find(key)
        if i < 0:
            raise KeyError(key)
        return self._cards[i].value

    def get(self, key: str, default: Any = None) -> Any:
        """Return a keyword value, or ``default`` when it is absent."""

        if self._is_commentary_key(key):
            return _CommentaryCards(self, key.upper())
        i = self._find(key)
        return self._cards[i].value if i >= 0 else default

    def __setitem__(self, key: str, value: Any) -> None:
        """Insert or replace a keyword, persisting it when attached to a writable file."""

        # Commentary keywords accumulate (append), never overwrite; a list/tuple replaces all of
        # them. Handled before the (value, comment) unpack, which does not apply to commentary.
        if self._is_commentary_key(key):
            self._set_commentary(key.upper(), value)
            return
        comment = None
        if isinstance(value, tuple) and len(value) == 2:
            value, comment = value
        i = self._find(key)
        resolved_comment = comment if comment is not None else (self._cards[i].comment if i >= 0 else "")
        # Persist FIRST: a rejected edit (a structural keyword, or a read-only device) must not
        # leave a bogus card in the in-memory header, which would poison every later read.
        if self._edit_ops is not None:
            self._edit_ops.append(("upsert", key, value, resolved_comment))
        elif self._persist is not None:
            revision = self._persist(key, value, resolved_comment)
            if revision is not None:
                self._revision = int(revision)
        if i >= 0:
            self._cards[i].value = value
            if comment is not None:
                self._cards[i].comment = comment
        else:
            self._cards.append(_Card(key.upper(), value, comment or ""))
        if self._edit_ops is None and self._persist is None and self._dirty_cb is not None:
            self._dirty_cb()  # read-only edit → not in the handle's bytes; reconstruct on save

    def __delitem__(self, key: str) -> None:
        """Delete a valued keyword or every card for a commentary keyword."""

        # Deleting a commentary keyword removes ALL of its cards (astropy semantics).
        if self._is_commentary_key(key):
            ku = key.upper()
            idxs = [i for i, c in enumerate(self._cards) if c.commentary and c.keyword.upper() == ku]
            if not idxs:
                raise KeyError(key)
            for i in reversed(idxs):
                del self._cards[i]
            self._resync_keyword(ku)  # empty texts → delete-all in the handle (or mark dirty)
            return
        i = self._find(key)
        if i < 0:
            raise KeyError(key)
        if self._edit_ops is not None:
            self._edit_ops.append(("delete_first", key))
        elif self._delete is not None:
            revision = self._delete(key)  # persist first; on failure the in-memory card is retained
            if revision is not None:
                self._revision = int(revision)
        del self._cards[i]
        if self._edit_ops is None and self._delete is None and self._dirty_cb is not None:
            self._dirty_cb()

    # ── commentary (COMMENT / HISTORY / blank) ────────────────────────────────────────────
    def _set_commentary(self, keyword: str, value: Any) -> None:
        """Append (scalar) or replace-all (``list``) commentary cards for ``keyword``.

        A ``list`` replaces every card of the keyword; anything else appends. A 2-tuple is read as
        the valued-keyword ``(value, comment)`` form and only its text is kept (commentary cards
        have no comment field) — so ``header['COMMENT'] = ('note', 'ignored')`` adds one card, not
        two. Each logical entry is split into ≤72-char physical cards. Appending persists eagerly
        one card at a time (O(1) per card — cheap for long HISTORY chains); replace-all rewrites
        every card of the keyword through ``_resync``.
        """
        if isinstance(value, list):
            self._cards[:] = [
                c for c in self._cards if not (c.commentary and c.keyword.upper() == keyword)
            ]
            for item in value:
                for chunk in _wrap_commentary(item):
                    self._cards.append(_Card(keyword, chunk, "", commentary=True))
            self._resync_keyword(keyword)
            return
        if isinstance(value, tuple) and len(value) == 2:
            value = value[0]  # (text, comment): keep the text, drop the meaningless comment
        for chunk in _wrap_commentary(value):
            # Persist FIRST so a rejected write leaves no bogus in-memory card (mirrors valued keys).
            if self._edit_ops is not None:
                self._edit_ops.append(("append_commentary", keyword, chunk))
            elif self._persist is not None:
                revision = self._persist(keyword, chunk, None)
                if revision is not None:
                    self._revision = int(revision)
            self._cards.append(_Card(keyword, chunk, "", commentary=True))
        if self._edit_ops is None and self._persist is None and self._dirty_cb is not None:
            self._dirty_cb()

    def _resync_keyword(self, keyword: str) -> None:
        """Push the current in-memory commentary cards of ``keyword`` to an attached writable handle
        (rewrite-all), or flag the list dirty so a read-only edit reconstructs on save."""
        if self._edit_ops is not None:
            texts = [c.value for c in self._cards if c.commentary and c.keyword.upper() == keyword]
            self._edit_ops.append(("delete_all", keyword))
            self._edit_ops.extend(("append_commentary", keyword, text) for text in texts)
        elif self._resync is not None:
            texts = [c.value for c in self._cards if c.commentary and c.keyword.upper() == keyword]
            revision = self._resync(keyword, texts)
            if revision is not None:
                self._revision = int(revision)
        elif self._dirty_cb is not None:
            self._dirty_cb()

    @contextmanager
    def edit(self):
        """Stage header mutations and persist them with one Zig validation/commit batch.

        Outside this context, attached writable headers retain their eager persistence behavior.
        If the body or commit raises, the Python card list is restored. Validation and revision
        failures happen before disk mutation; device failures use best-effort disk rollback rather
        than crash-safe journaling. Nested contexts share the outer transaction rather than creating
        savepoints. Detached/read-only headers use the same local staging semantics and are marked
        dirty once.
        """

        if self._edit_ops is not None:
            yield self
            return

        backup = [
            _Card(c.keyword, c.value, c.comment, commentary=c.commentary)
            for c in self._cards
        ]
        self._edit_ops = []
        try:
            yield self
            ops = self._edit_ops
            if ops:
                if self._batch_apply is not None:
                    revision = self._batch_apply(ops, self._revision)
                    if revision is not None:
                        self._revision = int(revision)
                elif self._dirty_cb is not None:
                    self._dirty_cb()
        except BaseException:
            self._cards = backup
            raise
        finally:
            self._edit_ops = None

    def add_comment(self, value: Any) -> None:
        """Append a COMMENT card (astropy-compatible). Long text spans multiple cards."""
        self._set_commentary("COMMENT", value)

    def add_history(self, value: Any) -> None:
        """Append a HISTORY card (astropy-compatible). Long text spans multiple cards."""
        self._set_commentary("HISTORY", value)

    def __iter__(self) -> Iterator[str]:
        """Iterate valued keyword names in card order."""

        for c in self._cards:
            if not c.commentary:
                yield c.keyword

    def __len__(self) -> int:
        """Return the number of valued (non-commentary) keyword cards."""

        return sum(1 for c in self._cards if not c.commentary)

    def keys(self):
        """Return valued keyword names in card order."""

        return list(self.__iter__())

    def items(self):
        """Return ``(keyword, value)`` pairs in card order."""

        return [(c.keyword, c.value) for c in self._cards if not c.commentary]

    def values(self):
        """Return valued keyword values in card order."""

        return [c.value for c in self._cards if not c.commentary]

    def comment_of(self, key: str) -> str:
        """Return the comment belonging to ``key``, or an empty string."""

        i = self._find(key)
        return self._cards[i].comment if i >= 0 else ""

    def cards(self) -> list[tuple[str, Any, str]]:
        """Return materialized logical entries as ``(keyword, value, comment)`` tuples."""

        return [(c.keyword, c.value, c.comment) for c in self._cards]

    @property
    def comments(self) -> list[str]:
        """COMMENT card text (in order)."""
        return [c.value for c in self._cards if c.commentary and c.keyword == "COMMENT"]

    @property
    def history(self) -> list[str]:
        """HISTORY card text (in order)."""
        return [c.value for c in self._cards if c.commentary and c.keyword == "HISTORY"]

    def __repr__(self) -> str:
        """Render the header as human-readable FITS-style card rows."""

        rows = []
        for c in self._cards:
            if c.commentary:
                rows.append(f"{c.keyword:<8}{c.value}")
            else:
                v = repr(c.value)
                tail = f" / {c.comment}" if c.comment else ""
                rows.append(f"{c.keyword:<8}= {v}{tail}")
        return "\n".join(rows)


class _CommentaryCards:
    """A mutable, list-like view over one keyword's COMMENT/HISTORY/blank cards, mirroring the
    object astropy returns from ``header['COMMENT']``. Indexing, assignment, deletion, and
    ``append`` mutate the owning :class:`Header` and persist to an attached writable file.

    ``append`` is O(1). A single-card ``view[i] = x`` / ``del view[i]`` rewrites all *k* cards of
    the keyword (O(k)) to persist, so replacing many at once is cheaper as one assignment,
    ``header['COMMENT'] = [...]``, than as a loop of per-index edits.
    """

    __slots__ = ("_header", "_keyword")

    def __init__(self, header: "Header", keyword: str):
        self._header = header
        self._keyword = keyword

    def _indices(self) -> "list[int]":
        ku = self._keyword
        return [i for i, c in enumerate(self._header._cards) if c.commentary and c.keyword.upper() == ku]

    def __len__(self) -> int:
        return len(self._indices())

    def __iter__(self) -> Iterator[Any]:
        cards = self._header._cards
        return (cards[i].value for i in self._indices())

    def __getitem__(self, index):
        idxs = self._indices()
        cards = self._header._cards
        if isinstance(index, slice):
            return [cards[i].value for i in idxs[index]]
        return cards[idxs[index]].value

    def __setitem__(self, index: int, text: Any) -> None:
        if not isinstance(index, int):
            raise TypeError("commentary index must be an integer (slice assignment is not supported)")
        cards = self._header._cards
        pos = self._indices()[index]  # raises IndexError like a list for a bad index
        chunks = _wrap_commentary(text)
        cards[pos].value = chunks[0]
        for off, chunk in enumerate(chunks[1:], start=1):  # over-long text spills into new cards
            cards.insert(pos + off, _Card(self._keyword, chunk, "", commentary=True))
        self._header._resync_keyword(self._keyword)

    def __delitem__(self, index: int) -> None:
        if not isinstance(index, int):
            raise TypeError("commentary index must be an integer (slice deletion is not supported)")
        pos = self._indices()[index]
        del self._header._cards[pos]
        self._header._resync_keyword(self._keyword)

    def append(self, text: Any) -> None:
        self._header._set_commentary(self._keyword, text)

    def __eq__(self, other: Any) -> bool:
        try:
            return list(self) == list(other)
        except TypeError:
            return NotImplemented

    def __repr__(self) -> str:
        return "\n".join(str(v) for v in self)

    __str__ = __repr__
