{
  description = "DwarfStar (antirez ds4) — DeepSeek V4 inference runtime, ROCm build for AMD Strix Halo (gfx1151)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];

      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      pkgsFor = system: import nixpkgs { inherit system; };
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          ds4 = pkgs.callPackage ./package.nix { };
          inherit (pkgs) lib;
        in
        {
          inherit ds4;
          default = ds4;
        } // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          # Convenience variant for an RDNA3 discrete GPU; Uds4-gfx1100 = pkgs.callPackage ./package.nix { rocmArch = "gfx1100"; };
          ds4-gfx1100 = pkgs.callPackage ./package.nix { rocmArch = "gfx1100"; };
        }
      );

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.ds4}/bin/ds4";
        };
      });

      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          inherit (pkgs) lib;
        in
        {
          default = pkgs.mkShell {
            inputsFrom = [ self.packages.${system}.ds4 ];
            packages = lib.optional pkgs.stdenv.hostPlatform.isLinux [
              pkgs.rocmPackages.rocminfo
              pkgs.rocmPackages.rocm-smi
            ];
          };
        }
      );
    };
}
