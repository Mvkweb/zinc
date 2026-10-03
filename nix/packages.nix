# Per-system packages. Thin: the how lives in ./build.nix.
{ pkgs, system, self, version }:
let build = import ./build.nix { inherit pkgs system; };
in {
  default = build.mkZinc { src = self; inherit version; };
}
