{
  description = "Marlowe Cardano implementation";


  inputs = {

    std = {
      url = "github:divnix/std";
      inputs.n2c.follows = "n2c";
    };

    n2c.url = "github:nlewo/nix2container";

    marlowe-plutus.url = "github:input-output-hk/marlowe-plutus";

    cardano-node.url = "github:input-output-hk/cardano-node?ref=8.9.0";

    iogx = {
      url = "github:input-output-hk/iogx";
      inputs.hackage.follows = "hackage";
      inputs.CHaP.follows = "CHaP";
      inputs.haskell-nix.follows = "haskell-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixpkgs.follows = "haskell-nix/nixpkgs";

    hackage = {
      url = "github:input-output-hk/hackage.nix";
      flake = false;
    };

    CHaP = {
      url = "github:input-output-hk/cardano-haskell-packages?ref=repo";
      flake = false;
    };

    haskell-nix = {
      url = "github:input-output-hk/haskell.nix";
      inputs.hackage.follows = "hackage";
    };
  };


  outputs = inputs@{ self, nixpkgs, ... }: inputs.iogx.lib.mkFlake {
    inherit inputs;
    repoRoot = ./.;
    systems = [ "x86_64-linux" "x86_64-darwin" "aarch64-darwin" "aarch64-linux" ];
    flake = let
      inherit (nixpkgs) lib;
    in {
      sqitch-plan-dirs = {
        # Ensure this path only changes when sqitch.plan file is updated, or DDL
        # files are updated.
        chain-sync = (builtins.path {
          path = self;
          name = "marlowe-chain-sync-sqitch-plan";
          filter = path: type:
            path == "${self}/marlowe-chain-sync"
              || path == "${self}/marlowe-chain-sync/sqitch.plan"
              || lib.hasPrefix "${self}/marlowe-chain-sync/deploy" path
              || lib.hasPrefix "${self}/marlowe-chain-sync/revert" path;
        }) + "/marlowe-chain-sync";

        # Ensure this path only changes when sqitch.plan file is updated, or DDL
        # files are updated.
        runtime = (builtins.path {
          path = self;
          name = "marlowe-runtime-sqitch-plan";
          filter = path: type:
            path == "${self}/marlowe-runtime"
              || path == "${self}/marlowe-runtime/marlowe-indexer"
              || path == "${self}/marlowe-runtime/marlowe-indexer/sqitch.plan"
              || lib.hasPrefix "${self}/marlowe-runtime/marlowe-indexer/deploy" path
              || lib.hasPrefix "${self}/marlowe-runtime/marlowe-indexer/revert" path;
        }) + "/marlowe-runtime/marlowe-indexer";
      };

      nixosModules.default = import ./nix/nixos.nix inputs;
    };
    outputs = import ./nix/outputs.nix;
  };


  nixConfig = {
    extra-substituters = [
      "https://cache.iog.io"
    ];
    extra-trusted-public-keys = [
      "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ="
    ];
    allow-import-from-derivation = true;
  };
}
