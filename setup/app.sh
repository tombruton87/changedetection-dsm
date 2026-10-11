# Changedetection.io's hooks for the chassis core (sourced by run-core.sh). The
# core gives: say, env_get/env_set, rand, compose, in_volume, cname, svc_up,
# leave_secret, notify, fresh, now, json, wait_ready, make_backup, record_backup,
# MSG, VAR, APP, LOG, PKG_NAME, PKG_TITLE.
#
# Watches and notification addresses go through Changedetection.io's own API,
# with the API key it keeps in its settings (changedetection.json in the data
# volume, read from its running container). The password is the one thing the
# API can't set: it's written into those settings with the app stopped, hashed
# exactly the way Changedetection.io hashes it. Free text arrives base64url
# (*_B64) and is checked again here once decoded.

CDS=""; CD_KEY=""; CD_PW=false
CD_REPO=ghcr.io/dgtlmoon/changedetection.io; CD_PIN=0.60.9   # the release this package was tested with; a floor, see cd_floor
CD_BROWSER_IMAGE=dgtlmoon/sockpuppetbrowser:latest
CD_NTFY=ntfy-server; CD_NTFY_USER=changedetection             # the ntfy package's container, and the sender this package makes in it
CD_UUID='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
CD_DEFAULTS=("https://news.ycombinator.com/" "https://changedetection.io/CHANGELOG.txt")   # upstream's example watches on a fresh install

app_validate() {   # key value → 0 if the value has the key's shape
  case "$1" in
    USE_BROWSER|PROTECT|VIA_BROWSER) [[ "$2" =~ ^[01]$ ]] ;;
    WATCH_ID)  [[ "$2" =~ $CD_UUID ]] ;;
    URL_B64)   [[ "$2" =~ ^[A-Za-z0-9_-]+$ ]] && (( ${#2} <= 2800 )) ;;   # no {1,2800}: musl caps a repeat at 255
    TITLE_B64) [[ "$2" =~ ^[A-Za-z0-9_-]+$ ]] && (( ${#2} <= 400 )) ;;
    NOTE_B64)  [[ "$2" =~ ^[A-Za-z0-9_-]+$ ]] && (( ${#2} <= 1400 )) ;;
    PASS_B64)  [[ "$2" =~ ^[A-Za-z0-9_-]+$ ]] && (( ${#2} <= 200 )) ;;
    NOTIFY)    [[ "$2" =~ ^(changes|all|off)$ ]] ;;
    NOTE_ID)   [[ "$2" =~ ^[0-9a-f]{12}$ ]] ;;
    TOPIC)     [[ "$2" =~ ^[A-Za-z0-9_-]{1,64}$ ]] ;;
    *) return 1 ;;
  esac
}

# ------------------------------------------------------------ small helpers
unb64() {   # base64url → text on stdout; 1 if it isn't
  local s=${1//-/+}; s=${s//_//}
  case $(( ${#s} % 4 )) in 2) s+="==" ;; 3) s+="=" ;; 1) return 1 ;; esac
  printf '%s' "$s" | base64 -d 2>/dev/null
}
clean_url() { [[ "$1" =~ ^https?://[^[:space:][:cntrl:]]+$ ]] && (( ${#1} <= 2000 )); }
clean_note() { [[ "$1" =~ ^[a-z][a-z0-9+.-]{1,24}://[^[:space:][:cntrl:]]+$ ]] && (( ${#1} <= 1000 )); }
version_gt() { [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" == "$1" ]]; }
strong_password() { echo "$(rand 5)-$(rand 5)-$(rand 5)-$(rand 5)"; }
note_id() { printf '%s' "$1" | md5sum | cut -c1-12; }
cd_url() { echo "http://127.0.0.1:$(env_get HTTP_PORT)"; }

# ------------------------------------------------------------ talking to Changedetection.io
cd_load() {   # the API key and whether a password is set, from Changedetection.io's own settings (it makes the key at its first start)
  local j; j=$(docker exec "$CDS" cat /datastore/changedetection.json 2>/dev/null) || j=""
  CD_KEY=$(jq -r '.settings.application.api_access_token // ""' <<< "$j" 2>/dev/null | tr -cd 'A-Za-z0-9_-')
  CD_PW=$(jq -r 'if (.settings.application.password // false) then "true" else "false" end' <<< "$j" 2>/dev/null); [[ "$CD_PW" == true ]] || CD_PW=false
  [[ -n "$CD_KEY" ]]
}
cd_api() {   # method path [json] → the body on stdout; 0 for 2xx. Key and body go through files, never a command line.
  local d code args; d=$(mktemp -d)
  printf 'header = "x-api-key: %s"\n' "$CD_KEY" > "$d/cfg"
  args=(-s -K "$d/cfg" -o "$d/out" -w '%{http_code}' --max-time 30 -X "$1")
  [[ -n "${3:-}" ]] && { printf '%s' "$3" > "$d/in"; args+=(-H 'Content-Type: application/json' --data-binary "@$d/in"); }
  code=$(curl "${args[@]}" "$(cd_url)/api/v1/$2" 2>/dev/null)
  cat "$d/out" 2>/dev/null; rm -rf "$d"
  [[ "$code" =~ ^2 ]]
}
cd_details() {   # watch ids on stdin → {id: {paused, muted, backend}}, one request per watch in a single curl
  local d u f; d=$(mktemp -d)
  { printf 'header = "x-api-key: %s"\n' "$CD_KEY"
    while read -r u; do [[ "$u" =~ $CD_UUID ]] && printf 'url = "%s/api/v1/watch/%s"\noutput = "%s/%s.json"\n' "$(cd_url)" "$u" "$d" "$u"; done; } > "$d/cfg"
  curl -s --max-time 60 -K "$d/cfg" >/dev/null 2>&1 || true
  for f in "$d"/*.json; do [[ -s "$f" ]] || continue
    jq -c --arg id "$(basename "$f" .json)" '{($id): {paused: (.paused // false), muted: (.notification_muted // false), backend: (.fetch_backend // "system")}}' "$f" 2>/dev/null
  done | jq -s -c 'add // {}' 2>/dev/null || echo '{}'
  rm -rf "$d"
}
cd_notes() { cd_api GET notifications | jq -c '.notification_urls // []' 2>/dev/null || echo '[]'; }
note_label() {   # an Apprise address → something to show without its secrets (they're often the "host" part: tgram://BOTTOKEN/…)
  local u=$1 scheme rest auth host path
  scheme=${u%%://*}; rest=${u#*://}; rest=${rest%%\?*}; auth=${rest%%/*}; host=${auth##*@}; path=${rest#"$auth"}; path=${path%%\?*}
  [[ "$host" =~ ^[A-Za-z0-9.-]+(:[0-9]+)?$ && "$host" == *[.:]* && ${#host} -le 60 ]] || host="${host:0:4}…"
  case "$scheme" in
    ntfy|ntfys) printf '%s · %s%s' ntfy "$host" "$path" ;;
    mailto|mailtos) printf 'email · %s' "$host" ;;
    *) printf '%s · %s%s' "$scheme" "$host" "$([[ -n "${path#/}" ]] && echo "/…")" ;;
  esac
}
note_list() {   # the JSON array of addresses → [{id, label, scheme, host}]
  jq -r '.[]' <<< "$1" 2>/dev/null | while IFS= read -r u; do
    local a=${u#*://}; a=${a%%\?*}; a=${a%%/*}
    printf '%s\t%s\t%s\t%s\n' "$(note_id "$u")" "$(note_label "$u")" "${u%%://*}" "${a##*@}"
  done | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {id: .[0], label: .[1], scheme: .[2], host: .[3]})' 2>/dev/null || echo '[]'
}
# A test through Apprise inside Changedetection.io's container — the same library and network its notifications use.
CD_PY_TEST='import sys, json, apprise
try:
    import changedetectionio.notification.apprise_plugin.custom_handlers  # its own post:// get:// json:// handlers
except Exception:
    pass
out = []
for u in json.load(sys.stdin):
    a = apprise.Apprise()
    out.append(bool(a.add(u)) and bool(a.notify(title="Changedetection.io: a test from your Synology", body="If this arrived, Changedetection.io can reach you here. Changes to your watches will come the same way.")))
print(json.dumps(out))'
note_test() { jq -c . <<< "$1" | docker exec -i "$CDS" python3 -c "$CD_PY_TEST" 2>>"$LOG" | tail -n 1; }   # addresses (JSON array) → [true|false …]

# ------------------------------------------------------------ the ntfy package on this NAS
ntfy_info() {   # → {found, scheme, port, url}: ntfy's web port as the ntfy package publishes it (80 inside, or 443 with its HTTPS on)
  docker inspect -f '{{.State.Running}}' "$CD_NTFY" 2>/dev/null | grep -qx true || { echo '{"found": false}'; return 0; }
  docker inspect -f '{{json .NetworkSettings.Ports}}' "$CD_NTFY" 2>/dev/null | jq -c --arg ip "$(env_get LAN_IP)" '
    [to_entries[] | select(.key == "80/tcp" or .key == "443/tcp") | .key as $k | (.value // [])[]
      | select((.HostIp // "") | test("^(127\\.|::1$)") | not)            # not the NAS-only port it keeps for DSM
      | {scheme: (if $k == "443/tcp" then "https" else "http" end), port: .HostPort,
         host: (if (.HostIp // "") | test("^(0\\.0\\.0\\.0|::)?$") then $ip else .HostIp end)}] | first
    | if . == null then {found: false} else . + {found: true, url: (.scheme + "://" + .host + ":" + .port)} end' 2>/dev/null || echo '{"found": false}'
}
ntfy_cli() { docker exec "$CD_NTFY" ntfy "$@" 2>&1 </dev/null; }

# ------------------------------------------------------------ lifecycle hooks
app_first_env() {
  env_set CD_IMAGE "$CD_REPO:$CD_PIN"; env_set BROWSER_IMAGE "$CD_BROWSER_IMAGE"
  env_set USE_BROWSER "${USE_BROWSER:-0}"; env_set LAN_PAGES false; env_set DSM_NOTIFY changes
  touch "$VAR/.needs-first"                                       # tidy upstream's example watches once it answers
  [[ "${PROTECT:-1}" == 1 ]] && touch "$VAR/.needs-password"     # and make the password the wizard asked for
  return 0
}
cd_floor() {   # this package's release is the oldest it runs: a package update brings a newer Changedetection.io with it
  local img cur; img=$(env_get CD_IMAGE); cur=${img##*:}
  [[ -n "$img" ]] || { env_set CD_IMAGE "$CD_REPO:$CD_PIN"; return 0; }
  [[ "$img" == "$CD_REPO:"* && "$cur" =~ ^[0-9]+(\.[0-9]+)+$ ]] || return 0   # someone's own image or tag: left as it is
  version_gt "$CD_PIN" "$cur" && { say "this package brings Changedetection.io $CD_PIN (was $cur)"; env_set CD_IMAGE "$CD_REPO:$CD_PIN"; }
  return 0
}
browser_env() {   # the compose profile and the server's driver address, as USE_BROWSER says
  if [[ "$(env_get USE_BROWSER)" == 1 ]]; then env_set COMPOSE_PROFILES browser; env_set BROWSER_URL ws://browser:3000
  else env_set COMPOSE_PROFILES ""; env_set BROWSER_URL ""; fi
  export COMPOSE_PROFILES; COMPOSE_PROFILES=$(env_get COMPOSE_PROFILES)
}
app_load_env() {
  CDS=$(cname server)
  [[ -n "$(env_get BROWSER_IMAGE)" ]] || env_set BROWSER_IMAGE "$CD_BROWSER_IMAGE"
  [[ -n "$(env_get USE_BROWSER)" ]] || env_set USE_BROWSER 0
  [[ -n "$(env_get LAN_PAGES)" ]] || env_set LAN_PAGES false
  [[ -n "$(env_get DSM_NOTIFY)" ]] || env_set DSM_NOTIFY changes
  cd_floor; browser_env
}
app_before_up() {
  env_set X_SETTINGS "$([[ "$(env_get SSL_PROXY)" == 1 ]] && echo 1)"
  browser_env
  if [[ "$(env_get USE_BROWSER)" == 1 ]] && ! docker image inspect "$(env_get BROWSER_IMAGE)" >/dev/null 2>&1; then
    phase "pulling the browser, $(env_get BROWSER_IMAGE) (follow it in the log)"
    docker pull "$(env_get BROWSER_IMAGE)" 2>&1 | grep -vE '^\s*$' | tail -n 5 | tee -a "$LOG" >/dev/null || true
  fi
  return 0
}
app_health() { [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$(cd_url)/" 2>/dev/null)" =~ ^(200|302)$ ]]; }
app_version() {   # Changedetection.io's version, read once per container
  local id; id=$(docker inspect -f '{{.Id}}' "$CDS" 2>/dev/null | cut -c1-12); [[ -n "$id" ]] || return 0
  if [[ "$(head -n 1 "$VAR/.cd-version" 2>/dev/null)" != "$id" ]]; then
    local v; v=$(docker exec "$CDS" sed -n "s/^__version__ = '\([0-9A-Za-z.-]*\)'.*/\1/p" /app/changedetectionio/__init__.py 2>/dev/null | head -n 1)
    [[ -n "$v" ]] && printf '%s\n%s\n' "$id" "$v" > "$VAR/.cd-version"
  fi
  sed -n 2p "$VAR/.cd-version" 2>/dev/null
}
app_after_up() { cd_first 60; }
cd_first() {   # [tries] — once, when it first answers: upstream's example watches go, and the password the wizard asked for is made
  [[ -f "$VAR/.needs-first" || -f "$VAR/.needs-password" ]] || return 0
  local i id list pw n=0
  for i in $(seq 1 "${1:-1}"); do app_health && cd_load && break; sleep 2; done
  cd_load || { say "Changedetection.io's settings aren't there yet — the first-start tidy-up comes shortly"; return 0; }
  if [[ -f "$VAR/.needs-first" ]]; then
    list=$(cd_api GET watch) || { say "Changedetection.io's API didn't answer yet — the first-start tidy-up comes shortly"; return 0; }
    for id in $(jq -r --argjson d "$(printf '%s\n' "${CD_DEFAULTS[@]}" | jq -R . | jq -s -c .)" 'to_entries[] | select(.value.url as $u | $d | index($u)) | .key' <<< "$list" 2>/dev/null); do
      [[ "$id" =~ $CD_UUID ]] && cd_api DELETE "watch/$id" >/dev/null && n=$(( n + 1 ))
    done
    rm -f "$VAR/.needs-first"; (( n )) && say "first start: Changedetection.io's $n example watches were removed — add your own in the window or in Changedetection.io"
  fi
  if [[ -f "$VAR/.needs-password" ]]; then
    pw=$(strong_password)
    if pw_apply "$pw"; then rm -f "$VAR/.needs-password"; leave_secret "Changedetection.io" "$pw" access; say "first start: password protection is on; the password is shown once in the window"
    else say "✗ the password couldn't be set yet ($MSG) — trying again shortly"; fi
  fi
  return 0
}

# ------------------------------------------------------------ the password (Access)
pw_apply() {   # password, or "" for none → into Changedetection.io's settings, with it stopped (running, it keeps settings in memory and writes them back)
  local hash=false rc
  if [[ -n "$1" ]]; then
    hash=$(printf '%s' "$1" | docker exec -i "$CDS" python3 -c 'import sys, os, base64, hashlib
p = sys.stdin.read(); s = os.urandom(32)   # as its SaltyPasswordField does: 32-byte salt + PBKDF2-SHA256, 100000 rounds, base64
print(base64.b64encode(s + hashlib.pbkdf2_hmac("sha256", p.encode("utf-8"), s, 100000)).decode("ascii"))' 2>>"$LOG")
    [[ "$hash" =~ ^[A-Za-z0-9+/]{80,}={0,2}$ ]] || { MSG="The password couldn't be prepared — see the log."; return 1; }
  fi
  say "$([[ "$hash" == false ]] && echo "turning password protection off" || echo "setting Changedetection.io's password") — it's away for a few seconds"
  docker stop -t 30 "$CDS" >> "$LOG" 2>&1 || true
  printf '%s' "$hash" | in_volume data rw -- 'h=$(cat); f=/vol/changedetection.json; [ -s "$f" ] || exit 3
    if [ "$h" = false ]; then jq ".settings.application.password = false" "$f"; else jq --arg h "$h" ".settings.application.password = \$h" "$f"; fi > "$f.pkg" \
      && [ -s "$f.pkg" ] && chmod 600 "$f.pkg" && mv "$f.pkg" "$f"' 2>>"$LOG"
  rc=$?
  docker start "$CDS" >> "$LOG" 2>&1 || true
  wait_ready 180 || { MSG="Changedetection.io hasn't come back yet — see the log."; return 1; }
  (( rc == 0 )) || { MSG="Changedetection.io's settings couldn't be changed — see the log."; return 1; }
  cd_load || true
  return 0
}

# ------------------------------------------------------------ what the window shows
app_status() {
  svc_up server || { echo '{"up": false}'; return 0; }
  cd_load || { echo '{"up": true, "ready": false}'; return 0; }
  local list det notes sys bstate
  list=$(cd_api GET watch) || list='{}'; [[ "$list" == \{* ]] || list='{}'
  det=$(jq -r 'keys[]' <<< "$list" 2>/dev/null | head -n 300 | cd_details)
  notes=$(cd_notes); sys=$(cd_api GET systeminfo) || sys='{}'; [[ "$sys" == \{* ]] || sys='{}'
  read -r bstate _ < <(state_of "$(cname browser)"); [[ "$det" == \{* ]] || det='{}'
  jq -n -c --argjson list "$list" --argjson det "$det" --argjson notes "$(note_list "$notes")" --argjson sys "$sys" --argjson ntfy "$(ntfy_info)" \
     --arg url "$(env_get APP_URL)" --arg notify "$(env_get DSM_NOTIFY)" --arg lan "$(env_get LAN_PAGES)" --arg browser "$(env_get USE_BROWSER)" --arg bstate "$bstate" \
     --argjson pw "$CD_PW" --arg lan_ip "$(env_get LAN_IP)" --arg image "$(env_get CD_IMAGE)" '
    {up: true, ready: true, url: $url, password: $pw, notify: $notify, lan_pages: ($lan == "true"), image: $image,
     browser: {on: ($browser == "1"), state: $bstate},
     queue: ($sys.queue_size // 0), overdue: (($sys.overdue_watches // []) | length),
     watches: ($list | to_entries | map(.value as $w | ($det[.key] // {}) as $d | {
        id: .key, url: ($w.url // ""), title: ($w.title // ""), page_title: ($w.page_title // ""),
        changed: ($w.last_changed // 0), checked: ($w.last_checked // 0), viewed: ($w.viewed // false),
        error: (if ($w.last_error | type) == "string" then $w.last_error[:240] else "" end),
        paused: ($d.paused // false), muted: ($d.muted // false), via_browser: (($d.backend // "") == "html_webdriver")})
        | sort_by([-(.changed), ((.title | select(. != "")) // .page_title // .url)])),
     notes: $notes,
     ntfy: ($ntfy + {connected: ($ntfy.found and ([$notes[] | select((.scheme == "ntfy" or .scheme == "ntfys") and .host == (($ntfy.host // "") + ":" + ($ntfy.port // "")))] | length > 0))})}' 2>/dev/null || echo '{"up": true}'
}

# ------------------------------------------------------------ DSM notifications
watch_changes() {   # changes Changedetection.io found since the last look → DSM desktop notifications
  local mode list marks seen rows n id name url err
  mode=$(env_get DSM_NOTIFY); svc_up server || return 0; cd_load || return 0
  list=$(cd_api GET watch) || return 0; [[ "$list" == \{* ]] || return 0
  marks=$(jq -c 'with_entries(.value = {c: (.value.last_changed // 0), e: (((.value.last_error | type) == "string") and ((.value.last_error | length) > 0))})' <<< "$list" 2>/dev/null) || return 0
  seen=$(cat "$VAR/.seen.json" 2>/dev/null)
  printf '%s\n' "$marks" > "$VAR/.seen.json.tmp" && mv "$VAR/.seen.json.tmp" "$VAR/.seen.json"
  [[ "$seen" == \{* && "$mode" != off ]] || return 0   # the first look only sets the marks: no flood of old changes
  rows=$(jq -c --argjson seen "$seen" --argjson m "$marks" --arg mode "$mode" '
    to_entries | map(select($seen[.key] != null) | .key as $k | .value as $w | $m[$k] as $now | $seen[$k] as $was
      | if $now.c > $was.c and $now.c > 0 then {id: $k, kind: "changed", name: ((($w.title // "") | select(. != "")) // (($w.page_title // "") | select(. != "")) // $w.url), url: $w.url, err: ""}
        elif $mode == "all" and $now.e and ($was.e | not) then {id: $k, kind: "failed", name: ((($w.title // "") | select(. != "")) // (($w.page_title // "") | select(. != "")) // $w.url), url: $w.url, err: $w.last_error}
        else empty end)' <<< "$list" 2>/dev/null)
  n=$(jq 'length' <<< "${rows:-[]}" 2>/dev/null || echo 0)
  (( n > 0 )) || return 0
  if (( n > 5 )); then notify changedmany 0 "$n"; return 0; fi
  jq -r '.[] | [.id, .kind, .name, .url, .err] | @tsv' <<< "$rows" | while IFS=$'\t' read -r id kind name url err; do
    [[ "$(cd_api GET "watch/$id" | jq -r '.notification_muted // false' 2>/dev/null)" == true ]] && continue   # muted in Changedetection.io: quiet here too
    if [[ "$kind" == changed ]]; then notify changed 0 "$name" "$url"; else notify checkfailed 0 "$name" "${err:-no answer}"; fi
  done
}
app_tick() {
  cd_first 1
  watch_changes
  if [[ "$(env_get USE_BROWSER)" == 1 ]] && ! svc_up browser && ! fresh "$VAR/.browser-kick" 300; then   # the core watches the server; the optional browser is watched here
    touch "$VAR/.browser-kick"; say "the browser ($(cname browser)) isn't running — starting it again"; compose up -d browser >> "$LOG" 2>&1 || true
  fi
  return 0
}

# ------------------------------------------------------------ settings, logs, storage, backups, report
app_settings() {   # behind DSM's reverse proxy: Changedetection.io honours its X-Forwarded headers (the core has already saved SSL_PROXY)
  env_set X_SETTINGS "$([[ "$(env_get SSL_PROXY)" == 1 ]] && echo 1)"
  return 1   # nothing of its own changed: the core restarts for the address anyway
}
app_logs() {
  if [[ "$(env_get USE_BROWSER)" == 1 ]]; then docker logs --tail 300 "$(cname browser)" > "$VAR/logs/browser.log.tmp" 2>&1 || true
  else echo "The browser is off (Watches → Browser for JavaScript pages)." > "$VAR/logs/browser.log.tmp"; fi
  for_window "$VAR/logs/browser.log"
}
app_storage() {
  in_volume data ro -- 'cd /vol && printf "all\t%s\n" "$(du -sm . | cut -f1)" && printf "folders\t%s\n" "$(find . -mindepth 2 -maxdepth 2 -name watch.json | wc -l)" && printf "settings_kb\t%s\n" "$(du -sk changedetection.json 2>/dev/null | cut -f1)"; true' </dev/null 2>/dev/null \
    | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {key: .[0], value: (.[1] | tonumber? // 0)}) | from_entries' 2>/dev/null || echo "{}"
}
app_restore() {   # dir — the data volume as the core backs it up (data.tar.gz), and the change marks started afresh
  [[ -s "$1/data.tar.gz" ]] || { MSG="That backup has no data."; return 1; }
  in_volume data rw -- "find /vol -mindepth 1 -delete && tar -C /vol --strip-components=1 -xzf -" < "$1/data.tar.gz" 2>>"$LOG" || { MSG="The data didn't go back; Changedetection.io is left stopped."; return 1; }
  rm -f "$VAR/.seen.json" "$VAR/.cd-version"
}
app_report() {
  local list notes
  cd_load || { echo "== Changedetection.io's settings weren't readable"; return 0; }
  list=$(cd_api GET watch) || list='{}'; notes=$(cd_notes)
  echo "== watches"; jq -r '"total \(length); with an error \([.[] | select((.last_error | type) == "string")] | length); changed at least once \([.[] | select((.last_changed // 0) > 0)] | length)"' <<< "$list" 2>/dev/null
  echo; echo "== notification addresses (kinds only)"; jq -r '.[] | split("://")[0]' <<< "$notes" 2>/dev/null | sort | uniq -c
  echo; echo "== settings"; echo "password protection: $CD_PW; DSM notifications: $(env_get DSM_NOTIFY); pages on the own network: $(env_get LAN_PAGES); browser: $(env_get USE_BROWSER) ($(state_of "$(cname browser)")); image $(env_get CD_IMAGE)"
  echo; echo "== system"; cd_api GET systeminfo | jq -c '{queue_size, overdue: (.overdue_watches | length), uptime, watch_count, version}' 2>/dev/null
  echo; echo "== ntfy on this NAS"; ntfy_info | jq -c 'del(.url)'
  :
}
app_wipe() {   # the optional browser isn't in SERVICES or IMAGE_VARS: its container and image go here
  docker rm -f "$(cname browser)" >> "$LOG" 2>&1 || true
  docker image rm "$(env_get BROWSER_IMAGE)" >> "$LOG" 2>&1 || true
}

# ------------------------------------------------------------ updates (the core's two, for a pinned image on ghcr.io)
# The core compares Docker Hub digests of the same tag. This package pins a release on ghcr.io, so "newer" means a newer
# release tag (from GitHub, checked against ghcr.io), and updating moves the tag — after the backup, and without
# pruning images host-wide: the old version is removed by name.
check_image_update() {
  local img cur latest token code newer=false
  img=$(env_get CD_IMAGE); cur=${img##*:}
  [[ "$img" == "$CD_REPO:"* ]] || { IMAGE_UPDATE='{"error":"a custom image is in use, so it isn'"'"'t checked"}'; return 0; }
  latest=$(curl -fsS --max-time 15 https://api.github.com/repos/dgtlmoon/changedetection.io/releases/latest 2>/dev/null | jq -r '.tag_name // ""' 2>/dev/null | tr -cd '0-9.')
  [[ "$latest" =~ ^[0-9]+(\.[0-9]+)+$ ]] || { IMAGE_UPDATE='{"error":"GitHub could not be reached"}'; return 0; }
  if version_gt "$latest" "$cur"; then
    token=$(curl -fsS --max-time 15 "https://ghcr.io/token?scope=repository:dgtlmoon/changedetection.io:pull" 2>/dev/null | jq -r '.token // ""' 2>/dev/null)
    code=$(printf 'header = "Authorization: Bearer %s"\n' "$token" | curl -s -K - -o /dev/null -I -w '%{http_code}' --max-time 15 \
      -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json" \
      "https://ghcr.io/v2/dgtlmoon/changedetection.io/manifests/$latest" 2>/dev/null)
    [[ "$code" == 200 ]] && newer=true   # a release whose image isn't published yet waits for the next look
  fi
  IMAGE_UPDATE=$(jq -n -c --arg img "$img" --arg cur "$cur" --arg latest "$latest" --argjson newer "$newer" --argjson at "$(now)" '{checked: $at, image: $img, current: $cur, latest: $latest, available: $newer}')
}
update_app() {
  local old to old_browser; old=$(env_get CD_IMAGE); to=$(jq -r '.latest // ""' <<< "$IMAGE_UPDATE" 2>/dev/null)
  say "updating $PKG_TITLE — first, a backup"
  make_backup pre-update || { MSG="Couldn't back up first, so $PKG_TITLE wasn't updated."; return 1; }
  record_backup true "$MADE"
  [[ "$to" =~ ^[0-9]+(\.[0-9]+)+$ && "$old" == "$CD_REPO:"* ]] && version_gt "$to" "${old##*:}" && { env_set CD_IMAGE "$CD_REPO:$to"; say "Changedetection.io ${old##*:} → $to"; }
  old_browser=$(docker image inspect -f '{{.Id}}' "$(env_get BROWSER_IMAGE)" 2>/dev/null)
  say "pulling the newest images"; compose pull 2>&1 | grep -vE '^\s*$' | tail -n 20 | tee -a "$LOG" >/dev/null || true
  if ! compose up -d --remove-orphans 2>&1 | tee -a "$LOG" >/dev/null; then
    env_set CD_IMAGE "$old"; compose up -d >> "$LOG" 2>&1 || true; MSG="The updated containers didn't start, so the version from before is back — see the log."; return 1; fi
  has app_after_up && app_after_up
  wait_ready 900 || { MSG="$PKG_TITLE was updated but hasn't answered yet — see the log."; return 1; }
  [[ "$(env_get CD_IMAGE)" != "$old" ]] && docker image rm "$old" >> "$LOG" 2>&1 || true
  [[ -n "$old_browser" && "$old_browser" != "$(docker image inspect -f '{{.Id}}' "$(env_get BROWSER_IMAGE)" 2>/dev/null)" ]] && docker image rm "$old_browser" >> "$LOG" 2>&1 || true
  check_image_update
  MSG="$PKG_TITLE is updated$(has app_version && echo " to $(app_version)"). The state from before is in $MADE."
}

# ------------------------------------------------------------ actions
recreate() {   # after an .env change: the server (and the browser, by profile) recreated, then ready
  browser_env
  compose up -d --remove-orphans >> "$LOG" 2>&1 || { MSG="$PKG_TITLE didn't start with the change — see the log."; return 1; }
  wait_ready 300 || { MSG="$PKG_TITLE hasn't come back yet — see the log."; return 1; }
}
need_api() { cd_load || { MSG="Changedetection.io isn't answering yet — try again in a minute."; return 1; }; }
app_act() {   # action (request vars are set)
  local out u t n id body notes
  case "$1" in lanpages|browser|dsmnotify|dsmtest) ;; *) need_api || return 1 ;; esac
  case "$1" in
    watchadd)
      u=$(unb64 "${URL_B64:-}") && clean_url "$u" || { MSG="That isn't a web address."; return 1; }
      t=$(unb64 "${TITLE_B64:-}" | tr -d '\000-\037' | cut -c1-200) || t=""
      body=$(jq -cn --arg u "$u" --arg t "$t" --arg b "${VIA_BROWSER:-0}" '{url: $u} + (if $t != "" then {title: $t} else {} end) + (if $b == "1" then {fetch_backend: "html_webdriver"} else {} end)')
      if out=$(cd_api POST watch "$body"); then
        id=$(jq -r '.uuid // ""' <<< "$out" 2>/dev/null)
        [[ "$id" =~ $CD_UUID ]] && cd_api GET "watch/$id?recheck=1" >/dev/null   # its first look now, not at the next round
        MSG="Watching ${t:-$u} — the first check is under way$([[ "${VIA_BROWSER:-0}" == 1 ]] && echo ", with the browser")."; say "watch added: $u"
      else MSG="Changedetection.io didn't take it: $(tr -d '"\000-\037' <<< "$out" | cut -c1-200)$([[ "$(env_get LAN_PAGES)" != true && "$out" =~ [Ii]nvalid ]] && echo " (an address on your own network needs Watches → Pages on your own network)")"; return 1; fi ;;
    watchcheck)
      cd_api GET "watch/$WATCH_ID?recheck=1" >/dev/null && MSG="Checking it now." || { MSG="There's no such watch any more."; return 1; } ;;
    checkall)
      out=$(cd_api GET "watch?recheck_all=1") && MSG="Checking every watch now$(jq -r '.status // "" | if . != "" then " (" + . + ")" else "" end' <<< "$out" 2>/dev/null | sed 's/(OK, /(/')." || { MSG="Changedetection.io didn't start the checks."; return 1; } ;;
    watchpause|watchresume)
      cd_api GET "watch/$WATCH_ID?paused=$([[ "$1" == watchpause ]] && echo paused || echo unpaused)" >/dev/null \
        && MSG="The watch is $([[ "$1" == watchpause ]] && echo "paused" || echo "checked again on its schedule")." || { MSG="There's no such watch any more."; return 1; } ;;
    lanpages)
      env_set LAN_PAGES "$([[ "${ON:-0}" == 1 ]] && echo true || echo false)"; recreate || return 1
      MSG=$([[ "${ON:-0}" == 1 ]] && echo "Pages on your own network (routers, printers, this NAS) can be watched now." || echo "Pages on your own network are refused again; watches of them will show an error.") ;;
    browser)
      env_set USE_BROWSER "${ON:-0}"; browser_env
      if [[ "${ON:-0}" == 1 ]] && ! docker image inspect "$(env_get BROWSER_IMAGE)" >/dev/null 2>&1; then
        say "pulling the browser, $(env_get BROWSER_IMAGE) — about 500 MB"
        docker pull "$(env_get BROWSER_IMAGE)" 2>&1 | grep -vE '^\s*$' | tail -n 5 | tee -a "$LOG" >/dev/null
        docker image inspect "$(env_get BROWSER_IMAGE)" >/dev/null 2>&1 || { env_set USE_BROWSER 0; browser_env; MSG="The browser couldn't be downloaded — see the log."; return 1; }
      fi
      recreate || return 1
      if [[ "${ON:-0}" == 1 ]]; then
        for n in $(seq 1 30); do svc_up browser && break; sleep 2; done
        svc_up browser || { MSG="The browser didn't start — see its log in Maintenance."; return 1; }
        MSG="The browser is on. Pick \"Use the browser\" when adding a watch, or set a watch's fetch method to Chrome in Changedetection.io."
      else docker rm -f "$(cname browser)" >> "$LOG" 2>&1 || true
        MSG="The browser is off; its memory is free again. Watches set to use it will show an error until they're switched to plain fetching."; fi ;;
    dsmnotify)
      env_set DSM_NOTIFY "${NOTIFY:-changes}"
      MSG=$(case "${NOTIFY:-changes}" in changes) echo "DSM will tell you when a watched page changes." ;; all) echo "DSM will tell you when a watched page changes, and when one can't be checked." ;; *) echo "DSM notifications are off; Changedetection.io's own notifications still go." ;; esac) ;;
    dsmtest)
      notify dsmtest 0
      grep -q "told DSM: dsmtest" <<< "$(tail -n 3 "$LOG")" && MSG="A test went to DSM's notifications." || { MSG="DSM's notifications couldn't be reached — the log says why."; return 1; } ;;
    noteadd)
      u=$(unb64 "${NOTE_B64:-}") && clean_note "$u" || { MSG="That isn't an Apprise address."; return 1; }
      if out=$(cd_api POST notifications "$(jq -cn --arg u "$u" '{notification_urls: [$u]}')"); then MSG="Added: $(note_label "$u"). Send a test to see it arrive."; say "notification address added: $(note_label "$u")"
      else MSG="Changedetection.io didn't take it: $(tr -d '"\000-\037' <<< "$out" | cut -c1-200)"; return 1; fi ;;
    notedel)
      notes=$(cd_notes); u=""; while IFS= read -r n; do [[ "$(note_id "$n")" == "$NOTE_ID" ]] && { u=$n; break; }; done < <(jq -r '.[]' <<< "$notes")
      [[ -n "$u" ]] || { MSG="That address isn't there any more."; return 1; }
      cd_api DELETE notifications "$(jq -cn --arg u "$u" '{notification_urls: [$u]}')" >/dev/null || { MSG="Changedetection.io didn't remove it."; return 1; }
      if [[ "$u" =~ ^ntfys?://(tk_[A-Za-z0-9]+)@ ]] && ntfy_cli token list "$CD_NTFY_USER" 2>/dev/null | grep -q "${BASH_REMATCH[1]}"; then ntfy_cli token remove "$CD_NTFY_USER" "${BASH_REMATCH[1]}" >> "$LOG"; fi   # its ntfy token goes too
      MSG="Removed: $(note_label "$u")." ;;
    notetest)
      notes=$(cd_notes)
      [[ -n "${NOTE_ID:-}" ]] && notes=$(jq -r '.[]' <<< "$notes" | while IFS= read -r n; do [[ "$(note_id "$n")" == "$NOTE_ID" ]] && printf '%s\n' "$n"; done | jq -R . | jq -s -c .)
      [[ "$(jq length <<< "$notes")" -gt 0 ]] || { MSG="There's no notification address to test — add one first."; return 1; }
      out=$(note_test "$notes"); n=$(jq '[.[] | select(.)] | length' <<< "${out:-[]}" 2>/dev/null || echo 0)
      [[ "$n" == "$(jq length <<< "$notes")" ]] && MSG="A test went to $([[ "$n" == 1 ]] && echo "$(note_label "$(jq -r '.[0]' <<< "$notes")")" || echo "all $n addresses")." \
        || { MSG="$n of $(jq length <<< "$notes") test$([[ "$(jq length <<< "$notes")" == 1 ]] || echo s) went — the log has what Apprise said."; return 1; } ;;
    ntfyuse) ntfy_use || return 1 ;;
    pwnew)
      local pw; pw=$(strong_password)
      pw_apply "$pw" || return 1
      leave_secret "Changedetection.io" "$pw" access; say "a new Changedetection.io password was made"
      MSG="Password protection is on with a new password — it's shown once, below." ;;
    pwset)
      local pw; pw=$(unb64 "${PASS_B64:-}") || pw=""
      [[ ${#pw} -ge 8 && ${#pw} -le 128 && ! "$pw" =~ [[:cntrl:]] ]] || { MSG="A password is 8 to 128 characters."; return 1; }
      pw_apply "$pw" || return 1
      say "Changedetection.io's password was set from the window"; MSG="Password protection is on with your password." ;;
    pwoff)
      pw_apply "" || return 1
      MSG="Password protection is off: anyone who can reach Changedetection.io can use it." ;;
    *) MSG="Unknown request."; return 1 ;;
  esac
}
ntfy_use() {   # the ntfy package on this NAS: a sender that may only post to TOPIC, its token, and the ntfy address in Changedetection.io
  local info scheme port host url tok old n verify=""
  info=$(ntfy_info); [[ "$(jq -r '.found' <<< "$info")" == true ]] || { MSG="The ntfy package isn't running on this Synology."; return 1; }
  scheme=$(jq -r '.scheme' <<< "$info"); port=$(jq -r '.port' <<< "$info" | tr -cd '0-9'); host="$(jq -r '.host' <<< "$info" | tr -cd '0-9a-fA-F.:'):$port"
  [[ -n "$port" ]] || { MSG="ntfy's port couldn't be read."; return 1; }
  local p; p=$(rand 24)
  printf '%s\n%s\n' "$p" "$p" | docker exec -i "$CD_NTFY" ntfy user add --ignore-exists "$CD_NTFY_USER" >> "$LOG" 2>&1   # its password is never used: it posts with a token
  ntfy_cli access "$CD_NTFY_USER" "$TOPIC" write-only >> "$LOG" || { MSG="ntfy didn't give the sender access to $TOPIC — see the log."; return 1; }
  # A connection made before is replaced, not piled up: its address and its token go.
  while IFS= read -r old; do
    [[ "$old" =~ ^ntfys?://([^@/]*)@${host//./\\.}/ ]] || continue
    tok=${BASH_REMATCH[1]}   # kept now: cd_api's own match would overwrite BASH_REMATCH
    cd_api DELETE notifications "$(jq -cn --arg u "$old" '{notification_urls: [$u]}')" >/dev/null
    [[ "$tok" =~ ^tk_[A-Za-z0-9]+$ ]] && ntfy_cli token remove "$CD_NTFY_USER" "$tok" >> "$LOG"
  done < <(cd_notes | jq -r '.[]')
  tok=$(ntfy_cli token add --label="Changedetection.io" "$CD_NTFY_USER" | grep -oE 'tk_[A-Za-z0-9]+' | head -n 1)
  [[ -n "$tok" ]] || { MSG="ntfy didn't make a token — see the log."; return 1; }
  if [[ "$scheme" == https ]] && ! curl -s -o /dev/null --max-time 10 "https://$host/v1/health"; then verify="?verify=no"; fi   # ntfy's own self-signed certificate
  url="$([[ "$scheme" == https ]] && echo ntfys || echo ntfy)://$tok@$host/$TOPIC$verify"
  cd_api POST notifications "$(jq -cn --arg u "$url" '{notification_urls: [$u]}')" >/dev/null || { MSG="Changedetection.io didn't take the ntfy address."; return 1; }
  say "ntfy: changes go to topic $TOPIC on $host (sender $CD_NTFY_USER, write-only)"
  n=$(note_test "$(jq -cn --arg u "$url" '[$u]')")
  [[ "$n" == "[true]" ]] && MSG="Changes now go to ntfy's $TOPIC topic — a test is on its way." || { MSG="Connected to ntfy's $TOPIC topic, but the test didn't arrive — the log has what Apprise said."; return 1; }
}
