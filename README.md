# nuage-dr

自宅の環境が丸ごと失われてもデータを失わないための、隔地 (別の拠点) に置く Raspberry Pi の NixOS 構成である。
あわせて、一次側の NAS と共有する NAS のモジュール (`nixosModules.nas`) を置く。全体の計画は nuage-cluster の `docs/dr-plan.md` として作成予定である。

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
| 複製 | syncoid が 1 時間ごとに一次側から pull する。暗号化した dataset を raw send (`zfs send -w`) で受け、鍵は読み込まない。受けた dataset は mount しない。受け側を巻き戻さない (`--no-rollback`、下の「複製」) |
| 世代 | sanoid が受けたスナップショットの古いものを消す。pi-nas ではスナップショットを取らない。月ごとに 1 つ hold をかけ、消させない |
| scrub | 月 1 回、pool を scrub する (`services.zfs.autoScrub`) |
| 待ち受け | SSH は無効。firewall は既定で拒否。Tailscale は `--shields-up` で、受ける通信をすべて拒否する |
| 更新 | nuage-dr の master を `system.autoUpgrade` で毎日取り込む (`github:k-wa-wa/nuage-dr#pi-nas`) |
| watchdog | ハードウェアの watchdog を有効にし、固まったら再起動させる (`RuntimeWatchdogSec = 10s`) |
| 停電 | Pi 5 は通電すると自動で起動する。停電から戻れば、そのまま動き出す |

### 複製

syncoid は `--no-rollback` を付けて動かす。`zfs receive` に `-F` を付けず、受け側の世代を消させないためである。

syncoid の既定では `zfs receive -F` を使う。一次側で新しい世代を消し、別の世代を作って送り直されると、受け側でも共通の世代より新しい分が消える。
一次側が乗っ取られても pi-nas の世代を消させない、という前提が崩れるので塞ぐ。

巻き戻しが要る状況になると、syncoid はエラーで止まり、`syncoid-<dataset>` のユニットが失敗する。以後の複製も、人が手を入れるまで止まる。
止まったときは、次を見る。

- 一次側で何が消されたか。pi-nas の受け先の最新の世代が、一次側にまだあるかを比べる。一次側で消されていれば、消した操作が正当か (乗っ取りでないか) を一次側のログで確かめる
- 正当であれば、pi-nas の世代を残したまま複製を戻す。受け先の世代を手で消して巻き戻すのは、消してよいと確かめてからにする

普段の差分の pull (一次側で古い世代が消えても、共通の世代から新しい分を送る) は、`--no-rollback` でも今までどおり通る。

syncoid には `--quiet` も付ける。`--quiet` のときだけ、syncoid は送受信の間に `pv` を挟まない。
`pv` (1.10) は入力が終わると、出力の pipe が空になるまで待つ。`zfs receive` が失敗して読み残したまま終わると `pv` が終わらず、ユニットは失敗にならずに動いたまま残る。
`--quiet` で消えるのは syncoid の INFO と WARNING の出力だけで、失敗 (`CRITICAL ERROR` と `zfs receive` のエラー) は journal に残る。

### 世代の決まり

世代の決まりは pi-nas の側にだけ置く。一次側の sanoid が取ったスナップショットのうち、次の数を残す。
変えるときは `nuage.nas.replica.retention` を書く。

| 種類 | 既定値 |
| :-- | :-- |
| hourly | 24 |
| daily | 30 |
| monthly | 12 |

#### 月ごとの hold

一次側が乗っ取られて偽のスナップショットを大量に流されると、sanoid は数で古い世代を消すので、まともな世代が押し出される。
それを防ぐため、pi-nas の側で、ひと月に 1 つ、そのとき最新の受け取り済みスナップショットに `zfs hold` をかける。hold のかかったスナップショットは消せない。

| 項目 | 中身 |
| :-- | :-- |
| ユニット | `nas-replica-hold` (timer は syncoid と同じ 1 時間ごと。syncoid のあと、sanoid の前に走る) |
| 対象 | 複製する dataset (例: `tank/pool-1/enc`) と、その子のそれぞれ |
| 付ける | 今月のタグの hold が無ければ、受け取った順 (`createtxg`) で最新のスナップショットに付ける |
| タグ | `nuage-keep-YYYY-MM`。年月は pi-nas の時計で決める |
| 外す | タグの年月が `nuage.nas.replica.monthlyHold.keepMonths` (既定 13) か月より古くなったら外す。13 なら、`nuage-keep-2026-10` は 2027-12 に外す |
| 数の下限 | 受け取った順 (`createtxg`) で新しい方から `keepMonths` 個の hold は、年月によらず外さない。年月の条件と数の下限の両方を満たすものだけを外す |
| 失敗 | 受け先が無い・スナップショットが無い・付け外しに失敗したときは、ユニットが失敗する |

どれを固定するか・いつ外すかは、pi-nas の時計と pi-nas の決まりだけで決める。一次側が付けたスナップショットの名前 (`_monthly` など) と作成日時 (`creation`) は、一次側で偽れるので使わない。

数の下限は、時計を未来へ進められたときのためである。隔地の網で NTP を書き換えられると、pi-nas の時計が未来へ進み、年月の条件だけでは hold が一度にすべて外れる。
数の下限があれば、時計を数年先へ進められても、hold は `keepMonths` 個より減らない。
「新しい方」の順は、タグの年月ではなく受け取った順 (`createtxg`) で決める。タグの年月は、付けたときの時計に左右されるためである。同じスナップショットに複数の hold があるときは、タグの順に並べる。

数の下限でも防げないことが残る。時計を 1 時間ごとに 1 か月ずつ進められると、走るたびに新しい月の hold が最新のスナップショットに付き、`keepMonths` 回で古い hold がすべて新しいものに入れ替わる。

hold のかかったスナップショットを sanoid が消そうとすると、`cannot destroy snapshot ...: it's being held` と警告を出して次へ進む。sanoid のユニットは失敗しない。
hold が外れたあとは、sanoid の決まりで消える。

pool を import した機械で、次のように確かめる。pi-nas にはログインできないので、installer の SD で起動したときに使う。

```bash
# hold のかかったスナップショット (userrefs が 1 以上) を一覧する
zfs list -H -t snapshot -o name,userrefs -r tank/pool-1/enc | awk '$2 > 0'

# あるスナップショットとその子の hold を見る
zfs holds -r tank/pool-1/enc@<スナップショット>

# すべての hold のタグを見る
zfs list -H -o name -t snapshot -r tank/pool-1/enc | xargs -d '\n' zfs holds -H
```

付け外しの記録は pi-nas の journal に残る。SD を別の機械で読むときは、`journalctl -D <SD の root>/var/log/journal -u nas-replica-hold` で見る。

手で外すときは `zfs release nuage-keep-YYYY-MM tank/pool-1/enc@<スナップショット>` を流す。

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

pi-nas にはログインできないので、同じ Pi に、ログインできる別の SD (installer) を挿して起動し、そこで作る。SATA HAT のディスクは付け替えない。

1. installer の SD を作る。nixos-raspberrypi の installer のイメージ (Pi 5 用) を、このリポジトリの flake から作る。nixos-raspberrypi はイメージのファイルを配っていないので、ビルドする。ビルドの仕方は下の「SD イメージの作り方と焼き方」と同じである

   ```bash
   nix build --accept-flake-config .#packages.aarch64-linux.rpi5-installer-sd-image
   ls result/sd-image/   # nixos-installer-rpi5-kernel.img.zst
   ```

   nixpkgs を pi-nas とそろえているので、installer の ZFS は pi-nas と同じ版 (2.4) になる。新しい版の ZFS で作って新しい機能を有効にすると、pi-nas で import できなくなるので、他から取ったイメージは使わない
2. ディスクをつないだ Pi に installer の SD を挿して起動する (pi-nas の SD が挿さっていれば抜く)。HDMI とキーボードをつなぐと、root でログインした状態になる。SSH で入るときは、画面に出る接続先とパスワードを使う (installer の SSH は一時的なものとし、作業が済んだら SD を抜く)
3. 下のとおり `zpool create` と、受け先の親の dataset の作成をして、`zpool export` する
4. `poweroff` で電源を切り、pi-nas の SD に差し替えて起動する。pi-nas は起動時に `tank` を import する

installer の `networking.hostId` (`8425e349`) は pi-nas の (`72a7a172`) と違う。ZFS は、他の hostId の機械で使われたまま (export されずに) 止まった pool を、`-f` 無しでは import しない。
`zpool export` してから差し替えれば、pi-nas は `-f` 無しで import できる。pi-nas は `-f` を付けずに import するので、export を忘れると pool が import されず、複製が止まる。そのときは installer の SD でもう一度起動し、`zpool import -f tank` してから `zpool export tank` する。

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

## CI

master 向けの PR と master への push で、評価・フォーマット・pi-nas のビルドを確かめる。pi-nas は master をそのまま取り込むので、master に入る前に壊れていないことを見る。`check` と `build-pi-nas` は必須のチェックである。`lock-warn` は、flake の入力とバイナリキャッシュの設定の変化を警告する。

ジョブの中身、警告の見方、Actions の決まりは [docs/ci.md](docs/ci.md) にある。
