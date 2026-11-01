// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

#ifndef TTMEDIA_H
#define TTMEDIA_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Media categorization kind matching Rust MediaKind.
 */
typedef enum CMediaKind {
    CMEDIA_KIND_AUDIO = 0,
    CMEDIA_KIND_VIDEO = 1,
    CMEDIA_KIND_DOCUMENT = 2,
    CMEDIA_KIND_CODE = 3,
    CMEDIA_KIND_IMAGE = 4,
    CMEDIA_KIND_ARCHIVE = 5,
    CMEDIA_KIND_BINARY = 6
} CMediaKind;

/**
 * Inspection summary descriptor containing media metadata and classification.
 */
typedef struct CMediaSummary {
    CMediaKind kind;
    char *mime_type;
    char *details;
    double duration_seconds;
    uint32_t width;
    uint32_t height;
} CMediaSummary;

/**
 * Opaque handle representing a continuous-memory FlatTable.
 */
typedef struct CFlatTable CFlatTable;

/**
 * Returns the compile-time library version string (null-terminated).
 */
const char *ttmedia_version(void);

/**
 * Inspects a byte buffer to determine media kind, MIME type, and metadata.
 *
 * @param data Pointer to buffer bytes. Must not be NULL.
 * @param len Size of data buffer in bytes.
 * @param hint Optional filename or extension hint (null-terminated), or NULL.
 * @return Allocated CMediaSummary pointer, or NULL on error. Free with ttmedia_summary_free().
 */
CMediaSummary *ttmedia_inspect(const uint8_t *data, size_t len, const char *hint);

/**
 * Releases memory allocated for a CMediaSummary descriptor.
 */
void ttmedia_summary_free(CMediaSummary *summary);

/**
 * Parses raw CSV byte data into a continuous memory tabular structure.
 *
 * @param data Pointer to CSV text buffer. Must not be NULL.
 * @param len Size of data in bytes.
 * @return Allocated CFlatTable handle, or NULL on parse failure. Free with ttmedia_table_free().
 */
CFlatTable *ttmedia_parse_csv(const uint8_t *data, size_t len);

/**
 * Returns the total number of rows in the table.
 */
size_t ttmedia_table_row_count(const CFlatTable *table);

/**
 * Returns the total number of columns in the table.
 */
size_t ttmedia_table_col_count(const CFlatTable *table);

/**
 * Copies the string representation of a cell at (row, col) into a caller-provided buffer.
 *
 * @param table Valid table handle.
 * @param row Zero-based row index.
 * @param col Zero-based column index.
 * @param buf Output char buffer.
 * @param max_len Capacity of output buffer including null-terminator.
 * @return 0 on success, or -1 on invalid argument / out of bounds.
 */
int32_t ttmedia_table_get_cell_str(const CFlatTable *table, size_t row, size_t col, char *buf, size_t max_len);

/**
 * Frees memory allocated for a CFlatTable.
 */
void ttmedia_table_free(CFlatTable *table);

/**
 * Frees a string allocated by the Rust C-ABI runtime.
 */
void ttmedia_free_string(char *s);

#ifdef __cplusplus
}
#endif

#endif /* TTMEDIA_H */
