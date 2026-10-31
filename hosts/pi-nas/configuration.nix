{ ... }:

{
  # 隔地に置く Raspberry Pi 5 の NAS。焼いたイメージで動き、ログインしないアプライアンスとする。
  # 一次側の NAS (192.168.5.30) から ZFS のスナップショットを pull で複製する。
  imports = [
    ./hardware.nix
  ];

  networking.hostName = "pi-nas";

  # ZFS が pool の持ち主を見分けるための ID。変えると pool の import に -f が要るので変えない。
  networking.hostId = "72a7a172";

  time.timeZone = "Asia/Tokyo";

  nuage.nas = {
    role = "replica";
    pool = "tank";
    replica = {
      source = {
        host = "192.168.5.30";
        # 一次側で pi-nas の pull 専用に作るユーザー。一次側では send,hold だけを渡す。
        user = "pi-nas-pull";
        # 秘密は焼くときに書き込む。Nix の store とイメージファイルには入れない。
        sshKeyFile = "/var/lib/secrets/syncoid_ed25519";
        knownHostsFile = "/var/lib/secrets/syncoid_known_hosts";
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
    # 前もって Tailnet Lock の署名をした auth key (tag:pi-nas)。焼くときに書き込む。
    # ファイルが無ければ tailscaled-autoconnect がエラーで止まる。
    authKeyFile = "/var/lib/secrets/tailscale_authkey";
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

  # 固まったらハードウェアの watchdog で再起動させる。
  # Pi の watchdog (bcm2835-wdt) は 15 秒より長くできないので、それより短くする。
  systemd.settings.Manager = {
    RuntimeWatchdogSec = "10s";
    RebootWatchdogSec = "10min";
  };

  system.stateVersion = "26.05";
}
