{
  config,
  lib,
  ...
}:

let
  cfg = config.nuage.nas;
in
{
  # 一次側 (source) と二次側 (replica) で共有する NAS のモジュール。
  # 役ごとの中身は別のファイルに分け、ここでは役によらない option と pool の import だけを扱う。
  # source の役は、一次側の NAS を NixOS に移すときに source.nix として足す。
  imports = [
    ./replica.nix
  ];

  options.nuage.nas = {
    role = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [ "replica" ]);
      default = null;
      example = "replica";
      description = ''
        この NAS の役。replica は一次側から syncoid で pull して、sanoid で世代を管理する。
      '';
    };

    pool = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "tank";
      description = ''
        データを置く ZFS の pool の名前。pool は宣言で作らず、起動時に import するだけにする。
        最初の 1 回だけ手で `zpool create` する (README を見る)。
      '';
    };
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = cfg.role != null;
          message = "nuage.nas.role が無い。この NAS の役 (\"replica\" など) を選ぶ。";
        }
        {
          assertion = cfg.pool != null;
          message = "nuage.nas.pool が無い。データを置く ZFS の pool の名前を渡す。";
        }
      ];
    }

    (lib.mkIf (cfg.pool != null) {
      boot.supportedFilesystems = [ "zfs" ];

      # データの pool は宣言で作らず、起動時に import するだけにする。
      boot.zfs.extraPools = [ cfg.pool ];

      # データの pool は -f を付けずに import する (forceImportAll の既定値 false のまま)。他のホストで import された pool を黙って奪わない。
      # root を ZFS に置かないので forceImportRoot は効かないが、26.11 の既定値 false にそろえて警告を消す。
      boot.zfs.forceImportRoot = false;
    })
  ];
}
