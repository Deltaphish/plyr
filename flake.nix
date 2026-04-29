{
    description = "Plyr";
    inputs = {
           nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
           zig-overlay.url = "github:mitchellh/zig-overlay";
           zls.url = "github:zigtools/zls/0.16.0";
           flake-utils.url = "github:numtide/flake-utils";
    };

    outputs = {self, nixpkgs, zig-overlay, zls, flake-utils}:
            flake-utils.lib.eachDefaultSystem (system:
             let
                pkgs = import nixpkgs {inherit system; };
                zig = zig-overlay.packages.${system}."0.16.0";

                zls-pkg = zls.packages.${system}.zls.overrideAttrs (old: {
                  nativeBuildInputs = [zig];
                });

             in {
                devShells.default = pkgs.mkShell {
                                  nativeBuildInputs = [
                                        zig
                                        zls-pkg
                                  ];
                shellHook = ''
                          echo "zig $(zig version)"
                          echo "zls $(zls --version)"
                          echo "Happy hacking..."
                          '';
                };
             });
}
