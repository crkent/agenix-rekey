self: appHostPkgs: nixosConfigurations: agePackage: let
  inherit
    (appHostPkgs.lib)
    flip
    nameValuePair
    removeSuffix
    ;
  mkApp = drv: {
    type = "app";
    program = "${drv}";
  };
  args = {
    inherit self nixosConfigurations;
    inherit (appHostPkgs) lib;
    pkgs = appHostPkgs;
    inherit agePackage;
  };
  apps = [
    ./_rekey-save-outputs.nix
    ./edit-secret.nix
    ./generate-secrets.nix
    ./rekey.nix
  ];
in
  builtins.listToAttrs (flip map apps (
    appPath:
      nameValuePair
      (removeSuffix ".nix" (builtins.baseNameOf appPath))
      (mkApp (import appPath args))
  ))
