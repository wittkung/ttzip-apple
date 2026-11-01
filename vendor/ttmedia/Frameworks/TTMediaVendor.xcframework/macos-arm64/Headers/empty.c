// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

#include "ttmedia_demux.h"

// Force linker to retain ttmedia_demux symbols from static archive
const void * const volatile __ttmedia_demux_anchor[] __attribute__((used, visibility("default"))) = {
    (const void *)&ttmedia_demux_open,
    (const void *)&ttmedia_demux_read_packet,
    (const void *)&ttmedia_demux_release_packet,
    (const void *)&ttmedia_demux_seek,
    (const void *)&ttmedia_demux_query_tracks_json,
    (const void *)&ttmedia_demux_close,
};
