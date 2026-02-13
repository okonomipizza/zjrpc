{
  description = "A clipboard sharing tool over local network";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    zig = {
      url = "github:mitchellh/zig-overlay";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils.follows = "flake-utils";
      };
    };

    zls = {
      url = "github:zigtools/zls/0.15.1";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        zig-overlay.follows = "zig";
      };
    };
  };

  outputs = {
    self,
    nixpkgs,
    zig,
    zls,
    ...
  }:
    builtins.foldl' nixpkgs.lib.recursiveUpdate {} (
      builtins.map (
        system: let
          pkgs = nixpkgs.legacyPackages.${system};
        in {
          devShell.${system} = pkgs.callPackage ./devShell.nix {
            zig = zig.packages.${system}."0.15.2";
            zls = zls.packages.${system}.zls;
          };

          formatter.${system} = pkgs.alejandra;
        }
      ) (builtins.attrNames zig.packages)
    );
}
