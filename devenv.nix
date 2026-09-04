{
  inputs,
  lib,
  pkgs,
  ...
}: let
  linuxLibraries = with pkgs;
    lib.optionals stdenv.isLinux [
      fontconfig
      libx11
      libxcb
      libxkbcommon
      vulkan-loader
      wayland
    ];
in {
  packages =
    (with pkgs; [
      clang
      git
      libclang
      openssl
      pkg-config
    ])
    ++ linuxLibraries;

  languages.rust.enable = true;

  env = {
    HELIX_DISABLE_AUTO_GRAMMAR_BUILD = "1";
    HELIX_RUNTIME = "${inputs.helix}/runtime";
    LIBCLANG_PATH = "${pkgs.libclang.lib}/lib";
    LD_LIBRARY_PATH = lib.makeLibraryPath linuxLibraries;
    RUST_BACKTRACE = "1";
  };

  tasks."project:check".exec = "cargo check --all-targets";
  tasks."project:test".exec = "cargo test --all-targets";
  tasks."project:run".exec = "cargo run --bin hxg";
}
