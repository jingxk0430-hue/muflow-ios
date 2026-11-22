# Bilibili native mask and activity foundation

This implementation traces retained first-party player bundles, rather than
reusing another platform's mask format. Static code inspection establishes the
wire format and equations; synthetic native tests do not establish real-device
performance or that any particular video supplies these resources.

Evidence retained under
`/home/xiaoxiaoke/Developer/infuse-danmaku-research/advanced-effects-20261122/ep1231538/renderer`:

- `npd.314.e3edce28.js`, SHA-256
  `2f9f1df88b8f5e7b9f7213f4d328711b3bb384310be2250bab6aa245df602b0a`.
  Character offsets 193654 onward: `getHeader`, `getTopList`, `loadMask`,
  `parse`, `parseBase64`; 190000 onward: `render`, `setMaskImage`.
- `core.a37280df.js`, SHA-256
  `0ec8956e41cdbcda53cce302db98de4c70a05f14c28a7e2ac259a43b96b74dd1`.
  `parseSandDuneData` and `addActivityMetas` around 268494–272339.
- `npd.505.84951d71.js`, SHA-256
  `549dd8bd3cc2a5c21943b9c2a049ff415bce84dea66423a6499c20a513ee1a33`.
  `calculateCoordination` around 2069300–2070200.

## Mask container

The 16-byte big-endian header starts `MASK`, has version at byte 4, codec byte
8 equal to 2, and index count at byte 12. The following count × 16 bytes contain
64-bit timeMs/absolute file offsets; the player only accepts zero high words.
Consecutive offsets bound independent zlib/gzip chunks. Inflated chunks contain
`[length:u32, unknown:u32, timeMs:u32, payload:length bytes]` frames. Payload is
UTF-8 `data:image/svg+xml;base64,...`; this is SVG, not bitmap RLE.

The current native transport integration caps full files at 4 MiB. Native
decompression selects only the chunk for the requested video time. It caps
compressed chunks at 8 MiB, inflated chunks at 16 MiB, and frames per chunk at
4096. Over-budget/unsupported inputs return failure without keeping old masks.
Index parsing and chunk selection should be cached by the caller. Do not
inflate chunks and parse XML on every display callback.

`selectMaskFrame` follows the web player's first-frame lookahead window:
`timeMs + floor(1000/fps) <= frame.timeMs < timeMs + 3*floor(1000/fps)`.
The caller clears a mask when no frame is suitable or after a source switch.

The native SVG rasterizer supports bounded svg/g/path/rect documents, common
affine transforms, fill opacity, and even-odd/nonzero fill. Paths support
M/L/H/V/C/S/Q/T/A/Z in absolute/relative forms. Arcs lower to cubic Beziers.
External resources, scripts, images, filters, clips, strokes and unsupported
structures fail explicitly. SVG source alpha is preserved; it is never
inverted based on an assumed person silhouette. The opaque area is where
comments remain visible, matching CSS mask alpha. Source and native synthetic
fixtures cover inverse silhouettes and letterbox mapping; no real mask response
was present for the previously inspected episode.

## Activity 20031

`pointFile` text lines are `absoluteTimeSeconds,xPercent,yPercent`. During
`showTime <= videoTime < end`, coordinates interpolate linearly between adjacent
points and clamp to first/last positions outside the point interval. The web's
Y equation maps percentages through the centered video rectangle. Native helper
accepts the complete normalized content rectangle, also handling pillarboxing.
It returns elapsed time since showTime and duration `end - showTime`.

This helper does not implement the SandDune displacement shader, noise texture,
radial/angle/gravity uniforms, or a pixel-identical black-hole renderer. A local
particle approximation must be identified as such, not described as the full
first-party activity engine.
