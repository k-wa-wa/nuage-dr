{ ... }:

{
  # 隔地に置く x86 の小型 NAS。焼いたイメージで動き、ログインしないアプライアンスとする。
  # 一次側の NAS (192.168.5.30) から ZFS のスナップショットを pull で複製する。
  imports = [
    ./hardware.nix
  ];

  networking.hostName = "dr-nas";

  # ZFS が pool の持ち主を見分けるための ID。変えると pool の import に -f が要るので変えない。
  networking.hostId = "2baa868f";

  time.timeZone = "Asia/Tokyo";

  nuage.nas = {
    role = "replica";
    pool = "tank";
    replica = {
      source = {
        host = "192.168.5.30";
        # 一次側で dr-nas の pull 専用に作るユーザー。一次側では send,hold だけを渡す。
        user = "dr-nas-pull";
        # 秘密は焼いたあとに ESP の secrets/ へ書き込む (hardware.nix)。Nix の store とイメージファイルには入れない。
        sshKeyFile = "/boot/secrets/syncoid_ed25519";
        knownHostsFile = "/boot/secrets/syncoid_known_hosts";
      };
      # 仮置き。一次側の NAS を NixOS に移し、暗号化した dataset を作ったら、その名前に合わせる。
      datasets = [ "pool-1/enc" ];
    };
  };

  # ユーザーは宣言の中身だけにする。動いている間に足されたユーザーやパスワードは、次の切り替えで消える。
  users.mutableUsers = false;
  # 意図して誰もログインできなくしている。ログインしないアプライアンスなので、パスワードも SSH の鍵も持つユーザーを置かない。
  # NixOS は締め出しを防ぐ assertion で止めるので、それを外す。
  users.allowNoPasswordLogin = true;

  # 待ち受け: 何も受けない。SSH も開けない。
  services.openssh.enable = false;
  networking.firewall.enable = true;

  # 拠点間は Tailscale で結ぶ。--shields-up で、Tailscale から受ける通信をすべて拒否する。
  # 一次側の NAS へは自宅の subnet router を通るので、経路を受け入れる (--accept-routes)。
  services.tailscale = {
    enable = true;
    # 前もって Tailnet Lock の署名をした auth key (tag:dr-nas)。焼いたあとに書き込む。
    # ファイルが無ければ tailscaled-autoconnect がエラーで止まる。
    authKeyFile = "/boot/secrets/tailscale_authkey";
    useRoutingFeatures = "client";
    extraUpFlags = [
      "--shields-up"
      "--accept-routes"
    ];
    # ログイン済みで tailscale up を通らない起動でも、毎回同じ設定にそろえる。
    extraSetFlags = [
      "--shields-up"
      "--accept-routes"
    ];
  };

  # 固まったらハードウェアの watchdog (x86 では iTCO_wdt など) で再起動させる。使えるかは機種で確かめる。
  systemd.settings.Manager = {
    RuntimeWatchdogSec = "30s";
    RebootWatchdogSec = "10min";
  };

  system.stateVersion = "26.05";
}
