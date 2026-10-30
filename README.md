# nuage-dr

自宅の環境が丸ごと失われてもデータを失わないための、実家 (別の拠点) に置く Raspberry Pi の NixOS 構成である。
あわせて、一次側の NAS と共有する NAS のモジュール (`nixosModules.nas`) を置く。全体の計画は nuage-cluster の `docs/dr-plan.md` にある。

| ホスト | 役 | 状態 |
| :-- | :-- | :-- |
| `pi-nas` | Raspberry Pi 5 の NAS。一次側の NAS (`192.168.5.30`) から ZFS のスナップショットを pull で複製する | 構成あり |
| `pi-1`〜`pi-3` | DR 用の計算 (k3s) | まだ無い |

一次側の NAS は nuage-cluster に置き、このリポジトリを flake input として読む。逆向きにはしない。

## pi-nas

焼いたイメージで動き、ログインしないアプライアンスとする。

| 項目 | 中身 |
| :-- | :-- |
| ハードウェア | Raspberry Pi 5 + Radxa Penta SATA HAT (仮置き)。HDD 2 台を mirror にする |
| 複製 | syncoid が 1 時間ごとに一次側から pull する。暗号化した dataset を raw send (`zfs send -w`) で受け、鍵は読み込まない。受けた dataset は mount しない |
| 世代 | sanoid が受けたスナップショットの古いものを消す。pi-nas ではスナップショットを取らない |
| 待ち受け | SSH は無効。firewall は既定で拒否。Tailscale は `--shields-up` で、受ける通信をすべて拒否する |
| 更新 | nuage-dr の master を `system.autoUpgrade` で毎日取り込む (`github:k-wa-wa/nuage-dr#pi-nas`) |
| watchdog | ハードウェアの watchdog を有効にし、固まったら再起動させる (`RuntimeWatchdogSec = 10s`) |
| 停電 | Pi 5 は通電すると自動で起動する。停電から戻れば、そのまま動き出す |

### 世代の決まり

世代の決まりは pi-nas の側にだけ置く。一次側の sanoid が取ったスナップショットのうち、次の数を残す。
変えるときは `nuage.nas.replica.retention` を書く。

| 種類 | 既定値 |
| :-- | :-- |
| hourly | 24 |
| daily | 30 |
| monthly | 12 |

### 秘密

秘密は Nix の store とイメージファイルに入れず、次のファイルとして置く。ファイルが無ければ、使うユニットがエラーで止まる。

| ファイル | 中身 | 無いときに止まるユニット |
| :-- | :-- | :-- |
| `/var/lib/secrets/syncoid_ed25519` | 一次側の NAS の pull 用のユーザー (`pi-nas-pull`) に入る SSH の秘密鍵 | `nas-replica-secrets` (と syncoid) |
| `/var/lib/secrets/syncoid_known_hosts` | 一次側の NAS のホスト鍵 (`192.168.5.30 ssh-ed25519 AAAA...`) | `nas-replica-secrets` (と syncoid) |
| `/var/lib/secrets/tailscale_authkey` | Tailscale の auth key。`tag:pi-nas` を付け、Tailnet Lock の署名を前もってしておく | `tailscaled-autoconnect` |

焼くときに SD のシークレット用のパーティションへ書き込む方針である。その仕組みはまだ無いので、今は焼いたあとの SD の root のパーティション (ラベル `NIXOS_SD`) に、手で置く。

```bash
sudo mount /dev/disk/by-label/NIXOS_SD /mnt
sudo install -d -m 0700 /mnt/var/lib/secrets
sudo install -m 0400 syncoid_ed25519 syncoid_known_hosts tailscale_authkey /mnt/var/lib/secrets/
sudo umount /mnt
```

Tailscale の管理画面で、pi-nas の鍵の期限切れ (key expiry) を無効にする。期限が切れると、遠隔から戻せなくなる。

## pool を作る (最初の 1 回だけ)

pool は宣言で作らない。最初の 1 回だけ手で `zpool create` し、pi-nas は起動時に `boot.zfs.extraPools` で import するだけにする。pool の名前は `tank` とする (`nuage.nas.pool`)。

pi-nas にはログインできないので、ZFS を使える別の Linux の機械にディスクをつないで作り、`zpool export` してから pi-nas につなぐ。
export した pool は、pi-nas が `-f` 無しで import できる。作る機械の ZFS は、pi-nas の ZFS (2.4) より新しい版にしない。新しい版の機能を有効にすると、pi-nas で import できなくなる。

ディスクは必ず `/dev/disk/by-id/...` で指す。`/dev/sdX` は起動のたびに変わりうる。

```bash
ls -l /dev/disk/by-id/ | grep -v part   # 2 台のディスクの id を確かめる

sudo zpool create \
  -o ashift=12 \
  -o autotrim=off \
  -O compression=lz4 \
  -O atime=off \
  -O xattr=sa \
  -O acltype=posixacl \
  -O mountpoint=none \
  -O canmount=off \
  tank mirror \
  /dev/disk/by-id/<1 台目> \
  /dev/disk/by-id/<2 台目>

# 受け先の親を作る。一次側の dataset (例: pool-1/enc) は tank/pool-1/enc として受ける。
sudo zfs create -o mountpoint=none -o canmount=off tank/pool-1

sudo zpool export tank
```

| 設定 | 値 | 理由 |
| :-- | :-- | :-- |
| `ashift` | 12 | 4K セクタの HDD に合わせる。あとから変えられない |
| `compression` | lz4 | 軽く、ほぼ損をしない。raw send で受けた dataset は一次側の設定のまま書かれる |
| `atime` | off | 読むたびの書き込みを避ける |
| `xattr` / `acltype` | sa / posixacl | Linux の拡張属性と ACL を速く扱う |
| `mountpoint` / `canmount` | none / off | pool の直下にはデータを置かない。受けた dataset も mount しない |

ディスクの by-id は、ディスクが届いてから書く。

## SD イメージの作り方と焼き方

SD イメージは aarch64 でビルドする。aarch64 の機械か、`boot.binfmt.emulatedSystems = [ "aarch64-linux" ];` を入れた機械でビルドする。
nixos-raspberrypi のバイナリキャッシュを使うため、`--accept-flake-config` を付ける。付けないと、Pi のカーネルを手元でビルドする。

```bash
nix build --accept-flake-config .#packages.aarch64-linux.pi-nas-sd-image
ls result/sd-image/   # nixos-image-rpi5-kernel.img.zst
```

焼く。`/dev/sdX` は SD カードのデバイスである。間違えると他のディスクを消すので、`lsblk` で確かめてから流す。

```bash
lsblk
zstd -dc result/sd-image/nixos-image-rpi5-kernel.img.zst | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
```

焼いたら、上の「秘密」の手順でファイルを置く。初回の起動で、root のパーティションは SD の全体に広がる。

## 確かめ方

```bash
nix flake check
nix eval .#nixosConfigurations.pi-nas.config.system.build.toplevel.drvPath
```
