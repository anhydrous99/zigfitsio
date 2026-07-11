/** Stable ABI codes (mirror of `bindings/c/zigfitsio.h` / Python `lowlevel.py`). */

// ── Element datatype codes (ZfType) ──
export const ZF_UINT8 = 1;
export const ZF_INT8 = 2;
export const ZF_INT16 = 3;
export const ZF_UINT16 = 4;
export const ZF_INT32 = 5;
export const ZF_UINT32 = 6;
export const ZF_INT64 = 7;
export const ZF_UINT64 = 8;
export const ZF_FLOAT32 = 9;
export const ZF_FLOAT64 = 10;
export const ZF_BOOL = 11;
export const ZF_BIT = 12;
export const ZF_STRING = 13;
export const ZF_COMPLEX64 = 14;
export const ZF_COMPLEX128 = 15;

// ── Open modes ──
export const READONLY = 0;
export const READWRITE = 1;
export const CREATE = 2;

// ── HDU kinds ──
export const HDU_PRIMARY = 0;
export const HDU_IMAGE = 1;
export const HDU_ASCII_TABLE = 2;
export const HDU_BINARY_TABLE = 3;
export const HDU_RANDOM_GROUPS = 4;

// ── Table types ──
export const BINARY_TBL = 0;
export const ASCII_TBL = 1;

// ── Logical-header snapshot/edit V1 ──
export const ZF_HEADER_SNAPSHOT_INCLUDE_RAW = 0x00000001;

export const ZF_HEADER_ENTRY_VALUE = 1;
export const ZF_HEADER_ENTRY_COMMENTARY = 2;
export const ZF_HEADER_ENTRY_BLANK = 3;
export const ZF_HEADER_ENTRY_OTHER = 4;

export const ZF_HEADER_VALUE_NONE = 0;
export const ZF_HEADER_VALUE_UNDEFINED = 1;
export const ZF_HEADER_VALUE_LOGICAL = 2;
export const ZF_HEADER_VALUE_INT64 = 3;
export const ZF_HEADER_VALUE_INTEGER_TEXT = 4;
export const ZF_HEADER_VALUE_FLOAT64 = 5;
export const ZF_HEADER_VALUE_STRING = 6;
export const ZF_HEADER_VALUE_RAW_TOKEN = 7;

export const ZF_HEADER_ENTRY_HIERARCH = 0x00000001;
export const ZF_HEADER_ENTRY_CONTINUED = 0x00000002;
export const ZF_HEADER_ENTRY_MALFORMED = 0x00000004;

export const ZF_HEADER_OP_UPSERT = 1;
export const ZF_HEADER_OP_DELETE_FIRST = 2;
export const ZF_HEADER_OP_DELETE_ALL = 3;
export const ZF_HEADER_OP_RENAME = 4;
export const ZF_HEADER_OP_APPEND_COMMENTARY = 5;
export const ZF_HEADER_OP_APPEND_RAW_RUN = 6;
export const ZF_HEADER_OP_INSERT_RAW_RUN = 7;
export const ZF_HEADER_OP_RESERVE_BLANKS = 8;

export const ZF_HEADER_OP_COMMENT_PRESENT = 0x00000001;
export const ZF_HEADER_OP_STRICT = 0x00000002;
export const ZF_HEADER_OP_FORCE_HIERARCH = 0x00000004;

export const ZF_HEADER_APPLY_CHECK_REVISION = 0x00000001;
export const ZF_HEADER_APPLY_ALLOW_STRUCTURAL = 0x00000002;
