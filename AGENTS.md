# Nuage DR Workspace Rules

このファイルは、`nuage-dr` リポジトリで動作する AI Agent 向けの動作ルールと前提条件を定義する。Agent は、コマンド実行やファイル編集の際、これらのルールを厳格に適用する必要がある。

## 1. このリポジトリの役割

- 隔地 (別の拠点) に置く Raspberry Pi の NixOS 構成と、一次側の NAS と共有する NAS モジュール (`nixosModules.nas`) を置く
- 自宅の環境が丸ごと失われたとき、本番 (nuage-cluster・GitHub の bot・atelier のエージェント) が乗っ取られたときにも、バックアップを消されないための場所である
- 全体の計画は nuage-cluster の `docs/dr-plan.md` として作成予定である

| 構成 | 中身 |
| :-- | :-- |
| `flake.nix` | 入力と出力 (`nixosModules.nas`・`nixosConfigurations.pi-nas`・`packages.aarch64-linux.pi-nas-sd-image`・`checks`) |
| `modules/nas/` | NAS のモジュール。`nuage.nas.role` で役を選ぶ。今は `replica` だけがある |
| `modules/auto-upgrade.nix` | Pi の更新の経路 (取り込みの設定はここにだけ置く) |
| `hosts/pi-nas/` | pi-nas の構成 |

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
