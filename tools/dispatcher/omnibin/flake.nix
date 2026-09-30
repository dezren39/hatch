{
  description = "Pinned omnibin with nixpkgs follows (used by dispatcher.sh)";

  inputs = {
    # Pinned to the exact nixpkgs rev omnibin uses, so fzakaria's cachix
    # cache hits (a floating nixos-unstable would trigger source builds).
    nixpkgs.url = "github:NixOS/nixpkgs/4975466d324710c576dc11ad614684e6bd8cad8e";
    omnibin.url = "github:fzakaria/omnibin/459dcff6ee82dd1fb7f3706c4ec5519019635a0a";
    # Use our nixpkgs for omnibin's build — one nixpkgs in the lock, not two.
    omnibin.inputs.nixpkgs.follows = "nixpkgs";
  };

  # Re-export omnibin's outputs (built against our nixpkgs via follows),
  # so `this-flake#omnibin` resolves exactly like `omnibin#omnibin`.
  outputs = inputs: inputs.omnibin.outputs;
}
