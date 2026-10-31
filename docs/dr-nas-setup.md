# dr-nas の作り方

dr-nas は、焼いたイメージで動き、ログインしないアプライアンスである。自宅で組んで試してから隔地に置く。

流れは次のとおりである。

1. イメージを作る (atelier)
2. 起動用の NVMe に焼き、秘密を置く (Mac)
3. BIOS を設定する
4. pool を作る (最初の 1 回だけ。installer の USB で起動する)
5. NVMe から起動する

## 1. イメージを作る

x86_64 でビルドするので、atelier で作る。nuage-dr を clone した場所で流す。

```bash
nix build .#dr-nas-image --out-link result-image
nix build .#dr-nas-installer-iso --out-link result-installer
zstd -T0 -o dr-nas.img.zst result-image/*.img
cp result-installer/iso/*.iso dr-nas-installer.iso
```

| 出力 | 中身 |
| :-- | :-- |
| `dr-nas-image` | 起動用の NVMe に焼く raw のイメージ。ESP (FAT、ラベル `ESP`) と root (ext4、ラベル `nixos`) を持つ |
| `dr-nas-installer-iso` | pool を作るときに起動する installer。dr-nas と同じ nixpkgs から作るので、ZFS の版が dr-nas と同じになる |

新しい版の ZFS で pool を作って新しい機能を有効にすると、dr-nas で import できなくなる。installer は、他から取った ISO を使わず、この flake から作る。

作ったファイルを Mac へ運ぶ。

```bash
scp atelier:<nuage-dr の clone>/dr-nas.img.zst atelier:<nuage-dr の clone>/dr-nas-installer.iso .
```

## 2. 起動用の NVMe に焼き、秘密を置く

起動用の NVMe を USB の NVMe ケースに入れ、Mac につなぐ。`diskN` はその NVMe である。間違えると他のディスクを消すので、`diskutil list` で確かめてから流す。

```bash
diskutil list
diskutil unmountDisk /dev/diskN
nix run nixpkgs#zstd -- -dc dr-nas.img.zst | sudo dd of=/dev/rdiskN bs=4m
```

焼いたあと、macOS が「読み取れないディスク」と出すことがある。root の ext4 を読めないためなので、無視する。

### 秘密

秘密は Nix の store とイメージファイルに入れず、ESP の `secrets/` に置く。ESP は FAT なので Mac から書ける。dr-nas は ESP を `/boot` に root だけが読める形でマウントする (`hosts/dr-nas/hardware.nix`)。ファイルが無ければ、使うユニットがエラーで止まる。

| ファイル (dr-nas の上のパス) | 中身 | 無いときに止まるユニット |
| :-- | :-- | :-- |
| `/boot/secrets/syncoid_ed25519` | 一次側の NAS の pull 用のユーザー (`dr-nas-pull`) に入る SSH の秘密鍵 | `nas-replica-secrets` (と syncoid) |
| `/boot/secrets/syncoid_known_hosts` | 一次側の NAS のホスト鍵 (`192.168.5.30 ssh-ed25519 AAAA...`) | `nas-replica-secrets` (と syncoid) |
| `/boot/secrets/tailscale_authkey` | Tailscale の auth key。`tag:dr-nas` を付け、Tailnet Lock の署名を前もってしておく | `tailscaled-autoconnect` |

ESP は 1 番目のパーティション (`diskNs1`) である。macOS は ESP を自動ではマウントしないので、手でマウントする。

```bash
sudo diskutil mount /dev/diskNs1
diskutil info /dev/diskNs1 | grep "Mount Point"   # 例: /Volumes/ESP
sudo mkdir /Volumes/ESP/secrets
sudo cp syncoid_ed25519 syncoid_known_hosts tailscale_authkey /Volumes/ESP/secrets/
sudo dot_clean -m /Volumes/ESP   # macOS が足す ._ のファイルを消す
diskutil eject /dev/diskN
```

Tailscale の管理画面で、dr-nas の鍵の期限切れ (key expiry) を無効にする。期限が切れると、遠隔から戻せなくなる。

## 3. BIOS を設定する

| 項目 | 設定 |
| :-- | :-- |
| 停電からの復帰 | 通電したら起動する (AC power recovery を Power On にする) |
| watchdog | メーカーの OS に向けた watchdog があれば切る。NixOS が応えないので、一定時間で再起動が繰り返される |
| 起動順 | 起動用の NVMe を先にする |
| Secure Boot | 切る |

## 4. pool を作る (最初の 1 回だけ)

pool は宣言で作らない。最初の 1 回だけ手で `zpool create` し、dr-nas は起動時に `boot.zfs.extraPools` で import するだけにする。pool の名前は `tank` とする (`nuage.nas.pool`)。

dr-nas にはログインできないので、同じ機械を installer の USB で起動して作る。

1. Mac で installer の ISO を USB メモリに焼く

   ```bash
   diskutil list
   diskutil unmountDisk /dev/diskN
   sudo dd if=dr-nas-installer.iso of=/dev/rdiskN bs=4m
   ```

2. HDD を挿した機械に USB メモリを挿し、起動のメニューで USB メモリを選んで起動する。HDMI とキーボードをつなぐと、`nixos` のユーザーでログインした状態になる
3. 下のとおり `zpool create` と、受け先の親の dataset の作成をして、`zpool export` する
4. `sudo poweroff` で電源を切り、USB メモリを抜いて起動する。dr-nas は起動時に `tank` を import する

installer と dr-nas は、ZFS の hostId が違う。ZFS は、他の hostId の機械で使われたまま (export されずに) 止まった pool を、`-f` 無しでは import しない。
`zpool export` してから起動し直せば、dr-nas は `-f` 無しで import できる。dr-nas は `-f` を付けずに import するので、export を忘れると pool が import されず、複製が止まる。そのときは installer でもう一度起動し、`sudo zpool import -f tank` してから `sudo zpool export tank` する。

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

## 5. NVMe から起動する

初回の起動で、root のパーティションは NVMe の全体に広がる。以後は nuage-dr の master を `system.autoUpgrade` で取り込む。

ESP は 256MiB しかないので、起動の項目は 3 世代までにしている (`boot.loader.systemd-boot.configurationLimit`)。
