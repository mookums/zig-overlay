{
  pkgs ? import <nixpkgs> { },
  system ? builtins.currentSystem,
}:
let
  inherit (pkgs) lib;
  sources = lib.importJSON ./sources.json;

  urlsForFile =
    file:
    let
      # This is a list of known Zig nightly mirrors used by https://github.com/mlugg/setup-zig.
      # File hashes are exactly the same so `fetchurl` can try them in order.
      mirrors = lib.importJSON ./mirrors.json;
    in
    [ ("https://ziglang.org/builds/" + file) ]
    ++ map (mirror: (builtins.elemAt mirror 0) + "/" + file) mirrors;

  # mkBinaryInstall makes a derivation that installs Zig from a binary.
  mkBinaryInstall =
    {
      file ? null,
      url ? null,
      broken ? false,
      version,
      sha256,
    }:
    assert file == null -> url != null;
    pkgs.stdenv.mkDerivation (finalAttrs: {
      pname = "zig";
      inherit version;

      src = pkgs.fetchurl {
        inherit sha256;
        urls = urlsForFile (
          if file != null then
            file
          # Backwards compatibility with old sources.json
          else
            (lib.removePrefix "https://ziglang.org/builds/" url)
        );
      };

      dontConfigure = true;
      dontBuild = true;
      dontFixup = true;

      installPhase = ''
        mkdir -p $out/{doc,bin,lib}
        [ -d docs ] && cp -r docs/* $out/doc
        [ -d doc ] && cp -r doc/* $out/doc
        cp -r lib/* $out/lib
        cp zig $out/bin/zig
      '';

      passthru = {
        hook = pkgs.zig.hook.override { zig = finalAttrs.finalPackage; };
        zls =
          let
            versionMap = lib.importJSON ./zls-versions.json;
            zlsVersion =
              if (builtins.hasAttr version versionMap) then versionMap.${version}.version else throw "";
          in
          zlsPackages.${"zls-" + zlsVersion};
      };

      meta = with lib; {
        description = "General-purpose programming language and toolchain for maintaining robust, optimal, and reusable software";
        homepage = "https://ziglang.org/";
        license = licenses.mit;
        maintainers = [ ];
        platforms = platforms.unix;
        inherit broken;
      };
    });

  # The packages that are tagged releases
  taggedPackages = lib.attrsets.mapAttrs (k: v: mkBinaryInstall v.${system}) (
    lib.attrsets.filterAttrs
      (
        k: v:
        (builtins.hasAttr system v)
        # && (v.${system}.url != null)
        && (v.${system}.sha256 != null)
        && !(lib.strings.hasSuffix "mach" k)
      )
      (
        builtins.removeAttrs sources [
          "master"
          "mach-latest"
        ]
      )
  );

  # The master packages
  masterPackages =
    lib.attrsets.mapAttrs'
      (
        k: v:
        lib.attrsets.nameValuePair (if k == "latest" then "master" else v.${system}.version) (
          mkBinaryInstall v.${system}
        )
      )
      (
        lib.attrsets.filterAttrs (
          k: v:
          (builtins.hasAttr system v) && (builtins.hasAttr "url" v.${system}) && (v.${system}.url != null)
        ) sources.master
      );

  # Mach nominated versions
  # https://machengine.org/docs/nominated-zig/
  machPackages = lib.attrsets.mapAttrs (k: v: mkBinaryInstall v.${system}) (
    lib.attrsets.filterAttrs (k: v: lib.strings.hasSuffix "mach" k) (
      builtins.removeAttrs sources [ "master" ]
    )
  );

  # This determines the latest /released/ version.
  latest = lib.lists.last (
    builtins.sort (x: y: (builtins.compareVersions x y) < 0) (builtins.attrNames taggedPackages)
  );

  # Latest Mach nominated version
  machLatest = lib.lists.last (
    builtins.sort (x: y: (builtins.compareVersions x y) < 0) (builtins.attrNames machPackages)
  );

  mkBinaryZls =
    {
      url,
      sha256,
      version,
    }:
    pkgs.stdenv.mkDerivation {
      pname = "zls";
      inherit version;

      src = pkgs.fetchurl { inherit url sha256; };
      sourceRoot = ".";

      dontConfigure = true;
      dontBuild = true;
      dontFixup = true;

      installPhase = ''
        mkdir -p $out/bin
        cp zls $out/bin
      '';
    };

  zlsPackages =
    let
      sources = lib.importJSON ./zls-sources.json;
      zigSystem = if lib.hasSuffix system "darwin" then (lib.removeSuffix "darwin") + "macos" else system;
    in
    lib.mapAttrs' (
      n: v:
      lib.nameValuePair ("zls-" + n) (mkBinaryZls {
        inherit (v) version;
        url = v.${zigSystem}.tarball;
        sha256 = v.${zigSystem}.shasum;
      })
    ) sources;

  zlsLatest = lib.lists.last (
    builtins.sort (x: y: (builtins.compareVersions x y) < 0) (
      builtins.filter (v: !lib.hasInfix "dev" v) (builtins.attrNames zlsPackages)
    )
  );

  zlsMaster = lib.lists.last (
    builtins.sort (x: y: (builtins.compareVersions x y) < 0) (builtins.attrNames zlsPackages)
  );
in
# We want the packages but also add a "default" that just points to the
# latest released version.
lib.mapAttrs' (k: v: lib.nameValuePair (lib.replaceStrings [ "." "+" ] [ "_" "_" ] k) v) (
  taggedPackages
  // masterPackages
  // machPackages
  // zlsPackages
  // {
    "default" = taggedPackages.${latest};
    mach-latest = machPackages.${machLatest};
    zls-latest = zlsPackages.${zlsLatest};
    zls-master = zlsPackages.${zlsMaster};
  }
)
