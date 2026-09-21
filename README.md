# zinc

A Wayland terminal emulator written in Zig.

## Dependencies

- Zig 0.16.0
- wayland-client
- libxkbcommon
- freetype2

## Build

Build the release binary:

```bash
zig build -Doptimize=ReleaseSafe
```

Run the binary:

```bash
./zig-out/bin/zinc
```

To check compilation and run tests without installing:

```bash
zig build check
```

## Known issues

- Hard resizes can strand one stray character. Content restores fine.
  Cause unknown, see `src/term/reflow.zig`.
