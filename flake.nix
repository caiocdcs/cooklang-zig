{
  description = "cooklang-zig: a CookLang recipe parser and CLI in Zig";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        inherit (pkgs) lib zig;

        src = lib.fileset.toSource {
          root = ./.;
          fileset = lib.fileset.unions [
            ./build.zig
            ./build.zig.zon
            ./src
          ];
        };

        # zig.hook builds with `zig build` (ReleaseSafe) and caches in $TMPDIR.
        cooklang-zig = pkgs.stdenv.mkDerivation {
          pname = "cooklang-zig";
          version = lib.head (
            builtins.match ''.*\.version = "([^"]+)".*'' (builtins.readFile ./build.zig.zon)
          );
          inherit src;
          nativeBuildInputs = [ zig.hook ];
          doCheck = true; # zig.hook's check phase runs `zig build test`
          meta = {
            description = "CookLang recipe parser and CLI";
            homepage = "https://github.com/caiocdcs/cooklang-zig";
            license = lib.licenses.mit;
            mainProgram = "cooklang-zig";
          };
        };
      in
      {
        packages.default = cooklang-zig;

        apps.default = flake-utils.lib.mkApp { drv = cooklang-zig; };

        checks = {
          inherit cooklang-zig;
          fmt = pkgs.runCommand "cooklang-zig-fmt" { nativeBuildInputs = [ zig ]; } ''
            zig fmt --check ${src}
            touch $out
          '';
        };

        devShells.default = pkgs.mkShell {
          packages = [
            zig
            pkgs.zls
            pkgs.just
            pkgs.watchexec
            pkgs.yq-go # just canonical-json
          ];
        };

        formatter = pkgs.nixfmt;
      }
    );
}
