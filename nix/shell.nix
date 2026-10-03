# Pinned dev shell. Same toolchain + libs as the build; mirrors shell.nix.
{ pkgs, system }:
let build = import ./build.nix { inherit pkgs system; };
in pkgs.mkShell {
  packages = [ build.zig pkgs.pkg-config ] ++ build.libs;
  LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath build.libs;
}
