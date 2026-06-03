{
  description = "Caddy with selected plugins (cloudflare DNS, rate-limit, cache-handler).";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    flake-lib = {
      url = "github:jgus/flake-lib/v1";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };
  };

  outputs = { self, nixpkgs, flake-utils, flake-lib }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        # Single source of truth for the plugin list + combined vendor hash. Regenerate via `nix run .#update-version` from this directory.
        pin = import ./pin.nix;
        pkgs = import nixpkgs { inherit system; };
        # xcaddy resolves transitive go module deps fresh each time it runs, and the resulting go.mod can bake in a `go X.Y.Z` directive newer than the default `go` in our pinned nixpkgs. Pinning buildGoModule to a known-recent go toolchain keeps the build stable across nixpkgs movement. lib.fix + `caddy = self` is required because `passthru.withPlugins` was constructed with the unoverridden caddy via auto-callPackage; rewiring the self-reference makes the override propagate.
        caddyBase = pkgs.lib.fix (self: pkgs.caddy.override {
          buildGoModule = pkgs.buildGo126Module;
          caddy = self;
        });
        caddy = caddyBase.withPlugins {
          inherit (pin) plugins hash;
        };
        update-version = pkgs.writeShellApplication {
          name = "update-version";
          text = ''exec ${./update-version.sh} "$@"'';
        };
        # The vendor-hash-by-build-failure dance is shared via flake-lib; the bespoke
        # plugin resolution stays in update-version.sh (a manifest-style source).
        revalidate-hash = flake-lib.lib.mkRevalidateHash {
          inherit pkgs;
          buildAttr = "caddy";
          hashField = "hash";
        };
      in
      {
        packages = {
          inherit caddy update-version revalidate-hash;
          default = caddy;
        };
      });
}
