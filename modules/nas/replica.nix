{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.nuage.nas;
  rcfg = cfg.replica;
  src = rcfg.source;

  isReplica = cfg.role == "replica";

  # 必要な値がそろったときだけ中身を作る。欠けていれば assertion で落ちる。
  ready =
    cfg.pool != null
    && src.host != null
    && src.user != null
    && isSecretPath src.sshKeyFile
    && isSecretPath src.knownHostsFile
    && rcfg.datasets != null;

  # 秘密はファイルのパスで受け取る。store のパスを渡されたら、秘密が store に入っているので拒む。
  isSecretPath = p: p != null && lib.hasPrefix "/" p && !lib.hasPrefix builtins.storeDir p;

  # 一次側の dataset を、同じ名前で pool の下に受ける (例: pool-1/enc → tank/pool-1/enc)。
  targetOf = dataset: "${cfg.pool}/${dataset}";

  # syncoid のユニットに LoadCredential で渡す名前。ExecStart では %d (credentials のディレクトリ) から読む。
  sshKeyCredential = "syncoid_ssh_key";
  knownHostsCredential = "syncoid_known_hosts";

  # 秘密のファイルが無ければ、何が無いかを書いて失敗する。syncoid のユニットはこれに requires で依存する。
  checkSecrets = pkgs.writeShellScript "nas-replica-check-secrets" ''
    missing=0
    for f in ${
      lib.escapeShellArgs [
        src.sshKeyFile
        src.knownHostsFile
      ]
    }; do
      if [ ! -s "$f" ]; then
        echo "nas-replica: 秘密のファイル $f が無い (または空である)。ホストの手順 (dr-nas は docs/dr-nas-setup.md) のとおりに置く。" >&2
        missing=1
      fi
    done
    exit "$missing"
  '';

  # hold を付け外しするスクリプト。中身と理由は replica-hold.sh に書く。
  holdScript = pkgs.writeShellApplication {
    name = "nas-replica-hold";
    runtimeInputs = [
      config.boot.zfs.package
      pkgs.coreutils
    ];
    text = builtins.readFile ./replica-hold.sh;
  };

  holdStateDirectory = "nas-replica-hold";

  syncoidUnits = map (dataset: "syncoid-${escapeUnitName dataset}.service") rcfg.datasets;

  # services.syncoid がユニットの名前を作るときと同じ規則で、dataset の名前を書き換える。
  escapeUnitName =
    name:
    lib.concatMapStrings (s: if lib.isList s then "-" else s) (
      builtins.split "[^a-zA-Z0-9_.\\-]+" name
    );
in
{
  options.nuage.nas.replica = {
    source = {
      host = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "192.168.5.30";
        description = "pull する一次側の NAS のホスト名か IP アドレス。";
      };

      user = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "dr-nas-pull";
        description = ''
          一次側の NAS で pull に使うユーザー。一次側では `zfs allow` で `send,hold` だけを渡す。
          スナップショットを取る権限が無いので、syncoid は `--no-sync-snap` で一次側の sanoid のスナップショットを送る。
        '';
      };

      sshKeyFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "/var/lib/secrets/syncoid_ed25519";
        description = ''
          一次側へ SSH で入る秘密鍵のファイルのパス。Nix の store に入れないよう、文字列のパスで渡す。
          ファイルが無ければ syncoid のユニットはエラーで止まる。
        '';
      };

      knownHostsFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "/var/lib/secrets/syncoid_known_hosts";
        description = ''
          一次側の SSH のホスト鍵を書いた known_hosts のファイルのパス。ホスト鍵を確かめずにはつながない。
          ファイルが無ければ syncoid のユニットはエラーで止まる。
        '';
      };
    };

    datasets = lib.mkOption {
      type = lib.types.nullOr (lib.types.listOf lib.types.str);
      default = null;
      example = [ "pool-1/enc" ];
      description = ''
        複製する一次側の dataset の一覧。子の dataset も含めて (recursive で) 受ける。
        受け先は `<pool>/<一次側の dataset>` になる。受け先の親 (例: `tank/pool-1`) は前もって作っておく。
      '';
    };

    retention = {
      hourly = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 24;
        description = "残す hourly のスナップショットの数。";
      };
      daily = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 30;
        description = "残す daily のスナップショットの数。";
      };
      monthly = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 12;
        description = "残す monthly のスナップショットの数。";
      };
    };

    hold = {
      intervalDays = lib.mkOption {
        type = lib.types.ints.positive;
        default = 30;
        description = ''
          hold (`nuage-keep-YYYY-MM`) を付ける間隔の日数。前に付けてから、Pi が動いていた時間の合計がこの日数になったら、
          そのとき最新の受け取り済みスナップショットに次の hold を付ける。
          経過は monotonic の時計 (CLOCK_BOOTTIME) で測り、壁時計は使わない。NTP で時計を進められても、hold は早く付かない。
          止まっていた時間 (再起動をまたいだ分) は数えないので、止まった分だけ遅れる。
        '';
      };

      keep = lib.mkOption {
        type = lib.types.ints.positive;
        default = 13;
        description = ''
          残す hold の数。受け取った順 (createtxg) で新しい方からこの数を残し、それより古い hold を外す。
          外すかどうかは数だけで決め、壁時計とタグの年月は使わない。
          一次側が偽のスナップショットを大量に流しても、sanoid に hold のかかった世代を消させないためである。
        '';
      };
    };
  };

  config = lib.mkIf isReplica (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = src.host != null;
            message = "nuage.nas.replica.source.host が無い。pull する一次側の NAS のホストを渡す。";
          }
          {
            assertion = src.user != null;
            message = "nuage.nas.replica.source.user が無い。一次側の NAS で pull に使うユーザーを渡す。";
          }
          {
            assertion = isSecretPath src.sshKeyFile;
            message = "nuage.nas.replica.source.sshKeyFile が無いか、store のパスである。store の外の絶対パスを文字列で渡す。";
          }
          {
            assertion = isSecretPath src.knownHostsFile;
            message = "nuage.nas.replica.source.knownHostsFile が無いか、store のパスである。store の外の絶対パスを文字列で渡す。";
          }
          {
            assertion = rcfg.datasets != null && rcfg.datasets != [ ];
            message = "nuage.nas.replica.datasets が無い。複製する一次側の dataset を 1 つ以上渡す。";
          }
        ];
      }

      (lib.mkIf ready {
        # 受けた dataset の鍵は、起動時に読み込まない。読み込もうとすると、鍵を聞いて起動が止まる。
        boot.zfs.requestEncryptionCredentials = false;

        # 複製: 一次側から pull する。暗号化した dataset を raw send (-w) で受け、受けた dataset は mount しない (-u)。
        services.syncoid = {
          enable = true;
          sshKey = "%d/${sshKeyCredential}";
          # 受け側で syncoid のユーザーに渡す権限。nixpkgs の既定から rollback を外す。
          # --no-rollback で zfs receive に -F を付けないので、巻き戻しの権限は要らない。
          # 持たせないことで、syncoid の側から受け側の世代を巻き戻せないようにする。
          localTargetAllow = [
            "change-key"
            "compression"
            "create"
            "mount"
            "mountpoint"
            "receive"
          ];
          commonArgs = [
            # 一次側のユーザーにはスナップショットを取る権限が無い。一次側の sanoid が取ったものを送る。
            "--no-sync-snap"
            # 受け側を巻き戻さない (zfs receive に -F を付けない)。既定の -F では、一次側で新しい世代を消して送り直されると、
            # 受け側でも共通の世代より新しい分が消える。巻き戻しが要るときは、syncoid がエラーで止まり、ユニットが失敗する。
            "--no-rollback"
            # pv を挟まない (--quiet のときだけ、syncoid は送受信の間に pv を挟まない)。pv 1.10 は入力が終わると、出力の pipe が
            # 空になるまで待つ。zfs receive が失敗して読み残したまま終わると、pv が終わらず、syncoid もユニットも止まったまま残る。
            # --quiet で消えるのは INFO と WARNING の出力だけで、失敗 (CRITICAL と zfs receive のエラー) は journal に残る。
            "--quiet"
            "--sshoption=StrictHostKeyChecking=yes"
            "--sshoption=UserKnownHostsFile=%d/${knownHostsCredential}"
          ];
          commands = lib.listToAttrs (
            map (
              dataset:
              lib.nameValuePair dataset {
                source = "${src.user}@${src.host}:${dataset}";
                target = targetOf dataset;
                recursive = true;
                sendOptions = "w";
                recvOptions = "u";
                service = {
                  requires = [ "nas-replica-secrets.service" ];
                  after = [ "nas-replica-secrets.service" ];
                  serviceConfig.LoadCredential = [
                    "${sshKeyCredential}:${src.sshKeyFile}"
                    "${knownHostsCredential}:${src.knownHostsFile}"
                  ];
                };
              }
            ) rcfg.datasets
          );
        };

        # syncoid の前に秘密のファイルがあるかを確かめる。無ければこのユニットが失敗し、syncoid も動かない。
        systemd.services.nas-replica-secrets = {
          description = "syncoid の秘密のファイルがあるかを確かめる";
          serviceConfig = {
            Type = "oneshot";
            ExecStart = checkSecrets;
          };
        };

        # hold: syncoid のあと、sanoid の前に走らせ、受け取ったスナップショットに hold を付け外しする。
        # 付ける間隔は Pi が動いていた時間 (monotonic の時計) で測り、外すのは数で決める。壁時計は使わない。
        # hold のかかったスナップショットは、sanoid が消そうとしても消えない (sanoid は警告を出して続け、ユニットは失敗しない)。
        systemd.services.nas-replica-hold = {
          description = "受け取ったスナップショットに hold を付け外しする";
          after = [ "zfs.target" ] ++ syncoidUnits;
          # sanoid も同じ時刻に起動する。hold を付け外しする間に、sanoid が一覧したスナップショットを消さないよう、先に走らせる。
          before = [ "sanoid.service" ];
          startAt = config.services.syncoid.interval;
          serviceConfig = {
            Type = "oneshot";
            # 前に付けてからの経過を積み上げる状態を置く (/var/lib/nas-replica-hold)。
            StateDirectory = holdStateDirectory;
            StateDirectoryMode = "0700";
            ExecStart = lib.escapeShellArgs (
              [
                (lib.getExe holdScript)
                "/var/lib/${holdStateDirectory}"
                (toString (rcfg.hold.intervalDays * 24 * 60 * 60))
                (toString rcfg.hold.keep)
              ]
              ++ map targetOf rcfg.datasets
            );
          };
        };

        # 世代: 世代の決まりは replica の側にだけ置く。ここではスナップショットを取らず、受けた分の古いものを消すだけにする。
        services.sanoid = {
          enable = true;
          datasets = lib.listToAttrs (
            map (
              dataset:
              lib.nameValuePair (targetOf dataset) {
                recursive = true;
                autosnap = false;
                autoprune = true;
                frequently = 0;
                inherit (rcfg.retention) hourly daily monthly;
                weekly = 0;
                yearly = 0;
              }
            ) rcfg.datasets
          );
        };
      })
    ]
  );
}
