{
  description = "zinc — ultra-light Zig 0.16 Wayland terminal";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

  # Binary cache: pull builds instead of compiling. No account needed to
  # pull; pushing needs CACHIX_AUTH_TOKEN (cache owner holds it).
  # NOTE: remote (untrusted) flakes ignore nixConfig unless the user passes
  # --accept-flake-config once. The CI cachix-action covers runners instead.
  # TODO(cache-owner): replace with the real cache name + public key.
  nixConfig = {
    extra-substituters = [ "https://zinc-term.cachix.org" ];
    extra-trusted-public-keys = [ "zinc-term.cachix.org-1:tmQ02H/zTCa6EjFoNsOpRIIgYETxRdZ/7mkz69ffgzc=" ];
  };

  # Release line lives ONLY in build.zig.zon `.version` (mandatory there).
  # A release commit bumps that one literal; suffixes and tarballs derive
  # from git, so tags need no other hardcoding.
  outputs = { self, nixpkgs }: let
    systems = [ "x86_64-linux" "aarch64-linux" ];
    forSystems = nixpkgs.lib.genAttrs systems;
    pkgsFor = system: nixpkgs.legacyPackages.${system};

    zonText = builtins.readFile ./build.zig.zon;
    zonMatch = builtins.match "[[:space:][:print:]]*\\.version = \"([0-9]+\\.[0-9]+\\.[0-9]+)\"[[:space:][:print:]]*" zonText;
    baseVersion =
      if zonMatch == null
      then throw "flake.nix: could not parse .version from build.zig.zon"
      else builtins.head zonMatch;
    versionFor = src:
      if src ? shortRev
      then "${baseVersion}+g${src.shortRev}"
      else "${baseVersion}-dev";
  in {
    packages = forSystems (system: import ./nix/packages.nix {
      pkgs = pkgsFor system;
      inherit system self;
      version = versionFor self;
    });

    checks = forSystems (system: import ./nix/checks.nix {
      pkgs = pkgsFor system;
      inherit system self;
    });

    devShells = forSystems (system: import ./nix/shell.nix {
      pkgs = pkgsFor system;
      inherit system;
    });
  };
}
