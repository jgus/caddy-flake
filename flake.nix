{
  description = "Caddy with selected plugins (cloudflare DNS, rate-limit, cache-handler).";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
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
      in
      {
        packages = {
          inherit caddy update-version;
          default = caddy;
        };
      });
}
