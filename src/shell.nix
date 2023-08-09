{ nixpkgs ? import <nixpkgs> {}}: nixpkgs.mkShell {
  buildInputs = with nixpkgs; [];
  shellHook = ''
    complete  -C "../zig-out/bin/penzai" "penzai"
  '';
}
