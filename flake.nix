{
  description = "cardano-sieve";

  inputs = {
    nixpkgs.follows = "haskellNix/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    haskellNix = {
      url = "github:input-output-hk/haskell.nix";
      inputs.hackage.follows = "hackageNix";
    };
    hackageNix = {
      url = "github:input-output-hk/hackage.nix";
      flake = false;
    };
    iohkNix = {
      url = "github:input-output-hk/iohk-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    chap = {
      url = "github:intersectmbo/cardano-haskell-packages?ref=repo";
      flake = false;
    };
    pre-commit-hooks.url = "github:cachix/git-hooks.nix";
  };

  outputs = { flake-utils, haskellNix, iohkNix, chap, pre-commit-hooks, ... }@inputs:
    flake-utils.lib.eachSystem [
      "x86_64-linux"
      "aarch64-linux"
      "aarch64-darwin"
    ] (system: let
      defaultCompiler = "ghc9124";
      fourmoluVersion = "0.18.0.0";
      hlintVersion = "3.10";

      nixpkgs = import inputs.nixpkgs {
        inherit system;
        inherit (haskellNix) config;

        overlays = 
          # Crypto libraries required for Cardano ecosystem
          builtins.attrValues iohkNix.overlays ++
          # Required for haskell.nix
          [ haskellNix.overlay ];
      };

      inherit (nixpkgs) lib stdenv;

      # Build fourmolu/hlint from haskell.nix rather than nixpkgs
      fourmolu = nixpkgs.haskell-nix.tool defaultCompiler "fourmolu" fourmoluVersion;
      hlint = nixpkgs.haskell-nix.tool defaultCompiler "hlint" hlintVersion;

      # Run formatter and static analysis before committing
      pre-commit-check = pre-commit-hooks.lib.${system}.run {
        src = ./.;
        hooks = {
          fourmolu = {
            enable = true;
            package = fourmolu; # Reuse fourmolu from `nix develop`
          };

          hlint = {
            enable = true;
            package = hlint; # Resuse hlint from `nix develop`
          };
        };
      };

      cabalProject = nixpkgs.haskell-nix.cabalProject' {
        src = ./.;
        name = "cardano-sieve";
        compiler-nix-name = defaultCompiler;

        # Required to use CHaP
        inputMap = {
          "https://chap.intersectmbo.org/" = chap;
        };

        cabalProjectLocal = ''
          repository cardano-haskell-packages-local
            url: file:${chap}
            secure: True
          active-repositories: hackage.haskell.org, cardano-haskell-packages-local
        '';

        shell = {
          tools = {
            cabal = "3.16.1.0";
            ghcid = "0.8.9";
            fourmolu = fourmoluVersion;
            hlint = hlintVersion;
          };

          buildInputs = lib.optionals stdenv.hostPlatform.isLinux [
            nixpkgs.liburing # io_uring is Linux only
          ];

          # Useful tools tools for local development
          nativeBuildInputs = with nixpkgs; [
            git # Required by cabal for SRPs
            gh
            jq
            sqlite
          ];

          # Set to true to build a hoogle index, then start it with
          # `nix develop . -c hoogle -- server --local`
          withHoogle = false;

          shellHook = ''
            ${pre-commit-check.shellHook}
          '';
        };
      };

      flake = cabalProject.flake {};

    in
      lib.recursiveUpdate flake {
        # 'required' aggregate job
        hydraJobs = 
          nixpkgs.callPackages inputs.iohkNix.utils.ciJobsAggregates {
            ciJobs = flake.hydraJobs;
            nonRequiredPaths = [];
          };

        packages.default = flake.packages."cardano-sieve:exe:cardano-sieve";
        apps.default = flake.apps."cardano-sieve:exe:cardano-sieve";
        project = cabalProject;
        formatter = nixpkgs.alejandra;
      });

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
