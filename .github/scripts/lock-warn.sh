#!/usr/bin/env bash
# PR の前後で flake の入力とバイナリキャッシュの設定を比べ、変わったものを警告する。
#
# dr-nas は master を autoUpgrade で取り込むので、flake.lock の更新はそのまま dr-nas に入る。
# 入力の rev が変わったら、何が変わったかを読んでからマージできるよう、比較のリンクを並べる。
# nixConfig のキャッシュの設定が変わったら、信用するバイナリの出どころが変わるので、別に強く警告する。
#
# 使い方: lock-warn.sh <前の flake.lock> <後の flake.lock> <前の flake.nix> <後の flake.nix>
# 無いファイル (PR で足した・消した) は、空として扱う。
# 警告は GitHub Actions の `::warning::` で出し、要約は $GITHUB_STEP_SUMMARY に書く。
# 警告にとどめ、変わったものがあっても 0 で終わる。比べられなかったとき (壊れた JSON など) は失敗で終わる。
# flake.nix が変わったときだけ、nixConfig を読むのに nix を使う。
#
# 手元で試すとき:
#   GITHUB_STEP_SUMMARY=/dev/stdout .github/scripts/lock-warn.sh old/flake.lock flake.lock old/flake.nix flake.nix

set -euo pipefail

if [ "$#" -ne 4 ]; then
  echo "使い方: lock-warn.sh <前の flake.lock> <後の flake.lock> <前の flake.nix> <後の flake.nix>" >&2
  exit 2
fi
: "${GITHUB_STEP_SUMMARY:?GITHUB_STEP_SUMMARY に要約の書き先を渡す}"

base_lock=$1
head_lock=$2
base_nix=$3
head_nix=$4

# 第三者の flake と見なさない GitHub の owner。これ以外の入力は、目立つ文言で警告する。
trusted_owners='["nixos"]'

# バイナリの出どころを変える nixConfig の設定。
cache_keys='["substituters","extra-substituters","trusted-substituters","extra-trusted-substituters","trusted-public-keys","extra-trusted-public-keys","require-sigs"]'

# PR から来る値を、workflow のコマンド (`::...::`) と Markdown の表を崩さない文字だけにする。
sanitize='def safe: tostring | gsub("[^A-Za-z0-9._/:+=@-]"; "?");'

read_lock() {
  if [ -e "$1" ]; then
    jq -e 'if .nodes then . else error("flake.lock に nodes が無い") end' "$1"
  else
    echo '{"nodes":{}}'
  fi
}

# root を除く入力のそれぞれを、比べる値だけにする。
lock_inputs() {
  jq "$sanitize"'
    (.root // "root") as $root
    | .nodes
    | del(.[$root])
    | with_entries(.value = (.value.locked // {} | {
        type: (.type // "" | safe),
        owner: (.owner // "" | safe),
        repo: (.repo // "" | safe),
        url: (.url // "" | safe),
        rev: (.rev // "" | safe),
        narHash: (.narHash // "" | safe)
      }))'
}

base_inputs=$(read_lock "$base_lock" | lock_inputs)
head_inputs=$(read_lock "$head_lock" | lock_inputs)

# 変わった入力を 1 行ずつ JSON で出す。
changes=$(jq -cn \
  --argjson base "$base_inputs" \
  --argjson head "$head_inputs" \
  --argjson trusted "$trusted_owners" \
  "$sanitize"'
  def src: if .type == "github" then "\(.owner)/\(.repo)" elif .url != "" then .url else .type end;
  def short: if . == "" then "" else .[0:12] end;
  def third: (.type != "github") or ((.owner | ascii_downcase) as $o | $trusted | index($o) | not);
  ($base + $head | keys[]) as $name
  | $base[$name] as $b
  | $head[$name] as $h
  | select($b != $h)
  | {
      name: ($name | safe),
      kind: (if $b == null then "added" elif $h == null then "removed" else "changed" end),
      before: (if $b then ($b.rev | short) // "" else "" end),
      after: (if $h then ($h.rev | short) // "" else "" end),
      beforeSrc: (if $b then ($b | src) else "" end),
      afterSrc: (if $h then ($h | src) else "" end),
      thirdParty: ([$b, $h] | map(select(. != null) | third) | any),
      link: (
        if $b and $h and $b.type == "github" and $h.type == "github"
          and $b.owner == $h.owner and $b.repo == $h.repo and $b.rev != "" and $h.rev != "" and $b.rev != $h.rev
        then "https://github.com/\($h.owner)/\($h.repo)/compare/\($b.rev)...\($h.rev)"
        elif $h and $h.type == "github" and $h.rev != ""
        then "https://github.com/\($h.owner)/\($h.repo)/commit/\($h.rev)"
        else "" end
      ),
      narHashOnly: ($b and $h and $b.rev == $h.rev and $b.narHash != $h.narHash)
    }')

# nixConfig を JSON で読む。flake.nix が無ければ空、読めなければ null を出す。
read_nix_config() {
  if [ ! -e "$1" ]; then
    echo '{}'
    return
  fi
  local path
  path=$(realpath "$1")
  nix eval --json --impure --expr "(import $path).nixConfig or {}" || echo 'null'
}

config_changes=""
config_unreadable=false
if ! cmp -s "$base_nix" "$head_nix" 2>/dev/null && { [ -e "$base_nix" ] || [ -e "$head_nix" ]; }; then
  if ! command -v nix >/dev/null; then
    echo "flake.nix が変わったので nixConfig を読むが、nix が無い" >&2
    exit 1
  fi
  base_config=$(read_nix_config "$base_nix")
  head_config=$(read_nix_config "$head_nix")
  if [ "$base_config" = null ] || [ "$head_config" = null ]; then
    config_unreadable=true
  else
    config_changes=$(jq -cn \
      --argjson base "$base_config" \
      --argjson head "$head_config" \
      --argjson cacheKeys "$cache_keys" \
      'def safe: tojson | gsub("[^A-Za-z0-9._/:+=@ \",\\[\\]{}-]"; "?");
      ($base + $head | keys[]) as $key
      | select($base[$key] != $head[$key])
      | {
          key: ($key | tostring | gsub("[^A-Za-z0-9._-]"; "?")),
          before: (if $base | has($key) then $base[$key] | safe else "" end),
          after: (if $head | has($key) then $head[$key] | safe else "" end),
          cache: ($cacheKeys | index($key) != null)
        }')
  fi
fi

summary() { printf '%s\n' "$@" >>"$GITHUB_STEP_SUMMARY"; }

summary "## flake の入力とキャッシュの設定の変化" ""

# nixConfig のキャッシュの設定は、表の前に強く警告する。
cache_changed=false
if [ "$config_unreadable" = true ]; then
  echo "::warning title=【要確認】nixConfig を読めなかった::flake.nix の nixConfig を評価できなかった。バイナリキャッシュの設定が変わっていないかを、flake.nix の差分で目で確かめる"
  summary "> [!CAUTION]" \
    "> flake.nix の \`nixConfig\` を評価できなかった。バイナリキャッシュの設定 (\`extra-substituters\`・\`extra-trusted-public-keys\` など) が変わっていないかを、flake.nix の差分で目で確かめる。" ""
fi
if [ -n "$config_changes" ]; then
  if jq -se 'any(.cache)' <<<"$config_changes" >/dev/null; then
    cache_changed=true
    keys=$(jq -sr 'map(select(.cache) | .key) | join(", ")' <<<"$config_changes")
    echo "::warning title=【要確認】バイナリキャッシュの設定が変わった::flake.nix の nixConfig の ${keys} が変わった。信用するバイナリの出どころが変わる。出どころと鍵を確かめてからマージする"
    summary "> [!CAUTION]" \
      "> **バイナリキャッシュの設定が変わった。** 信用するバイナリの出どころが変わる。CI と手元のビルドは \`--accept-flake-config\` でこの設定を受け入れるので、出どころと鍵を確かめてからマージする。" ""
  fi
  while IFS= read -r c; do
    if [ "$(jq -r '.cache' <<<"$c")" = false ]; then
      key=$(jq -r '.key' <<<"$c")
      echo "::warning title=nixConfig が変わった::flake.nix の nixConfig の ${key} が変わった。--accept-flake-config で受け入れる設定なので、中身を確かめる"
    fi
  done <<<"$config_changes"
  summary "### nixConfig" "" "| 設定 | 前 | 後 |" "| :-- | :-- | :-- |"
  jq -sr 'def code: if . == "" then "(無い)" else "`\(.)`" end;
    .[] | "| `\(.key)`\(if .cache then " (キャッシュ)" else "" end) | \(.before | code) | \(.after | code) |"' <<<"$config_changes" >>"$GITHUB_STEP_SUMMARY"
  summary ""
fi

if [ -z "$changes" ]; then
  summary "flake.lock の入力に変化は無い。"
else
  while IFS= read -r c; do
    name=$(jq -r '.name' <<<"$c")
    kind=$(jq -r '.kind' <<<"$c")
    before=$(jq -r '.before' <<<"$c")
    after=$(jq -r '.after' <<<"$c")
    before_src=$(jq -r '.beforeSrc' <<<"$c")
    after_src=$(jq -r '.afterSrc' <<<"$c")
    link=$(jq -r '.link' <<<"$c")
    third=$(jq -r '.thirdParty' <<<"$c")

    case $kind in
    added) msg="入力 ${name} が足された (${after_src} ${after})" ;;
    removed) msg="入力 ${name} が消えた (${before_src} ${before})" ;;
    *)
      if [ "$before_src" != "$after_src" ]; then
        msg="入力 ${name} の取り込み元が ${before_src} から ${after_src} に変わった (${before} -> ${after})"
      elif [ "$(jq -r '.narHashOnly' <<<"$c")" = true ]; then
        msg="入力 ${name} の narHash が変わった (rev は ${after:-無し} のまま)"
      else
        msg="入力 ${name} が ${before} から ${after} に変わった"
      fi
      ;;
    esac
    [ -n "$link" ] && msg="${msg}。${link}"
    if [ "$third" = true ]; then
      echo "::warning title=【第三者の flake】${name} が変わった::第三者の flake。差分を読んでからマージする。${msg}"
    else
      echo "::warning title=flake の入力 ${name} が変わった::${msg}"
    fi
  done <<<"$changes"

  if jq -se 'any(.thirdParty)' <<<"$changes" >/dev/null; then
    summary "> [!WARNING]" \
      "> **第三者の flake が変わった。** 個人などが保守する flake は、隔地の機器にそのまま入る。比較のリンクから差分を読んでからマージする。" ""
  fi
  summary "### flake.lock" "" "| 入力 | 取り込み元 | 前 | 後 | 差分 | 注意 |" "| :-- | :-- | :-- | :-- | :-- | :-- |"
  jq -sr 'def code: if . == "" then "(無い)" else "`\(.)`" end;
    .[] | "| `\(.name)` | \(if .beforeSrc == .afterSrc or .beforeSrc == "" then .afterSrc elif .afterSrc == "" then .beforeSrc else "\(.beforeSrc) → \(.afterSrc)" end) | \(.before | code) | \(.after | code) | \(if .link == "" then "" elif (.link | contains("/compare/")) then "[比較](\(.link))" else "[コミット](\(.link))" end) | \([if .thirdParty then "**第三者の flake。差分を読んでからマージする**" else empty end, if .kind == "added" then "足された" elif .kind == "removed" then "消えた" else empty end, if .beforeSrc != .afterSrc and .beforeSrc != "" and .afterSrc != "" then "**取り込み元が変わった**" else empty end, if .narHashOnly then "narHash だけが変わった" else empty end] | join("・")) |"' <<<"$changes" >>"$GITHUB_STEP_SUMMARY"
fi

if [ "$cache_changed" = false ] && [ "$config_unreadable" = false ] && [ -z "$config_changes" ]; then
  summary "" "nixConfig に変化は無い。"
fi
