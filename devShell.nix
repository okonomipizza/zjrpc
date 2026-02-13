{
  mkShell,
  zig,
  zls,
}:
  mkShell {
    name = "zig-dev";
    packages = [
      zig
      zls
    ];

    shellHook = ''
      echo "Development environment loaded!"
      echo ""
      echo "  Zig: $(zig version)"
      echo ""
    '';
  }
