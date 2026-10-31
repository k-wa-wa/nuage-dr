# 受け取ったスナップショットに、一定の間隔で hold を付け、数で外す。
#
# 一次側が乗っ取られて偽のスナップショットを大量に流されると、sanoid が数で古い世代を消し、まともな世代が押し出される。
# それを防ぐため、決まった間隔ごとに 1 つ、そのとき最新の受け取り済みスナップショットに hold をかけ、sanoid にも syncoid にも消させない。
#
# いつ付けるか・どれを外すかは、Pi の側の数えだけで決める。壁時計 (date) は判断に使わない。
#   - 付ける間隔は、Pi が動いていた時間の合計で測る。monotonic の時計 (/proc/uptime、CLOCK_BOOTTIME) を使い、
#     NTP で時計を書き換えられても進まない。止まっていた時間 (再起動をまたいだ分) は足さない
#   - 外すのは数だけで決める。受け取った順 (createtxg) で新しい方から <残す数> 個を残す
# 一次側が付けたスナップショットの名前 (_monthly など) と作成日時 (creation) は、一次側で偽れるので使わない。
# 受け取った順は createtxg で決める。createtxg は受け取った側の pool の txg である。
#
# 使い方: nas-replica-hold <状態のディレクトリ> <間隔の秒数> <残す数> <受け先の dataset>...
# 受け先の dataset とその子のそれぞれについて、次を行う。
#   - 次のどれかのとき、最新のスナップショットに hold を付ける
#     - 状態のファイルが無い (初回)
#     - このスクリプトの hold が 1 つも無い
#     - 前に付けてから、動いていた時間の合計が <間隔の秒数> 以上になった
#   - ただし、最新のスナップショットにこのスクリプトの hold が既にあれば付けない (同じスナップショットに 2 つ付けて数を使わない)
#     経過は戻さないので、次に新しいスナップショットを受け取ったときに付ける
#   - 受け取った順で新しい方から <残す数> 個を残し、それより古い hold を外す
# タグは nuage-keep-YYYY-MM とする。年月は人が見て分かるためだけのもので、判断には使わない。
# 何かに失敗したら、残りの dataset を続けたうえで、最後に失敗で終わる。

if [ "$#" -lt 4 ]; then
  echo "使い方: nas-replica-hold <状態のディレクトリ> <間隔の秒数> <残す数> <受け先の dataset>..." >&2
  exit 2
fi

state_dir=$1
interval=$2
keep=$3
shift 3
if [[ $state_dir != /* ]]; then
  echo "nas-replica-hold: 状態のディレクトリ ($state_dir) は絶対パスで渡す。" >&2
  exit 2
fi
if ! [[ $interval =~ ^[1-9][0-9]*$ ]]; then
  echo "nas-replica-hold: 間隔の秒数 ($interval) は 1 以上の整数で渡す。" >&2
  exit 2
fi
if ! [[ $keep =~ ^[1-9][0-9]*$ ]]; then
  echo "nas-replica-hold: 残す数 ($keep) は 1 以上の整数で渡す。" >&2
  exit 2
fi
if [ ! -d "$state_dir" ]; then
  echo "nas-replica-hold: 状態のディレクトリ $state_dir が無い。" >&2
  exit 1
fi

# このスクリプトが付けた hold のタグ。年月は判断に使わないので、接頭辞だけで見分ける。
prefix=nuage-keep-
tag="${prefix}$(date +%Y-%m)"

# 起動ごとに変わる ID と、起動してからの秒数 (CLOCK_BOOTTIME)。どちらも壁時計を書き換えても変わらない。
boot_id=$(</proc/sys/kernel/random/boot_id)
read -r uptime _ </proc/uptime
uptime=${uptime%%.*}
if ! [[ $boot_id =~ ^[0-9a-f-]+$ && $uptime =~ ^[0-9]+$ ]]; then
  echo "nas-replica-hold: boot_id ($boot_id) か uptime ($uptime) を読めない。" >&2
  exit 1
fi

failed=0

fail() {
  echo "nas-replica-hold: $*" >&2
  failed=1
}

# dataset ごとの状態のファイル。ZFS の名前に使えない % で / を置き換えるので、名前はぶつからない。
state_file() {
  echo "$state_dir/${1//\//%}"
}

# 状態を書く。途中で電源が落ちても壊れないよう、別のファイルに書いて fsync し、置き換える。
write_state() {
  local file=$1 elapsed=$2
  printf 'boot_id=%s\nuptime=%s\nelapsed=%s\n' "$boot_id" "$uptime" "$elapsed" >"$file.tmp" &&
    sync "$file.tmp" &&
    mv "$file.tmp" "$file"
}

hold_dataset() {
  local ds=$1
  local out holds latest name htag i file key value
  local s_boot_id s_uptime s_elapsed elapsed reason=""
  local -a snaps mine=()
  local -A order=()

  # 前に付けてからの経過を読み、前回からの monotonic の経過を足す。
  file=$(state_file "$ds")
  if [ -e "$file" ]; then
    s_boot_id="" s_uptime="" s_elapsed=""
    while IFS='=' read -r key value; do
      case $key in
      boot_id) s_boot_id=$value ;;
      uptime) s_uptime=$value ;;
      elapsed) s_elapsed=$value ;;
      esac
    done <"$file"
    if ! [[ -n $s_boot_id && $s_uptime =~ ^[0-9]+$ && $s_elapsed =~ ^[0-9]+$ ]]; then
      # 壊れた状態は初回と同じに扱う。ユニットは失敗させて気づけるようにし、次からは直した状態で続ける。
      fail "$file の中身が読めない。初回と同じに扱い、書き直す。"
      reason="状態のファイルが読めない"
      elapsed=0
    elif [ "$s_boot_id" = "$boot_id" ]; then
      if [ "$uptime" -lt "$s_uptime" ]; then
        # 同じ起動の中で uptime が戻ることは無い。足さずに失敗させる (遅れる向きなので hold は減らない)。
        fail "$file の uptime ($s_uptime) が今の uptime ($uptime) より大きい。経過を足さない。"
        elapsed=$s_elapsed
      else
        elapsed=$((s_elapsed + uptime - s_uptime))
      fi
    else
      # 再起動をまたいだ。止まっていた時間は測れないので足さず、この起動で動いた分だけを足す。
      elapsed=$((s_elapsed + uptime))
    fi
  else
    reason="状態のファイルが無い"
    elapsed=0
  fi

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
  for i in "${!snaps[@]}"; do
    order[${snaps[i]}]=$i
  done
  latest=${snaps[-1]}

  if ! holds=$(zfs holds -H "${snaps[@]}"); then
    fail "$ds の hold を一覧できない。"
    return
  fi

  # このスクリプトが付けた hold だけを見る。他のタグ (syncoid の --use-hold など) には触れない。
  # 受け取った順の位置・タグ・スナップショットの名前を集める。
  local latest_held=0
  while IFS=$'\t' read -r name htag _; do
    [[ -n $name && $htag == "$prefix"* ]] || continue
    if [ "$name" = "$latest" ]; then
      latest_held=1
    fi
    mine+=("${order[$name]}"$'\t'"$htag"$'\t'"$name")
  done <<<"$holds"

  if [ -z "$reason" ]; then
    if [ "${#mine[@]}" -eq 0 ]; then
      reason="hold が 1 つも無い"
    elif [ "$elapsed" -ge "$interval" ]; then
      reason="前に付けてから ${elapsed} 秒動いた"
    fi
  fi

  if [ -n "$reason" ] && [ "$latest_held" -eq 1 ]; then
    # 最新のスナップショットには既に付いている。数を使わないよう付けず、経過も戻さない。
    echo "$latest には既に hold がある。新しいスナップショットを受け取るまで付けない ($reason)。"
    reason=""
  fi

  if [ -n "$reason" ]; then
    # 先に経過を 0 に戻して書く。書けなければ付けない (付けたのに経過が戻らず、毎回付くのを避ける)。
    if ! write_state "$file" 0; then
      fail "$file に状態を書けない。hold を付けない。"
      return
    fi
    if ! zfs hold "$tag" "$latest"; then
      # 付けられないときは経過を戻し、次の回にもう一度付ける。古い分も外さない。
      write_state "$file" "$elapsed" || fail "$file に状態を書き戻せない。"
      fail "$latest に $tag の hold を付けられない。"
      return
    fi
    echo "$latest に $tag の hold を付けた ($reason)。"
    mine+=("$((${#snaps[@]} - 1))"$'\t'"$tag"$'\t'"$latest")
  elif ! write_state "$file" "$elapsed"; then
    fail "$file に状態を書けない。"
  fi

  # 受け取った順 (createtxg) に並べ、新しい方から keep 個を残す。それより古いものを外す。
  # 順序はタグの年月で決めない。タグの年月は、付けたときの時計に左右されるためである。
  # 同じスナップショットに複数の hold があるときは、タグの順に並べる。
  mapfile -t mine < <(printf '%s\n' "${mine[@]}" | sort -t $'\t' -k1,1n -k2,2)

  for ((i = 0; i < ${#mine[@]} - keep; i++)); do
    IFS=$'\t' read -r _ htag name <<<"${mine[i]}"
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
