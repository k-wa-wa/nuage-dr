{
  description = "隔地の Raspberry Pi (DR 環境) の NixOS 構成と、一次側と共有する NAS モジュール";

  # nixos-raspberrypi のバイナリキャッシュ。Pi 用のカーネルとファームウェアを手元でビルドしないために使う。
  # 手元で SD イメージを作るときは `--accept-flake-config` を付ける。
  # Pi の上の nix には、nixos-raspberrypi.lib.nixosSystem が同じキャッシュを設定する (trusted-nix-caches)。
  nixConfig = {
    extra-substituters = [
      "https://nixos-raspberrypi.cachix.org"
    ];
    extra-trusted-public-keys = [
      "nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI="
    ];
  };

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";

    # Pi 5 のカーネル・ファームウェア・ブートローダーと SD イメージを作るモジュール。
    # キャッシュに当たるよう、nixpkgs は nixos-raspberrypi の flake.lock と同じ版に合わせて固定する。
    nixos-raspberrypi = {
      url = "github:nvmd/nixos-raspberrypi";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixos-raspberrypi,
      ...
    }:
    let
      lib = nixpkgs.lib;
      piNas = self.nixosConfigurations.pi-nas;

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
      # 一次側 (nuage-cluster の nas) と二次側 (pi-nas) で共有する NAS のモジュール。
      # nixos-raspberrypi に依存させない。nuage-cluster は x86_64 でこれを読む。
      nixosModules.nas = ./modules/nas;

      nixosConfigurations.pi-nas = nixos-raspberrypi.lib.nixosSystem {
        modules = [
          nixos-raspberrypi.nixosModules.raspberry-pi-5.base
          nixos-raspberrypi.nixosModules.sd-image
          self.nixosModules.nas
          ./modules/auto-upgrade.nix
          ./hosts/pi-nas/configuration.nix
        ];
      };

      packages.aarch64-linux = {
        pi-nas-sd-image = piNas.config.system.build.sdImage;

        # pi-nas の pool を作るときに、同じ Pi で起動する installer のイメージ (README の「pool を作る」)。
        # nixos-raspberrypi が出すものをそのまま出す。pi-nas の構成とは混ぜない。
        # nixpkgs を follows でそろえているので、ZFS の版が pi-nas と同じになる。
        rpi5-installer-sd-image = nixos-raspberrypi.installerImages.rpi5;
      };

      formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixfmt-tree;

      # aarch64 のビルドが要るものは入れない。評価だけで確かめる。
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

          # pi-nas の構成が評価できることを確かめる (ビルドはしない)。
          pi-nas-eval = pkgs.writeText "pi-nas-drv-path" (
            builtins.unsafeDiscardStringContext piNas.config.system.build.toplevel.drvPath
          );
        };
    };
}
