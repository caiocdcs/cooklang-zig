{
  description = "CookLang Parser for Zig - A complete implementation of the CookLang specification";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        zig = pkgs.zig_0_13 or pkgs.zig;  # Use zig 0.13+ or fallback
      in
      {
        packages = {
          default = pkgs.stdenv.mkDerivation {
            pname = "cooklang-zig";
            version = "0.1.0";

            src = ./.;

            nativeBuildInputs = [ zig ];

            buildPhase = ''
              zig build -Doptimize=ReleaseFast
            '';

            installPhase = ''
              mkdir -p $out/bin
              cp zig-out/bin/cooklang_zig $out/bin/
            '';

            meta = with pkgs.lib; {
              description = "CookLang parser implementation in Zig";
              homepage = "https://github.com/caiocdcs/cooklang-zig";
              license = licenses.mit;
              platforms = platforms.all;
              mainProgram = "cooklang_zig";
            };
          };
        };

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            zig
            just
            entr  # For file watching
          ];

          shellHook = ''
            echo "CookLang Zig Development Environment"
            echo "==================================="
            echo "Zig version: $(zig version)"
            echo ""
            echo "Available commands:"
            echo "  just build      - Build the project"
            echo "  just test       - Run unit tests"
            echo "  just test-parser - Run canonical tests"
            echo "  just demo       - Run demo"
            echo "  just fmt        - Format code"
            echo ""
            echo "Type 'just' to see all available commands"
          '';
        };

        apps.default = flake-utils.lib.mkApp {
          drv = self.packages.${system}.default;
        };

        checks = {
          build = self.packages.${system}.default;

          test = pkgs.stdenv.mkDerivation {
            pname = "cooklang-zig-tests";
            version = "0.1.0";

            src = ./.;

            nativeBuildInputs = [ zig ];

            buildPhase = ''
              zig build test --summary all
            '';

            installPhase = ''
              mkdir -p $out
              echo "Tests passed" > $out/test-results
            '';
          };
        };
      });
}
