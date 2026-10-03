# Verification ladder as flake checks (`nix flake check` runs them all).
# Compile-only on purpose: the repo rule executes tests only on request,
# so the suite stays out of builds and checks alike.
{ pkgs, system, self }:
let
  build = import ./build.nix { inherit pkgs system; };
  mk = name: cmd: pkgs.runCommand "zinc-${name}" {
    src = self;
    nativeBuildInputs = [ build.zig pkgs.pkg-config ];
    buildInputs = build.libs;
  } ''
    cp -r $src work && chmod -R +w work && cd work
    export HOME="$TMPDIR/home" && mkdir -p "$HOME"
    ${cmd}
    touch $out
  '';
in {
  check = mk "check" "zig build check";
  check-minimal = mk "minimal" "zig build check -Dminimal=true";
  check-ascii-only = mk "ascii-only" "zig build check -Dascii-only=true";
  fmt = mk "fmt" "zig fmt --check src/ build.zig";
}
