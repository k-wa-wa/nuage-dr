{
  description = "隔地 (DR 環境) の機器の NixOS 構成と、一次側と共有する NAS モジュール";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
  };

  outputs =
    {
      self,
      nixpkgs,
      ...
    }:
    let
      lib = nixpkgs.lib;
      drNas = self.nixosConfigurations.dr-nas;

      # nixosModules.nas の assertion を確かめるための、最小の x86_64 の構成。
      evalNas =
        nas:
        lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            self.nixosModules.nas
            {
              boot.loader.grub.enable = false;
              fileSystems."/" = {
                device = "none";
                fsType = "tmpfs";
              };
              networking.hostId = "00000000";
              system.stateVersion = "26.05";
              nuage.nas = nas;
            }
          ];
        };

      failedAssertions =
        nas:
        let
          cfg = (evalNas nas).config;
        in
        map (a: a.message) (lib.filter (a: !a.assertion) cfg.assertions);
    in
    {
      # 一次側 (nuage-cluster の nas) と二次側 (dr-nas) で共有する NAS のモジュール。
      # 機種に固有の設定は入れない。機種の設定は hosts/ に置く。
      nixosModules.nas = ./modules/nas;

      nixosConfigurations = {
        dr-nas = lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            self.nixosModules.nas
            ./modules/auto-upgrade.nix
            ./hosts/dr-nas/configuration.nix
          ];
        };

        # dr-nas の pool を作るときに、同じ機械で起動する installer (docs/dr-nas-setup.md)。
        # dr-nas の構成とは混ぜない。同じ nixpkgs から作るので、ZFS の版が dr-nas と同じになる。
        dr-nas-installer = lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
          ];
        };
      };

      packages.x86_64-linux = {
        # 起動用の NVMe に焼く raw のイメージ (ESP と ext4 の root)。
        dr-nas-image = drNas.config.system.build.images.raw-efi;
        dr-nas-installer-iso = self.nixosConfigurations.dr-nas-installer.config.system.build.isoImage;
      };

      formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixfmt-tree;

      # 評価だけで確かめる。ビルドは CI と手元で行う。
      checks.x86_64-linux =
        let
          pkgs = nixpkgs.legacyPackages.x86_64-linux;

          # 必要な option を渡さないときに、assertion がそれぞれ落ちることを確かめる。
          missing = failedAssertions { role = "replica"; };
          expectFailed =
            needle:
            lib.assertMsg (lib.any (lib.hasInfix needle) missing) "nuage.nas: ${needle} の assertion が落ちていない";
          expectedNeedles = [
            "nuage.nas.pool"
            "nuage.nas.replica.source.host"
            "nuage.nas.replica.source.user"
            "nuage.nas.replica.source.sshKeyFile"
            "nuage.nas.replica.source.knownHostsFile"
            "nuage.nas.replica.datasets"
          ];

          # 役を選ばないときも落ちる。
          noRole = failedAssertions { };
        in
        {
          nas-assertions =
            assert lib.all expectFailed expectedNeedles;
            assert lib.assertMsg (lib.any (lib.hasInfix "nuage.nas.role") noRole)
              "nuage.nas: role の assertion が落ちていない";
            pkgs.runCommand "nas-assertions" { } ''
              cat > $out <<'EOF'
              ${lib.concatStringsSep "\n" missing}
              EOF
            '';

          # dr-nas の構成が評価できることを確かめる (ビルドはしない)。
          dr-nas-eval = pkgs.writeText "dr-nas-drv-path" (
            builtins.unsafeDiscardStringContext drNas.config.system.build.toplevel.drvPath
          );
        };
    };
}
