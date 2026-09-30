{
  description = "Pinned omnibin with nixpkgs follows, plus mcpx from dezren39/nix (used by dispatcher.sh)";

  inputs = {
    # Pinned to the exact nixpkgs rev omnibin uses, so fzakaria's cachix
    # cache hits (a floating nixos-unstable would trigger source builds).
    nixpkgs.url = "github:NixOS/nixpkgs/4975466d324710c576dc11ad614684e6bd8cad8e";
    omnibin.url = "github:fzakaria/omnibin/459dcff6ee82dd1fb7f3706c4ec5519019635a0a";
    # Use our nixpkgs for omnibin's build — one nixpkgs in the lock, not two.
    omnibin.inputs.nixpkgs.follows = "nixpkgs";
    # dezren39's nix config — we only consume its mcpx package.
    dezren39-nix.url = "github:dezren39/nix";
  };

  # Re-export omnibin's outputs (built against our nixpkgs via follows),
  # deep-merged with the mcpx package from dezren39/nix, so both
  # `this-flake#omnibin` and `this-flake#mcpx` resolve from one lockfile.
  outputs = inputs: inputs.nixpkgs.lib.recursiveUpdate inputs.omnibin.outputs {
    # dezren39's package.nix is documented pure-Go (modernc.org/sqlite chosen
    # specifically to avoid needing a C toolchain), but it doesn't set
    # CGO_ENABLED=0, and nixpkgs' buildGoModule defaults to CGO_ENABLED=1 when
    # a C compiler is present. On this machine /nix is a symlink to
    # /home/hatch/nix-persist, and the canonicalized plugin path
    # (/home/hatch/nix-persist/store/.../liblto_plugin.so) trips the linker's
    # impure-path check -> build failure (verified 2026-09-30).
    # NOTE: setting env.CGO_ENABLED via overrideAttrs does NOT work —
    # module.nix computes env from its own args
    # (CGO_ENABLED = args.env.CGO_ENABLED or go.CGO_ENABLED), clobbering the
    # override. Exporting it in preBuild runs after the builder's env setup
    # and actually wins. (Verified: the Go build itself then succeeds pure-Go.)
    # The REMAINING failure was postInstall's `wrapProgram` -> makeCWrapper,
    # which compiles a tiny C wrapper with the cc-wrapper; the linker purity
    # check rejects gcc's plugin path because gcc canonicalizes /nix through
    # the symlink (/home/hatch/nix-persist/store/... — still the real store).
    # stdenv sets NIX_ENFORCE_PURITY=1 by default; exporting 0 for this one
    # derivation is safe and honest here — the "impure" path IS the store.
    packages.x86_64-linux.mcpx =
      inputs.dezren39-nix.packages.x86_64-linux.mcpx.overrideAttrs (old: {
        preBuild = (old.preBuild or "") + "\nexport CGO_ENABLED=0\nexport NIX_ENFORCE_PURITY=0\n";
      });
  };
}
