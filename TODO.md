## TODO

Open items only. Everything that used to be listed here and now exists in the app has been
removed (share menu consolidation, SponsorBlock Highlight + per-category behaviour, re-skip after
seeking, hold-to-seek, seek thumbnails, fullscreen rotation, download button under the player,
autoplay switch, playback back-stack, local history tab, channel opens over the player, playlist
panel, quality picker, captions).

### Player
- Captions: styling options (size, background) and translated tracks (`translationLanguages`)
  are not exposed; only the video's own tracks are listed.
- Progressive streams do not re-resolve when the quality picker changes; only the HLS cap is
  applied live. Re-resolving at the current position would make the picker feel instant.

### Home
- Chip selection re-fetches the whole feed (`params`), like the web client; the response's
  `reloadContinuationItemsCommand` path is parsed structurally but has not been seen live yet.
- Shelves render videos and Shorts; posts (`postRenderer`) and playlist lockups are skipped.

### Music
- Library sub-pages (Liked songs = `VLLM`, `FEmusic_history`, uploads) are reachable through the
  shelves YouTube returns but have no dedicated screens yet.
- Lyrics tab from `/next` (`musicQueueRenderer` → Lyrics) is parsed by nobody.
- Home continuation works when signed in; anonymous continuation tokens come back empty from
  YouTube, so the anonymous Home is the first page only.
- Offline songs are listed in Music › Library; they are still evicted by the download cache limit
  like every other download. Pinning explicit saves would need a flag in `DownloadMetadata`.

### Housekeeping
- `PlayerStateManager.swift` is ~1,700 lines; the SponsorBlock, recommendation-refill and
  playback-history concerns could each move to their own file without behaviour change.
