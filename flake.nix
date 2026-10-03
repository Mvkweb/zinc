{
  description = "zinc — ultra-light Zig 0.16 Wayland terminal";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

  outputs = { self, nixpkgs }: let
    systems = [ "x86_64-linux" "aarch64-linux" ];
    forSystems = nixpkgs.lib.genAttrs systems;

    # Release line lives ONLY in build.zig.zon `.version` (mandatory there).
    # The flake reads it, so a release commit bumps exactly one literal;
    # suffixes and tarballs derive from git.
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

    zigVersion = "0.16.0";
    zigHashes = {
      x86_64-linux = "sha256-cOSWZKdDdLSLUebz/fv0N/Y5XUJQkFBYi9SavlK6PQA=";
      aarch64-linux = "sha256-6ksJv7IuxvbGzqxXq2PvtrRuF6sI0h9p86SLOOFTTxc=";
    };

    # Pinned Zig 0.16.0 straight from ziglang.org: deterministic regardless
    # of what nixpkgs ships, no overlay dependency.
    zigToolchain = pkgs: system: pkgs.stdenvNoCC.mkDerivation {
      pname = "zig";
      version = zigVersion;
      src = pkgs.fetchurl {
        url = "https://ziglang.org/download/${zigVersion}/zig-${system}-${zigVersion}.tar.xz";
        hash = zigHashes.${system};
      };
      installPhase = ''
        runHook preInstall
        mkdir -p $out/bin
        cp -r . $out/zig-dist
        ln -s $out/zig-dist/zig $out/bin/zig
        runHook postInstall
      '';
    };

    zincLibs = pkgs: with pkgs; [ wayland libxkbcommon freetype fontconfig ];

    zincDrv = { pkgs, system, src, doCheck ? false }: pkgs.stdenv.mkDerivation {
      pname = "zinc";
      version = versionFor src;
      inherit src;
      nativeBuildInputs = [
        (zigToolchain pkgs system)
        pkgs.pkg-config
        pkgs.makeWrapper
        # Zig bakes a stock /lib64 dynamic linker into the binary, which
        # does not exist on NixOS. Rewrite INTERP/RPATH to the nix glibc
        # before wrapping; without this the binary fails at exec time.
        pkgs.autoPatchelfHook
      ];
      buildInputs = zincLibs pkgs;
      # Zero zon dependencies, so no network or vendoring step is needed.
      buildPhase = ''
        runHook preBuild
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME"
        zig build -Doptimize=ReleaseSafe -Dversion=${versionFor src} \
          --prefix $out --global-cache-dir "$TMPDIR/zig-global-cache"
        runHook postBuild
      '';
      dontInstall = true;
      postFixup = ''
        wrapProgram $out/bin/zinc \
          --prefix LD_LIBRARY_PATH : "${pkgs.lib.makeLibraryPath (zincLibs pkgs)}"
      '';
      inherit doCheck;
      checkPhase = ''
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME"
        zig build check --global-cache-dir "$TMPDIR/zig-global-cache"
      '';
      meta = with pkgs.lib; {
        description = "Ultra-light Zig 0.16 Wayland terminal";
        homepage = "https://github.com/Mvkweb/zinc";
        platforms = [ "x86_64-linux" "aarch64-linux" ];
      };
    };

    # Verification ladder as flake checks: `nix flake check` runs them all.
    mkCheck = { pkgs, system, name, cmd }: pkgs.runCommand "zinc-${name}" {
      src = self;
      nativeBuildInputs = [ (zigToolchain pkgs system) pkgs.pkg-config ];
      buildInputs = zincLibs pkgs;
    } ''
      cp -r $src work && chmod -R +w work && cd work
      export HOME="$TMPDIR/home" && mkdir -p "$HOME"
      ${cmd}
      touch $out
    '';
  in {
    packages = forSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = zincDrv { inherit pkgs system; src = self; doCheck = true; };
    });

    checks = forSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
      check = name: cmd: mkCheck { inherit pkgs system name cmd; };
    in {
      check = check "check" "zig build check --global-cache-dir \"$TMPDIR/zig-global-cache\"";
      check-minimal = check "minimal" "zig build check -Dminimal=true --global-cache-dir \"$TMPDIR/zig-global-cache\"";
      check-ascii-only = check "ascii-only" "zig build check -Dascii-only=true --global-cache-dir \"$TMPDIR/zig-global-cache\"";
      fmt = check "fmt" "zig fmt --check src/ build.zig";
    });

    devShells = forSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.mkShell {
        packages = [ (zigToolchain pkgs system) pkgs.pkg-config ] ++ zincLibs pkgs;
        LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath (zincLibs pkgs);
      };
    });
  };
}
