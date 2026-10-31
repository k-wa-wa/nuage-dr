# Nuage DR Workspace Rules

このファイルは、`nuage-dr` リポジトリで動作する AI Agent 向けの動作ルールと前提条件を定義する。Agent は、コマンド実行やファイル編集の際、これらのルールを厳格に適用する必要がある。

## 1. このリポジトリの役割

- 隔地 (別の拠点) に置く Raspberry Pi の NixOS 構成と、一次側の NAS と共有する NAS モジュール (`nixosModules.nas`) を置く
- 自宅の環境が丸ごと失われたとき、本番 (nuage-cluster・GitHub の bot・atelier のエージェント) が乗っ取られたときにも、バックアップを消されないための場所である
- 全体の計画は nuage-cluster の `docs/dr-plan.md` として作成予定である

| 構成 | 中身 |
| :-- | :-- |
| `flake.nix` | 入力と出力 (`nixosModules.nas`・`nixosConfigurations.pi-nas`・`packages.aarch64-linux.pi-nas-sd-image`・`packages.aarch64-linux.rpi5-installer-sd-image`・`checks`) |
| `modules/nas/` | NAS のモジュール。`nuage.nas.role` で役を選ぶ。今は `replica` だけがある |
| `modules/auto-upgrade.nix` | Pi の更新の経路 (取り込みの設定はここにだけ置く) |
| `hosts/pi-nas/` | pi-nas の構成 |
| `.github/workflows/ci.yml` | CI (下の「6. CI」) |
| `.github/scripts/lock-warn.sh` | flake の入力とキャッシュの設定の変化を警告するスクリプト (CI の `lock-warn`) |

## 2. 更新の経路

| 資材 | 適用経路 |
| :-- | :-- |
| Pi の NixOS 構成 (`hosts/`・`modules/`) | nuage-dr の master → 各 Pi の `system.autoUpgrade` が取り込む |
| 一次側の NAS (nuage-cluster の nas) | nuage-cluster が nuage-dr を flake input として読み、nuage-cluster の master → autoUpgrade |

- master に入れられるのは k-wa-wa だけである。bot は PR を作るまでとし、master への push・マージをしない
- master はルールセットで PR を必須にし、素通し (bypass) できるのは k-wa-wa だけである。この保護が Pi の更新の信頼の根元である
- 取り込みの設定は `modules/auto-upgrade.nix` の 1 か所にまとめる。あとで署名タグ (`git verify-tag`) を確かめる形に、ここだけを差し替える。他のファイルに `system.autoUpgrade` を書かない
- Pi は遠隔にあり、最初の設置のあとは物理的に触らない。起動できなくなる変更 (ブートローダー・ネットワーク・Tailscale) は、特に慎重に扱う

## 3. 守ること

- **nuage-cluster を input にしない。** 依存の向きは nuage-cluster → nuage-dr だけとする。bot が push できる nuage-cluster を、バックアップの信頼の根元に入れないためである
- **`nixosModules.nas` を nixos-raspberrypi に依存させない。** 一次側の NAS (x86_64) でも読むためである。Pi に固有の設定は `hosts/` に置く
- **秘密を Nix の store に入れない。** 秘密はファイルのパスを文字列で受け取る (例: `"/var/lib/secrets/syncoid_ed25519"`)。パスリテラル (`./secret`)・`builtins.readFile`・`pkgs.writeText` で秘密を扱わない。リポジトリは public であり、SOPS も使わない。Pi の秘密は、焼くときに SD へ書き込む
- **必要な値が無いときは assertion で落とす。** 既定値で黙って続けない。秘密のファイルが無いときは、ユニットがエラーで止まるようにする
- **pool とデータのディスクを宣言で扱わない。** disko などでデータのディスクに触れない。NixOS は import するだけにする
- **nixpkgs は nixos-raspberrypi の flake.lock と同じ版に合わせる。** nixos-raspberrypi のバイナリキャッシュに当てるためである。更新するときは、nixos-raspberrypi を更新し、その flake.lock の nixpkgs の rev に合わせる

  ```bash
  nix flake update nixos-raspberrypi
  nix flake lock --override-input nixpkgs github:nixos/nixpkgs/<nixos-raspberrypi の flake.lock の nixpkgs の rev>
  ```

## 4. 変更したときの確かめ方

- nix ファイルを変えたら、必ず次のコマンドでフォーマットする

  ```bash
  nix run nixpkgs#nixfmt-tree -- .
  ```

- 次の 2 つが通ることを確かめる。atelier は x86_64 なので、aarch64 のビルドが要る check は入れない

  ```bash
  nix flake check
  nix eval .#nixosConfigurations.pi-nas.config.system.build.toplevel.drvPath
  ```

- `nix flake check` は、`nixosModules.nas` に必要な option を渡さないときに assertion が落ちることも確かめる (`checks.x86_64-linux.nas-assertions`)。必要な option を足したら、この check にも足す

## 5. その他制約

- **言い切り調の使用**:
  コメントアウトやドキュメントを記述する際は、です・ます調（敬体）を避け、である・する調（常体）の言い切りを使用すること。

## 6. CI

`.github/workflows/ci.yml` が、master 向けの PR と master への push で走る。

| ジョブ | マシン | 中身 | 必須 |
| :-- | :-- | :-- | :-- |
| `check` | `ubuntu-24.04` | `nix flake check` と nixfmt のずれの確かめ (`nix fmt -- --ci`) | 必須 |
| `build-pi-nas` | `ubuntu-24.04-arm` | `nix build .#nixosConfigurations.pi-nas.config.system.build.toplevel` (SD イメージは作らない) | 必須 |
| `lock-warn` | `ubuntu-24.04` | PR だけで走る。flake の入力とキャッシュの設定の変化を警告する | 必須にしない |

- 必須のチェックは、master のルールセットでジョブの名前 (`check`・`build-pi-nas`) で指す (nuage-workspace の tf)。ジョブの id と `name:` を変えない。matrix にしない
- `--no-update-lock-file` を付けて、flake.lock に無い入力を CI で黙って足させない
- `build-pi-nas` は、nixos-raspberrypi のバイナリキャッシュを flake の `nixConfig` から `--accept-flake-config` で受ける
- Actions を攻め口にしない。action はコミットの SHA で固定し、横にタグをコメントで書く。workflow の権限は `contents: read` だけにし、secrets を使わない。`pull_request_target` を使わない。PR から来る値 (タイトル・ブランチ名など) を `run:` に直接埋めない
- workflow を変えたら `nix run nixpkgs#actionlint` を通す
- `lock-warn` の比べる処理は `.github/scripts/lock-warn.sh` にある。手元では、書き換えた flake.lock を渡して試す

  ```bash
  GITHUB_STEP_SUMMARY=/dev/stdout .github/scripts/lock-warn.sh <前の flake.lock> flake.lock <前の flake.nix> flake.nix
  ```

- `lock-warn` の警告が出た PR (flake.lock を上げる PR を含む) は、要約の比較のリンクから差分を読んでからマージする
