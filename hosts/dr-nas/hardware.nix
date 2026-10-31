{ ... }:

{
  # x86 の 2 ベイの小型機 (N100・N150 など) に、2 台の HDD を mirror でつなぐ。機種は未決で、届いたら見直す。
  # データのディスクは宣言で扱わない (pool は docs/dr-nas-setup.md の手順で手で作り、boot.zfs.extraPools で import するだけにする)。

  boot.initrd.availableKernelModules = [
    "nvme"
    "ahci"
    "xhci_pci"
    "usb_storage"
    "sd_mod"
  ];
  hardware.enableRedistributableFirmware = true;
  hardware.cpu.intel.updateMicrocode = true;

  # 起動用の NVMe は、raw-efi のイメージ (ESP と ext4 の root) を焼いたものである。
  # ラベルはイメージ (nixpkgs の virtualisation/disk-image.nix) が付けるものに合わせる。
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
    autoResize = true;
  };
  # ESP には秘密 (secrets/) も置く。FAT は持ち主を持たないので、マスクで root だけが読めるようにする。
  fileSystems."/boot" = {
    device = "/dev/disk/by-label/ESP";
    fsType = "vfat";
    options = [
      "fmask=0077"
      "dmask=0077"
    ];
  };
  # 初回の起動で、root のパーティションを NVMe の全体に広げる。
  boot.growPartition = true;

  boot.loader.systemd-boot.enable = true;
  # 焼いたイメージは EFI の既定のパス (EFI/BOOT/BOOTX64.EFI) で起動する。NVRAM には書かない。
  boot.loader.efi.canTouchEfiVariables = false;
  # イメージの ESP は 256MiB しかない。世代を増やしすぎて更新が止まらないよう、起動の項目の数を絞る。
  boot.loader.systemd-boot.configurationLimit = 3;
}
