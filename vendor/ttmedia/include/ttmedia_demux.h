// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

#pragma once

#ifndef TTMEDIA_DEMUX_H
#define TTMEDIA_DEMUX_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#if defined(__clang__)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-extension"
#endif

#if !defined(__has_feature) || !__has_feature(nullability)
#ifndef _Nonnull
#define _Nonnull
#endif
#ifndef _Nullable
#define _Nullable
#endif
#ifndef _Null_unspecified
#define _Null_unspecified
#endif
#endif

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Status and error codes returned by demuxing bridge operations.
 */
typedef enum TTMediaDemuxStatus {
    TT_MEDIA_DEMUX_OK = 0,
    TT_MEDIA_DEMUX_EOF = 1,
    TT_MEDIA_DEMUX_ERR_INVALID_ARGUMENT = -1,
    TT_MEDIA_DEMUX_ERR_IO = -2,
    TT_MEDIA_DEMUX_ERR_CORRUPT_DATA = -3,
    TT_MEDIA_DEMUX_ERR_UNSUPPORTED_FORMAT = -4,
    TT_MEDIA_DEMUX_ERR_OUT_OF_MEMORY = -5,
    TT_MEDIA_DEMUX_ERR_SEEK_FAILED = -6,
} TTMediaDemuxStatus;

/**
 * Container format identifiers conforming to the hermetic whitelist demuxer.
 * Matches FR-001 whitelist requirements.
 */
typedef enum TTMediaContainerFormat {
    TT_MEDIA_CONTAINER_FORMAT_UNKNOWN = 0,
    TT_MEDIA_CONTAINER_FORMAT_MOV = 1,
    TT_MEDIA_CONTAINER_FORMAT_MATROSKA = 2,
    TT_MEDIA_CONTAINER_FORMAT_WEBM = 3,
    TT_MEDIA_CONTAINER_FORMAT_AVI = 4,
    TT_MEDIA_CONTAINER_FORMAT_FLV = 5,
    TT_MEDIA_CONTAINER_FORMAT_MPEGTS = 6,
    TT_MEDIA_CONTAINER_FORMAT_MP3 = 7,
    TT_MEDIA_CONTAINER_FORMAT_AAC = 8,
    TT_MEDIA_CONTAINER_FORMAT_FLAC = 9,
    TT_MEDIA_CONTAINER_FORMAT_OGG = 10,
    TT_MEDIA_CONTAINER_FORMAT_WAV = 11,
} TTMediaContainerFormat;

/**
 * Elementary stream media types.
 */
typedef enum TTMediaType {
    TT_MEDIA_TYPE_UNKNOWN = 0,
    TT_MEDIA_TYPE_VIDEO = 1,
    TT_MEDIA_TYPE_AUDIO = 2,
    TT_MEDIA_TYPE_SUBTITLE = 3,
    TT_MEDIA_TYPE_ATTACHMENT = 4,
    TT_MEDIA_TYPE_DATA = 5,
} TTMediaType;

/**
 * Video codec identifiers for hardware pass-through and open codec decoding.
 */
typedef enum TTVideoCodec {
    TT_VIDEO_CODEC_UNKNOWN = 0,
    TT_VIDEO_CODEC_H264 = 1,
    TT_VIDEO_CODEC_HEVC = 2,
    TT_VIDEO_CODEC_AV1 = 3,
    TT_VIDEO_CODEC_VP9 = 4,
    TT_VIDEO_CODEC_VP8 = 5,
    TT_VIDEO_CODEC_PRORES = 6,
} TTVideoCodec;

/**
 * Audio codec identifiers for CoreAudio and software decoding pipelines.
 */
typedef enum TTAudioCodec {
    TT_AUDIO_CODEC_UNKNOWN = 0,
    TT_AUDIO_CODEC_AAC = 1,
    TT_AUDIO_CODEC_ALAC = 2,
    TT_AUDIO_CODEC_OPUS = 3,
    TT_AUDIO_CODEC_FLAC = 4,
    TT_AUDIO_CODEC_VORBIS = 5,
    TT_AUDIO_CODEC_MP3 = 6,
    TT_AUDIO_CODEC_PCM_S16LE = 7,
    TT_AUDIO_CODEC_PCM_S24LE = 8,
    TT_AUDIO_CODEC_PCM_F32LE = 9,
    TT_AUDIO_CODEC_AC3 = 10,
    TT_AUDIO_CODEC_EAC3 = 11,
} TTAudioCodec;

/**
 * Video format parameters required for CoreMedia CMVideoFormatDescription
 * creation and VideoToolbox hardware decoder configuration.
 */
typedef struct TTVideoFormatDesc {
    TTVideoCodec codec;
    int32_t width;
    int32_t height;
    uint32_t pixel_format;
    const uint8_t * _Nullable extradata;
    size_t extradata_len;
} TTVideoFormatDesc;

/**
 * Audio format parameters required for CoreAudio AudioStreamBasicDescription
 * configuration and CoreMedia CMAudioFormatDescription creation.
 */
typedef struct TTAudioFormatDesc {
    TTAudioCodec codec;
    double sample_rate;
    uint32_t channel_count;
    uint32_t bits_per_channel;
    const uint8_t * _Nullable extradata;
    size_t extradata_len;
} TTAudioFormatDesc;

/**
 * Compressed elementary packet extracted by the demuxer or decoded frame reference.
 * Directly maps to CoreMedia CMSampleBuffer construction.
 */
typedef struct TTMediaPacket {
    uint32_t stream_index;
    uint8_t media_type;
    int64_t pts_value;
    int32_t pts_timescale;
    int64_t dts_value;
    int32_t dts_timescale;
    int64_t duration_value;
    int32_t duration_timescale;
    const uint8_t * _Nullable payload_data;
    size_t payload_len;
    bool is_keyframe;
    bool do_not_display;
    uint32_t iosurface_id;
} TTMediaPacket;

/**
 * Comprehensive media stream and container metadata reported on opening.
 */
typedef struct TTMediaStreamInfo {
    TTMediaContainerFormat container_format;
    uint32_t track_count;
    double duration_seconds;
    int64_t bit_rate;
    bool has_video;
    bool has_audio;
    TTVideoFormatDesc video_desc;
    TTAudioFormatDesc audio_desc;
} TTMediaStreamInfo;

/**
 * Opens a media container at the specified filesystem path and extracts stream metadata.
 *
 * @param path Null-terminated UTF-8 filesystem path to media container.
 * @param out_handle Pointer to receive the allocated opaque demuxer handle.
 * @param out_info Pointer to receive the media stream metadata and format descriptors.
 * @return TT_MEDIA_DEMUX_OK (0) on success, or a negative TTMediaDemuxStatus code on failure.
 */
int32_t ttmedia_demux_open(
    const char * _Nonnull path,
    void * _Nullable * _Nonnull out_handle,
    TTMediaStreamInfo * _Nonnull out_info
);

/**
 * Reads the next compressed packet or decoded frame from the active demuxer instance.
 *
 * Caller must release the packet using ttmedia_demux_release_packet() once processing completes.
 *
 * @param handle Opaque demuxer handle returned by ttmedia_demux_open().
 * @param out_packet Pointer to receive the extracted packet payload and timing metadata.
 * @return TT_MEDIA_DEMUX_OK (0) on success,
 *         TT_MEDIA_DEMUX_EOF (1) on end of stream,
 *         or a negative TTMediaDemuxStatus error code on failure.
 */
int32_t ttmedia_demux_read_packet(
    void * _Nonnull handle,
    TTMediaPacket * _Nonnull out_packet
);

/**
 * Releases memory and references held by an extracted TTMediaPacket.
 *
 * Resets payload pointers and zeroes the packet structure. Safe to call with NULL.
 *
 * @param packet Pointer to the packet to release.
 */
void ttmedia_demux_release_packet(
    TTMediaPacket * _Nullable packet
);

/**
 * Seeks to the specified timestamp in seconds.
 *
 * @param handle Opaque demuxer handle returned by ttmedia_demux_open().
 * @param timestamp_seconds Target presentation timestamp in seconds.
 * @param accurate When true, demuxer seeks to the exact keyframe preceding the timestamp;
 *                 when false, seeks to the nearest keyframe according to container index.
 * @return TT_MEDIA_DEMUX_OK (0) on success, or a negative TTMediaDemuxStatus code on failure.
 */
int32_t ttmedia_demux_seek(
    void * _Nonnull handle,
    double timestamp_seconds,
    bool accurate
);

/**
 * Closes the active demuxer instance and frees all associated resources.
 *
 * Safe to call with NULL.
 *
 * @param handle Opaque demuxer handle to destroy.
 */
void ttmedia_demux_close(
    void * _Nullable handle
);

/**
 * Queries the structured track catalog and selected-track source media metadata as a bounded UTF-8 JSON document
 * (`schema_version = 1`, `source_metadata_contract_version = "v1"`) into a caller-allocated buffer without
 * modifying existing C struct layouts.
 *
 * Includes per-track identity (`container_track_number`, `playback_track_id`, `packet_stream_index`),
 * video colour/HDR/Dolby Vision provenance (`bit_depth`, `color_primaries`, `transfer_characteristics`,
 * `matrix_coefficients`, `color_range`, `chroma_subsampling`, `hdr_format`, `dynamic_range`,
 * `dolby_vision_profile`, `dolby_vision_level`, `max_cll`, `max_fall`), and audio codec profile/Atmos/layout
 * provenance (`audio_profile`, `is_atmos`, `channel_layout`, `channel_layout_source`).
 * Always sets `active_hdr_output_verified_by_demuxer = false` so the UI layer only displays active HDR/EDR
 * rendering state after verifying live display/renderer output.
 *
 * Buffer ownership, sizing, and error semantics:
 * 1. Size-query mode: Pass `out_json_buf == NULL` and `buf_capacity == 0`.
 *    Writes the exact UTF-8 byte length (excluding the trailing NUL terminator) into `*out_required_len`
 *    and returns `TT_MEDIA_DEMUX_OK (0)`.
 * 2. Copy mode: Pass a non-null `out_json_buf` with `buf_capacity >= (*out_required_len + 1)`.
 *    Writes the UTF-8 JSON bytes followed by a trailing `'\0'` byte into `out_json_buf`, sets
 *    `*out_required_len` to the UTF-8 byte length (excluding `'\0'`), and returns `TT_MEDIA_DEMUX_OK (0)`.
 * 3. Insufficient capacity (never silently truncates): If `out_json_buf != NULL` and
 *    `buf_capacity < (*out_required_len + 1)`, sets `*out_required_len` to the required UTF-8 byte length
 *    (excluding `'\0'`), leaves `out_json_buf` unmodified, and returns `TT_MEDIA_DEMUX_ERR_OUT_OF_MEMORY (-5)`.
 * 4. Invalid arguments: If `handle == NULL`, `out_required_len == NULL`, or
 *    `(out_json_buf == NULL && buf_capacity > 0)`, returns `TT_MEDIA_DEMUX_ERR_INVALID_ARGUMENT (-1)`.
 *
 * The caller retains sole ownership of `out_json_buf`; no native heap allocation is leaked across FFI.
 */
int32_t ttmedia_demux_query_tracks_json(
    const void * _Nullable handle,
    char * _Nullable out_json_buf,
    size_t buf_capacity,
    size_t * _Nullable out_required_len
);

/* Bounded UTF-8 SRT/WebVTT parser. Returns owned UTF-8 JSON or NULL on allocation failure.
 * Input is borrowed for this call only; maximum length is 4 MiB.
 * Release the result exactly once with ttmedia_subtitles_free, never libc free. */
char * _Nullable ttmedia_subtitles_parse(const uint8_t * _Nullable data, size_t len);
void ttmedia_subtitles_free(char * _Nullable value);
/* Worker-only catalog/timeline access through an already-authorized descriptor path.
 * track = -1 lists tracks; track = 0 runs default bounded prewarm (8 tracks, 4000ms);
 * track <= -2 runs encoded bounded prewarm (remaining budget_ms, max_tracks, optional single target track);
 * track > 0 runs an explicit user-initiated full single-track load without prewarm time truncation.
 * Same JSON ownership as ttmedia_subtitles_parse. */
char * _Nullable ttmedia_subtitles_container(const char * _Nullable path, int64_t track);
/* Request-scoped container scan (request_id > 0 enables per-request cancellation isolation). */
char * _Nullable ttmedia_subtitles_container_request(
    const char * _Nullable path,
    int64_t track,
    uint64_t request_id
);
/* Explicitly registers a subtitle request_id in the active table before scan start so its state cannot be evicted.
 * Returns true if registered, or false if rejected because request_id == 0 or MAX_ACTIVE_REQUESTS (4096) is full. */
bool ttmedia_subtitles_register_request(uint64_t request_id);
/* Marks a specific subtitle request_id as cancelled (effective both before scan start and mid-scan). */
void ttmedia_subtitles_cancel_request(uint64_t request_id);
/* Reclaims an unstarted or completed subtitle request_id from the active/pre-start tables. */
void ttmedia_subtitles_reclaim_request(uint64_t request_id);
/* Returns true if request_id (> 0) has been marked cancelled. */
bool ttmedia_subtitles_is_request_cancelled(uint64_t request_id);
/* Returns the number of Matroska clusters scanned by a completed/aborted request_id (0 if none or pre-start abort). */
uint64_t ttmedia_subtitles_last_scanned_clusters(uint64_t request_id);
/* Configures an optional per-cluster cooperative pacing window (in ms) for a specific request_id for deterministic concurrency testing. */
void ttmedia_subtitles_set_request_cluster_delay_ms(uint64_t request_id, uint32_t delay_ms);
/* Returns the number of currently registered/in-flight subtitle requests in the native table (bounded by MAX_ACTIVE_REQUESTS = 4096). */
size_t ttmedia_subtitles_active_request_count(void);
/* Returns the number of unregistered pre-start cancellation tombstones in the native table (bounded by MAX_PRE_START_TOMBSTONES = 4096). */
size_t ttmedia_subtitles_pre_start_tombstone_count(void);
/* Returns the number of completed request diagnostic records in the native table (bounded by MAX_COMPLETED_RECORDS = 256). */
size_t ttmedia_subtitles_completed_record_count(void);
/* Returns the number of unconsumed per-request cluster delay entries in the native table (bounded by MAX_PENDING_DELAY_RECORDS = 256). */
size_t ttmedia_subtitles_pending_delay_count(void);
/* Returns the aggregate count of tombstone + completed + pending_delay records currently retained in the native table. */
size_t ttmedia_subtitles_retained_record_count(void);
/* Legacy session/process fallback cancellation hook. */
void ttmedia_subtitles_cancel(void);

/**
 * Status codes returned by bounded SVGZ decompression operations.
 */
typedef enum TTMediaSvgzStatus {
    TT_MEDIA_SVGZ_OK = 0,
    TT_MEDIA_SVGZ_ERR_COMPRESSED_TOO_LARGE = -1,
    TT_MEDIA_SVGZ_ERR_INVALID_GZIP_HEADER = -2,
    TT_MEDIA_SVGZ_ERR_TRUNCATED_STREAM = -3,
    TT_MEDIA_SVGZ_ERR_CORRUPTED_OR_CHECKSUM = -4,
    TT_MEDIA_SVGZ_ERR_DECOMPRESSED_LIMIT = -5,
    TT_MEDIA_SVGZ_ERR_EXCESSIVE_RATIO = -6,
    TT_MEDIA_SVGZ_ERR_INVALID_UTF8 = -7,
    TT_MEDIA_SVGZ_ERR_NOT_VALID_SVG = -8,
    TT_MEDIA_SVGZ_ERR_IO = -9,
} TTMediaSvgzStatus;

/**
 * Decompresses an in-memory Gzip (.svgz) buffer with strict input, output, and expansion-ratio bounds.
 * On TT_MEDIA_SVGZ_OK (0), *out_svg_utf8 receives an owned null-terminated UTF-8 string that must be
 * released with ttmedia_svgz_string_free(). On failure, *out_err_metric receives the offending size/ratio.
 */
int32_t ttmedia_svgz_decompress_bytes(
    const uint8_t * _Nullable data,
    size_t len,
    size_t max_compressed_bytes,
    size_t max_decompressed_bytes,
    size_t max_expansion_ratio,
    char * _Nullable * _Nonnull out_svg_utf8,
    size_t * _Nonnull out_err_metric
);

/**
 * Streams and decompresses a Gzip (.svgz) file from disk with strict input, output, and expansion-ratio bounds.
 */
int32_t ttmedia_svgz_decompress_file(
    const char * _Nonnull path,
    size_t max_compressed_bytes,
    size_t max_decompressed_bytes,
    size_t max_expansion_ratio,
    char * _Nullable * _Nonnull out_svg_utf8,
    size_t * _Nonnull out_err_metric
);

/**
 * Releases an owned UTF-8 C string returned by ttmedia_svgz_* or ttmedia_mhtml_*.
 */
void ttmedia_svgz_string_free(char * _Nullable value);

/**
 * Returns true if the leading bytes represent an RFC 2557 MHTML (multipart/related) archive.
 */
bool ttmedia_mhtml_is_multipart(const uint8_t * _Nullable data, size_t len);

/**
 * Returns true if the file at path starts with an RFC 2557 MHTML (multipart/related) archive header.
 */
bool ttmedia_mhtml_is_multipart_file(const char * _Nonnull path);

/**
 * Inspects an RFC 2557 MHTML buffer and returns an owned JSON summary string (or NULL if not MHTML).
 * Release with ttmedia_svgz_string_free().
 */
char * _Nullable ttmedia_mhtml_extract_summary(
    const uint8_t * _Nullable data,
    size_t len,
    size_t max_preview_bytes
);

#ifdef __cplusplus
}
#endif

#if defined(__clang__)
#pragma clang diagnostic pop
#endif

#endif // TTMEDIA_DEMUX_H
