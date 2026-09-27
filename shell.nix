{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
  packages = with pkgs; [
    zig
    pkg-config
    wayland
    wayland-protocols
    wayland-scanner
    libxkbcommon
    freetype
    fontconfig
  ];

  LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath (with pkgs; [
    wayland
    libxkbcommon
    freetype
    fontconfig
  ]);
}
