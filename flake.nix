{
  description = "resonite-headless-nix";

  inputs = { };

  outputs = { ... }: {
    nixosModules = {
      default = { ... }: {
        imports = [ ./service.nix ];
      };
    };
  };
}
