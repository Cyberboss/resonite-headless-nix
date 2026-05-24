{
    description = "resonite-headless-nix";

    inputs = {};

    outputs = { nixpkgs, ... }: {
        nixosModules = {
            default = { ... }: {
                imports = [ ./service.nix ];
            };
        };
    };
}
