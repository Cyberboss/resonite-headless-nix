# Resonite Headless Server for Nix

This uses [DepotDownloader](https://github.com/steamre/depotdownloader) and .NET to execute a resonite-headless server.

It runs as a systemd service and automatically updates on a timer.

Optionally supports [ResoniteModLoader](https://github.com/resonite-modding-group/ResoniteModLoader) mods.

## Basic example

`flake.nix`
```nix
{
    inputs = {
        resonite-headless.url = "github:Cyberboss/resonite-headless-nix";
    };
}
```

Optionally pin to a semantically versioned tag.
A Nixpkgs reference is, for all intents and purposes, also required.

`resonite.nix`
```nix
{ inputs, ... }:
{
    imports = [
        inputs.resonite-headless.nixosModules.default
    ];

    services.resonite-headless = {
        depotdownloader-env-file = "/run/secrets/depotdownloader.env"; # Set DEPOT_DOWNLOADER_USERNAME, DEPOT_DOWNLOADER_PASSWORD to a burner steam account with Resonite added and steam guard disabled. Set DEPOT_DOWNLOADER_BETA_PASSWORD to the headless code
        credentials-file = "/run/secrets/resonite-credentials.env"; # Set RESONITE_USERNAME and RESONITE_PASSWORD for the headless account.
        auto-update-interval = "30m"; # How often the headless checks for steam updates and attempts to restart the systemd service. See 
        config-json = {
            # See https://wiki.resonite.com/Headless_server_software/Configuration_file
            # This structure maps directly to the JSON with some exceptions:
            # loginCredential and loginPassword are configured later using credentials-file and are not allowed
            # dataFolder and cacheFolder map to the systemd service user's home directory under ~/data and ~/cache respectively
            # logFolder maps to /var/log/resonite-headless by default
            
            "$schema" = "https://raw.githubusercontent.com/Yellow-Dog-Man/JSONSchemas/main/schemas/HeadlessConfig.schema.json";
            sessionName = "My Example Headless";
            loadWorldUrl = "resrec:///U-Purpzie/R-ad6a1712-ec7d-45ef-8279-fad21871a7ec"; # Purpzie's Grid
            description = "According to all known laws of aviation, there is no way a bee should be able to fly.";
            defaultUserRoles = {
                YourMainAccountUserName = "Admin";
            };
            saveOnExit = false;
            autoSleep = true;
            hideFromPublicListing = false;
            accessLevel = "ContactsPlus";
        };
    };
}
```

Sample .env files:
`depotdownloader.env`
```env
DEPOT_DOWNLOADER_USERNAME=my_burner_steam_account_with_resonite_added_and_no_steam_guard
DEPOT_DOWNLOADER_PASSWORD=my_burner_steam_account_password
DEPOT_DOWNLOADER_BETA_PASSWORD=CurrentResoniteHeadlessCode_SupportYDMSOnStripe!
```

`resonite-credentials.env`
```env
RESONITE_USERNAME="My Resonite Headless Account Username"
RESONITE_PASSWORD="My Resonite Headless Account Password"
```

See a more complete example with mods [here](https://github.com/Cyberboss/cyberservermkii/blob/main/system/resonite.nix).

Full options specifcation can be found in [service.nix](./service.nix).

Mods built from source support coming soon: #1
