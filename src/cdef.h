// C definitions imported into Zig via translateC (Zig 0.16, arocc).
// Wayland core only: xdg-shell tables and app-level APIs are hand-written
// in Zig (src/backend/wl_proto.zig), xkbcommon via manual externs.
#include <wayland-client-core.h>

// FreeType (needs -I/usr/include/freetype2, wired in build.zig).
#include <ft2build.h>
#include FT_FREETYPE_H
#include <freetype/ftsynth.h>
#include <wayland-client-core.h>
