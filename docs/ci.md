# CI

`.github/workflows/ci.yml` が、master 向けの PR と master への push で走る。dr-nas は master をそのまま取り込むので、master に入る前に、評価とビルドが通ることを確かめる。

## ジョブ

| ジョブ | マシン | 中身 | 必須 |
| :-- | :-- | :-- | :-- |
| `check` | `ubuntu-24.04` | `nix flake check` と nixfmt のずれの確かめ (`nix fmt -- --ci`) | 必須 |
| `build-dr-nas` | `ubuntu-24.04` | `nix build .#nixosConfigurations.dr-nas.config.system.build.toplevel` (焼くイメージは作らない) | 必須 |
| `lock-warn` | `ubuntu-24.04` | PR だけで走る。flake の入力とキャッシュの設定の変化を警告する | 必須にしない |

- 必須のチェックは `check` と `build-dr-nas` である。master のルールセットで、ジョブの名前で指す (nuage-workspace の tf で設定する)。通らない PR はマージできない。ジョブの id と `name:` を変えない。matrix にしない
- CI は `--no-update-lock-file` を付けて動く。flake.lock が flake.nix の入力と合わなければ落ちる。flake.lock に無い入力を CI で黙って足させない

## Actions の決まり

- Actions を攻め口にしない。action はコミットの SHA で固定し、横にタグをコメントで書く
- workflow の権限は `contents: read` だけにし、secrets を使わない。`pull_request_target` を使わない
- PR から来る値 (タイトル・ブランチ名など) を `run:` に直接埋めない
- workflow を変えたら `nix run nixpkgs#actionlint` を通す

## 入力の更新の警告 (`lock-warn`)

PR を base にマージしたときに変わる flake.lock と flake.nix を比べ、次を警告する。警告にとどめ、ジョブは落とさない。

| 変化 | 警告 |
| :-- | :-- |
| flake.lock の入力の `rev` (または `narHash`) が変わった・入力が増えた・減った | `flake の入力 <名前> が変わった` |
| そのうち、`nixos` の owner の外の flake | `【第三者の flake】<名前> が変わった` |
| flake.nix の `nixConfig` のキャッシュの設定 (`extra-substituters`・`extra-trusted-public-keys` など) が変わった | `【要確認】バイナリキャッシュの設定が変わった` |
| flake.nix の `nixConfig` のその他の設定が変わった | `nixConfig が変わった` |

警告は PR の Checks の画面の注釈 (annotations) に出る。`lock-warn` のジョブの要約 (Summary) には、入力の名前・前と後の rev・比較のリンクの表が出る。

- flake.lock を上げる PR は、要約の比較のリンクから差分を読んでからマージする
- 第三者の flake は、個人などが保守するので、特に読む
- バイナリキャッシュの設定が変わったときは、信用するバイナリの出どころが変わる。CI と手元のビルドは `--accept-flake-config` でこの設定を受け入れるので、出どころと鍵を確かめる

比べる処理は `.github/scripts/lock-warn.sh` にある。手元では、前の版のファイルを渡して試す。

```bash
git show origin/master:flake.lock >/tmp/flake.lock.old
git show origin/master:flake.nix >/tmp/flake.nix.old
GITHUB_STEP_SUMMARY=/dev/stdout .github/scripts/lock-warn.sh /tmp/flake.lock.old flake.lock /tmp/flake.nix.old flake.nix
```
