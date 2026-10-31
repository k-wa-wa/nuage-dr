{ config, ... }:

{
  # 隔地の機器の更新の経路。nuage-dr の master を取り込む。
  # 取り込みの設定はこのファイルにだけ置く。あとで署名タグ (git verify-tag) を確かめてから取り込む形に、ここだけを差し替える。
  # master に入れられるのは k-wa-wa だけで、bot は PR までである (AGENTS.md)。
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  system.autoUpgrade = {
    enable = true;
    flake = "github:k-wa-wa/nuage-dr#${config.networking.hostName}";
  };
}
