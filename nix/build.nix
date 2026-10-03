# Shared build logic: toolchain resolution + the zinc derivation builder.
# The flake's packages/checks/shell all come through here, so there is
# exactly one place that knows how zinc compiles.
{ pkgs, system }:
let
  # Idiom: nixpkgs' versioned toolchain, never a hand-rolled tarball.
  # Fails loudly at eval if the pin predates 0.16 instead of silently
  # building with the wrong compiler.
  zig = pkgs.zig_0_16 or (throw
    "nixpkgs pin lacks zig_0_16 (need >= 0.16.0); bump the nixpkgs input");
  libs = with pkgs; [ wayland libxkbcommon freetype fontconfig ];
in {
  inherit zig libs;

  mkZinc = { src, version }:
    pkgs.stdenv.mkDerivation {
      pname = "zinc";
      inherit version src;
      strictDeps = true;

      nativeBuildInputs = [ zig pkgs.pkg-config pkgs.makeWrapper pkgs.autoPatchelfHook ];
      buildInputs = libs;

      # Phases (build/check/install) come from nixpkgs' zig hook.
      # The hook's check runs `zig build test` (executes); the repo rule is
      # compile-only verification, which lives in nix/checks.nix instead.
      dontUseZigCheck = true;

      zigBuildFlags = [ "-Doptimize=ReleaseSafe" "-Dversion=${version}" ];

      preBuild = ''
        [[ "$(zig version)" == "0.16.0" ]] || {
          echo "zinc requires zig 0.16.0, got $(zig version)" >&2
          exit 1
        }
      '';

      postFixup = ''
        wrapProgram $out/bin/zinc \
          --prefix LD_LIBRARY_PATH : "${pkgs.lib.makeLibraryPath libs}"
      '';

      meta = with pkgs.lib; {
        description = "Ultra-light Zig 0.16 Wayland terminal";
        homepage = "https://github.com/Mvkweb/zinc";
        mainProgram = "zinc";
        platforms = [ "x86_64-linux" "aarch64-linux" ];
      };
    };
}
