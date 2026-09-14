{
  description = "cardano-sieve";

  inputs = {
    hackageNix = {
      url = "github:input-output-hk/hackage.nix";
      flake = false;
    };
    haskellNix = {
      url = "github:input-output-hk/haskell.nix";
      inputs.hackage.follows = "hackageNix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Pin to the same nixpkgs as cardano-api for maximum binary cache overlap.
    nixpkgs.url = "github:NixOS/nixpkgs/11cb3517b3af6af300dd6c055aeda73c9bf52c48";
    iohkNix.url = "github:input-output-hk/iohk-nix";
    flake-utils.url = "github:numtide/flake-utils";
    CHaP = {
      url = "github:intersectmbo/cardano-haskell-packages?ref=repo";
      flake = false;
    };
    pre-commit-hooks.url = "github:cachix/git-hooks.nix";
    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };
  };

  outputs = inputs:
    inputs.flake-utils.lib.eachSystem [
      "x86_64-linux"
      "aarch64-linux"
      "aarch64-darwin"
    ] (system: let
      nixpkgs = import inputs.nixpkgs {
        overlays = [
          # iohkNix.overlays.crypto provides libsodium-vrf, libblst and libsecp256k1.
          inputs.iohkNix.overlays.crypto
          # haskellNix.overlay must come before its config overlays.
          inputs.haskellNix.overlay
          # Configure haskell.nix to use the iohk-nix crypto libraries, so
          # cardano-crypto-praos links against libsodium-vrf rather than stock
          # libsodium.
          inputs.iohkNix.overlays.haskell-nix-crypto
        ];
        inherit system;
        inherit (inputs.haskellNix) config;
      };
      inherit (nixpkgs) lib;

      defaultCompiler = "ghc9124";

      # Shared with shell.tools below so the pre-commit hook and the dev shell
      # can never format against different fourmolu versions.
      fourmoluVersion = "0.18.0.0";
      fourmolu = nixpkgs.haskell-nix.tool defaultCompiler "fourmolu" fourmoluVersion;

      pre-commit-check = inputs.pre-commit-hooks.lib.${system}.run {
        src = ./.;
        hooks = {
          # Set `package`, not `entry`: git-hooks.nix builds the default entry
          # as an absolute store path, so the hook still resolves fourmolu when
          # git runs it outside `nix develop`. Its own tools.fourmolu is
          # nixpkgs' 0.19.0.1, hence pinning ours here.
          fourmolu = {
            enable = true;
            package = fourmolu;
          };
          hlint.enable = true;
        };
      };

      cabalProject = nixpkgs.haskell-nix.cabalProject' {
        src = ./.;
        name = "cardano-sieve";
        compiler-nix-name = defaultCompiler;

        # Redirect the CHaP URL to the pinned flake input so the build is
        # fully reproducible and works in sandboxed Nix evaluations.
        inputMap = {
          "https://chap.intersectmbo.org/" = inputs.CHaP;
        };

        cabalProjectLocal = ''
          repository cardano-haskell-packages-local
            url: file:${inputs.CHaP}
            secure: True
          active-repositories: hackage.haskell.org, cardano-haskell-packages-local
        '';

        shell.packages = p: [p.cardano-sieve];

        shell.tools = {
          cabal = "3.16.1.0";
          ghcid = "0.8.9";
          fourmolu = fourmoluVersion;
          hlint = "3.10";
        };

        shell.nativeBuildInputs = with nixpkgs; [git gh jq sqlite];

        shell.withHoogle = false;

        shell.shellHook = ''
          ${pre-commit-check.shellHook}
        '';
      };

      flake = cabalProject.flake {};

      # Job paths kept out of the `required` aggregate: they land in
      # `nonrequired` instead and so cannot fail CI. Nothing is excluded yet —
      # "devShells" here would drop the dev shell, for instance.
      nonRequiredPaths = [];

      # `required`/`nonrequired` aggregates over the jobs haskell.nix already
      # derives (checks, packages, devShells, roots, plan-nix), plus those jobs
      # themselves so each is still reported individually.
      ciJobs =
        nixpkgs.callPackages inputs.iohkNix.utils.ciJobsAggregates {
          ciJobs = flake.hydraJobs;
          nonRequiredPaths = map lib.hasPrefix nonRequiredPaths;
        }
        // flake.hydraJobs;
    in
      lib.recursiveUpdate flake {
        # haskell.nix names every output after its cabal component
        # ("cardano-sieve:exe:cardano-sieve"), so a bare `nix build`/`nix run`
        # finds nothing. Point default at the executable.
        packages.default = flake.packages."cardano-sieve:exe:cardano-sieve";
        apps.default = flake.apps."cardano-sieve:exe:cardano-sieve";

        # `nix develop`. haskell.nix already derives this shell from the
        # `shell.*` args on cabalProject above; naming it here makes the entry
        # point visible and leaves somewhere for extra shells to hang.
        devShells.default = cabalProject.shell;

        # Both names carry the same jobs: this flake-utils revision has no
        # special case for hydraJobs, so eachSystem puts `${system}` at the top
        # of either one.
        hydraJobs = ciJobs;
        inherit ciJobs;

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
