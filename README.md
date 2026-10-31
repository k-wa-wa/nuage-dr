# nuage-dr

自宅の環境が丸ごと失われてもデータを失わないための、隔地 (別の拠点) に置く機器の NixOS 構成である。
あわせて、一次側の NAS と共有する NAS のモジュール (`nixosModules.nas`) を置く。全体の計画は nuage-cluster の `docs/dr-plan.md` として作成予定である。

| ホスト | 役 | 状態 |
| :-- | :-- | :-- |
| `dr-nas` | x86 の 2 ベイの小型 NAS。一次側の NAS (`192.168.5.30`) から ZFS のスナップショットを pull で複製する | 構成あり (機種は未決) |
| `pi-1`〜`pi-3` | DR 用の計算 (k3s) | まだ無い |

一次側の NAS は nuage-cluster に置き、このリポジトリを flake input として読む。逆向きにはしない。

## dr-nas

焼いたイメージで動き、ログインしないアプライアンスとする。

| 項目 | 中身 |
| :-- | :-- |
| ハードウェア | x86 の 2 ベイの小型機 (N100・N150 など)。HDD 2 台を mirror にし、起動用に小容量の NVMe を 1 枚挿す。Pi 5 + SATA HAT は、電源の不足やカーネルの更新でディスクが見えなくなる報告があり、触らない隔地には向かないのでやめた |
| 複製 | syncoid が 1 時間ごとに一次側から pull する。暗号化した dataset を raw send (`zfs send -w`) で受け、鍵は読み込まない。受けた dataset は mount しない。受け側を巻き戻さない (`--no-rollback`、下の「複製」) |
| 世代 | sanoid が受けたスナップショットの古いものを消す。pi-nas ではスナップショットを取らない。Pi が動いた時間で 30 日ごとに 1 つ hold をかけ、消させない |
| scrub | 月 1 回、pool を scrub する (`services.zfs.autoScrub`) |
| 待ち受け | SSH は無効。firewall は既定で拒否。Tailscale は `--shields-up` で、受ける通信をすべて拒否する |
| 更新 | nuage-dr の master を `system.autoUpgrade` で毎日取り込む (`github:k-wa-wa/nuage-dr#dr-nas`) |
| watchdog | ハードウェアの watchdog を有効にし、固まったら再起動させる (`RuntimeWatchdogSec = 30s`)。使えるかは機種で確かめる |
| 停電 | 通電したら自動で起動するよう BIOS で設定する。停電から戻れば、そのまま動き出す |

### 複製

syncoid は `--no-rollback` を付けて動かす。`zfs receive` に `-F` を付けず、受け側の世代を消させないためである。

syncoid の既定では `zfs receive -F` を使う。一次側で新しい世代を消し、別の世代を作って送り直されると、受け側でも共通の世代より新しい分が消える。
一次側が乗っ取られても dr-nas の世代を消させない、という前提が崩れるので塞ぐ。

巻き戻しが要る状況になると、syncoid はエラーで止まり、`syncoid-<dataset>` のユニットが失敗する。以後の複製も、人が手を入れるまで止まる。
止まったときは、次を見る。

- 一次側で何が消されたか。dr-nas の受け先の最新の世代が、一次側にまだあるかを比べる。一次側で消されていれば、消した操作が正当か (乗っ取りでないか) を一次側のログで確かめる
- 正当であれば、dr-nas の世代を残したまま複製を戻す。受け先の世代を手で消して巻き戻すのは、消してよいと確かめてからにする

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

#### hold

一次側が乗っ取られて偽のスナップショットを大量に流されると、sanoid は数で古い世代を消すので、まともな世代が押し出される。
それを防ぐため、pi-nas の側で、決まった間隔ごとに 1 つ、そのとき最新の受け取り済みスナップショットに `zfs hold` をかける。hold のかかったスナップショットは消せない。

| 項目 | 中身 |
| :-- | :-- |
| ユニット | `nas-replica-hold` (timer は syncoid と同じ 1 時間ごと。syncoid のあと、sanoid の前に走る) |
| 対象 | 複製する dataset (例: `tank/pool-1/enc`) と、その子のそれぞれ |
| 付ける | 前の hold から、pi-nas が動いていた時間の合計が `nuage.nas.replica.hold.intervalDays` (既定 30) 日になったら、受け取った順 (`createtxg`) で最新のスナップショットに付ける |
| タグ | `nuage-keep-YYYY-MM`。年月は人が見て分かるためだけに入れ、判断には使わない |
| 外す | 受け取った順 (`createtxg`) で新しい方から `nuage.nas.replica.hold.keep` (既定 13) 個を残し、それより古い hold を外す |
| 失敗 | 受け先が無い・スナップショットが無い・付け外しに失敗した・状態のファイルが読めないときは、ユニットが失敗する |

どれを固定するか・いつ外すかは、pi-nas の数えと pi-nas の決まりだけで決める。一次側が付けたスナップショットの名前 (`_monthly` など) と作成日時 (`creation`) は、一次側で偽れるので使わない。
pi-nas の壁時計も使わない。NTP を書き換えられても、hold が早く付くことも外れることも無い。

付ける・外すの細かい決まりと、攻撃ごとに何が守るかは [docs/hold.md](docs/hold.md) に書く。

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

付け外しの記録と付けた理由は pi-nas の journal に残る。SD を別の機械で読むときは、`journalctl -D <SD の root>/var/log/journal -u nas-replica-hold` で見る。

手で外すときは `zfs release nuage-keep-YYYY-MM tank/pool-1/enc@<スナップショット>` を流す。

## 作り方

イメージの作り方と焼き方、秘密の置き方、pool の作り方は [docs/dr-nas-setup.md](docs/dr-nas-setup.md) にある。

## 確かめ方

```bash
nix flake check
nix build .#nixosConfigurations.dr-nas.config.system.build.toplevel
```

## CI

master 向けの PR と master への push で、評価・フォーマット・pi-nas のビルドを確かめる。pi-nas は master をそのまま取り込むので、master に入る前に壊れていないことを見る。`check` と `build-pi-nas` は必須のチェックである。`lock-warn` は、flake の入力とバイナリキャッシュの設定の変化を警告する。

ジョブの中身、警告の見方、Actions の決まりは [docs/ci.md](docs/ci.md) にある。
