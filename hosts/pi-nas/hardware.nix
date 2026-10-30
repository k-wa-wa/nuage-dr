{ ... }:

{
  # 仮置き: Radxa Penta SATA HAT (PCIe の SATA) に、2 台の HDD を mirror でつなぐ。
  # データのディスクは宣言で扱わない (pool は README の手順で手で作り、boot.zfs.extraPools で import するだけにする)。
  # ディスクの by-id は届いてから README の手順に書く。

  # Pi 5 の外向きの PCIe (FPC コネクタ) を有効にする。SATA HAT はここにつながる。
  hardware.raspberry-pi.config.all.base-dt-params.pciex1 = {
    enable = true;
    value = "on";
  };
}
