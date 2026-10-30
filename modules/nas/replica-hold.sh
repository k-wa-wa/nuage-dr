# 受け取ったスナップショットに、月ごとの hold を付け外しする。
#
# 一次側が乗っ取られて偽のスナップショットを大量に流されると、sanoid が数で古い世代を消し、まともな世代が押し出される。
# それを防ぐため、ひと月に 1 つ、そのとき最新の受け取り済みスナップショットに hold をかけ、sanoid にも syncoid にも消させない。
#
# どれを固定するか・いつ外すかは、Pi の時計と Pi の決まりだけで決める。
# 一次側が付けたスナップショットの名前 (_monthly など) と作成日時 (creation) は、一次側で偽れるので使わない。
# 受け取った順は createtxg で決める。createtxg は受け取った側の pool の txg である。
#
# 使い方: nas-replica-hold <残す月数> <受け先の dataset>...
# 受け先の dataset とその子のそれぞれについて、次を行う。
#   - 今月のタグ (nuage-keep-YYYY-MM、Pi の時計の年月) の hold が無ければ、最新のスナップショットに付ける
#   - タグの年月が <残す月数> より古い hold を外す (例: 13 なら、2026-10 のタグは 2027-12 に外す)
# 何かに失敗したら、残りの dataset を続けたうえで、最後に失敗で終わる。

if [ "$#" -lt 2 ]; then
  echo "使い方: nas-replica-hold <残す月数> <受け先の dataset>..." >&2
  exit 2
fi

keep_months=$1
shift
if ! [[ $keep_months =~ ^[1-9][0-9]*$ ]]; then
  echo "nas-replica-hold: 残す月数 ($keep_months) は 1 以上の整数で渡す。" >&2
  exit 2
fi

prefix=nuage-keep-
tag_re="^${prefix}([0-9]{4})-(0[1-9]|1[0-2])\$"

month=$(date +%Y-%m)
tag="${prefix}${month}"
now_index=$((10#${month%-*} * 12 + 10#${month#*-}))

failed=0

fail() {
  echo "nas-replica-hold: $*" >&2
  failed=1
}

hold_dataset() {
  local ds=$1
  local out holds latest name htag age have=0
  local -a snaps old=()

  # この dataset だけのスナップショットを、受け取った順 (createtxg) に並べる。
  if ! out=$(zfs list -H -o name -t snapshot -d 1 -s createtxg "$ds"); then
    fail "$ds のスナップショットを一覧できない。"
    return
  fi
  if [ -z "$out" ]; then
    fail "$ds に受け取ったスナップショットが無い。"
    return
  fi
  mapfile -t snaps <<<"$out"

  if ! holds=$(zfs holds -H "${snaps[@]}"); then
    fail "$ds の hold を一覧できない。"
    return
  fi

  # このスクリプトが付けた hold だけを見る。他のタグ (syncoid の --use-hold など) には触れない。
  while IFS=$'\t' read -r name htag _; do
    [[ -n $name && $htag =~ $tag_re ]] || continue
    if [ "$htag" = "$tag" ]; then
      have=1
      continue
    fi
    age=$((now_index - (10#${BASH_REMATCH[1]} * 12 + 10#${BASH_REMATCH[2]})))
    if [ "$age" -gt "$keep_months" ]; then
      old+=("$htag"$'\t'"$name")
    fi
  done <<<"$holds"

  if [ "$have" -eq 0 ]; then
    latest=${snaps[-1]}
    if ! zfs hold "$tag" "$latest"; then
      # 今月の分を付けられないときは、古い分も外さない。
      fail "$latest に $tag の hold を付けられない。"
      return
    fi
    echo "$latest に $tag の hold を付けた。"
  fi

  for entry in "${old[@]}"; do
    htag=${entry%%$'\t'*}
    name=${entry#*$'\t'}
    if zfs release "$htag" "$name"; then
      echo "$name から $htag の hold を外した。"
    else
      fail "$name から $htag の hold を外せない。"
    fi
  done
}

for root in "$@"; do
  # 受け先の dataset が無いのは、syncoid がまだ受け取れていないときである。黙って飛ばさない。
  if ! out=$(zfs list -H -o name -t filesystem,volume -r "$root"); then
    fail "受け先の $root が無い。"
    continue
  fi
  mapfile -t datasets <<<"$out"
  for ds in "${datasets[@]}"; do
    hold_dataset "$ds"
  done
done

exit "$failed"
