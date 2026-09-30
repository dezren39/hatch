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
    packages.x86_64-linux.mcpx = inputs.dezren39-nix.packages.x86_64-linux.mcpx;
  };
}
