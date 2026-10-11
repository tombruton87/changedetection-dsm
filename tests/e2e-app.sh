# Changedetection.io's steps for the chassis harness (chassis/tests/e2e.sh <appdir> act).
# Needs, besides Changedetection.io's image: python:3.12-alpine (a test page to change), binwiederhier/ntfy
# (a stand-in for the ntfy package), dgtlmoon/sockpuppetbrowser (the browser). No host ports beyond the app's:
# the test page has none, and the ntfy stand-in publishes an ephemeral port on the compose network's gateway only.
app_e2e_answers() { printf "USE_BROWSER='0'\nPROTECT='1'\n"; }
CS=changedetection-server; PAGE=cdtest-page; NT=ntfy-server
wait_for() { local i; for i in $(seq 1 "$2"); do touch "$VAR/watching"; jq -e "$1" "$VAR/status.json" >/dev/null 2>&1 && return 0; sleep 1; done; return 1; }
cd_signin() {   # password → 0 when Changedetection.io lets it in (its own login form, CSRF token and all)
  local jar csrf code; jar=$(mktemp)
  csrf=$(curl -s -c "$jar" -b "$jar" "http://127.0.0.1:$PORT/login" | sed -n 's/.*name="csrf_token" value="\([^"]*\)".*/\1/p' | head -n 1)
  curl -s -c "$jar" -b "$jar" -o /dev/null --data-urlencode "password=$1" --data-urlencode "csrf_token=$csrf" "http://127.0.0.1:$PORT/login"
  code=$(curl -s -b "$jar" -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/"); rm -f "$jar"; [[ "$code" == 200 ]]
}
open_to_all() { [[ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/")" == 200 ]]; }
b64u() { printf '%s' "$1" | base64 -w0 | tr '+/' '-_' | tr -d '='; }
wid() { jq -r --arg u "$1" '[.app.watches[] | select(.url == $u) | .id][0] // ""' "$VAR/status.json"; }
e2e_cleanup() { docker rm -f "$PAGE" >/dev/null 2>&1; [[ -n "${NT_OURS:-}" ]] && docker rm -f "$NT" >/dev/null 2>&1; true; }
app_e2e_act() {
  local fail=0 pw pw2 url ip id gw nport; NT_OURS=""
  log "changedetection.io"
  jq -e '.app.up and .app.ready and (.app.watches | type == "array")' "$VAR/status.json" >/dev/null && echo "  ok   status has watches ($(jq '.app.watches | length' "$VAR/status.json")), version $(jq -r .version "$VAR/status.json")" || { echo "  FAIL status.app: $(jq -c '.app' "$VAR/status.json" | cut -c1-300)"; fail=1; }
  jq -e '.app.watches | length == 0' "$VAR/status.json" >/dev/null && echo "  ok   upstream's example watches were removed" || { echo "  FAIL example watches: $(jq -c '[.app.watches[].url]' "$VAR/status.json")"; fail=1; }

  # Password protection from the first start: shown once; Changedetection.io asks for it; the API key still works.
  pw=$(jq -r 'select(.kind == "access") | .password' "$VAR/secret.json" 2>/dev/null); rm -f "$VAR/secret.json"
  [[ ${#pw} -ge 20 ]] && echo "  ok   a one-time password was left for the window" || { echo "  FAIL no password secret"; fail=1; }
  jq -e '.app.password == true' "$VAR/status.json" >/dev/null && ! open_to_all && echo "  ok   protection is on: / sends strangers to the sign-in page" || { echo "  FAIL protection not on"; fail=1; }
  cd_signin "$pw" && echo "  ok   the password signs in" || { echo "  FAIL sign-in with the first password"; fail=1; }
  cd_signin "wrong-$pw" && { echo "  FAIL a wrong password signs in"; fail=1; } || echo "  ok   a wrong one doesn't"

  # A page on the compose network to watch and change.
  docker rm -f "$PAGE" >/dev/null 2>&1
  docker run -d --name "$PAGE" --network changedetection_default python:3.12-alpine sh -c \
    'mkdir -p /www && printf "<html><head><title>Demo shop</title></head><body><h1>Kettle</h1><p>Price: 24.99</p></body></html>" > /www/index.html && cd /www && exec python -m http.server 8000' >/dev/null || { echo "  FAIL test page"; fail=1; }
  ip=$(docker inspect -f '{{(index .NetworkSettings.Networks "changedetection_default").IPAddress}}' "$PAGE"); url="http://$ip:8000/"
  echo "  (test page: $url)"
  # Pages on your own network: refused until allowed.
  request "ACTION='lanpages'" "ON='1'" || fail=1
  [[ "$(docker exec $CS printenv ALLOW_IANA_RESTRICTED_ADDRESSES)" == true ]] && jq -e '.app.lan_pages' "$VAR/status.json" >/dev/null && echo "  ok   own-network pages allowed" || { echo "  FAIL lanpages"; fail=1; }
  request "ACTION='watchadd'" "URL_B64='$(b64u "$url")'" "TITLE_B64='$(b64u "Kettle at the demo shop")'" || fail=1
  wait_for "[.app.watches[] | select(.url == \"$url\") | .checked > 0 and .error == \"\"] == [true]" 90 && echo "  ok   watched and checked: $(jq -c --arg u "$url" '.app.watches[] | select(.url == $u) | {title, checked, error}' "$VAR/status.json")" || { echo "  FAIL first check: $(jq -c '.app.watches' "$VAR/status.json" | cut -c1-300)"; fail=1; }
  id=$(wid "$url")

  # ntfy: a stand-in for the ntfy package (same auth settings), found and connected in one step.
  if docker ps -a --format '{{.Names}}' | grep -qx "$NT"; then echo "  (an $NT container exists already — the ntfy part is skipped)"
  else
    NT_OURS=1; gw=$(docker network inspect changedetection_default -f '{{(index .IPAM.Config 0).Gateway}}')
    docker run -d --name "$NT" -p "$gw::80" -e NTFY_AUTH_FILE=/tmp/user.db -e NTFY_AUTH_DEFAULT_ACCESS=deny-all -e NTFY_ENABLE_LOGIN=true \
      -e NTFY_CACHE_FILE=/tmp/cache.db -e NTFY_BASE_URL=http://ntfy.example binwiederhier/ntfy serve >/dev/null || fail=1
    sleep 3; nport=$(docker port "$NT" 80/tcp 2>/dev/null | head -n 1 | sed 's/.*://')
    [[ -n "$nport" ]] || { echo "  FAIL the ntfy stand-in didn't start: $(docker logs --tail 3 "$NT" 2>&1 | tr '\n' ' ')"; fail=1; }
    printf 'e2e-pass-1234\ne2e-pass-1234\n' | docker exec -i "$NT" ntfy user add --role=admin reader >/dev/null 2>&1
    poll() { curl -s -u reader:e2e-pass-1234 "http://$gw:$nport/$1/json?poll=1&since=all"; }
    wait_for ".app.ntfy.found == true and .app.ntfy.port == \"$nport\"" 30 && echo "  ok   the ntfy package is found: $(jq -c '.app.ntfy' "$VAR/status.json")" || { echo "  FAIL ntfy not found: $(jq -c '.app.ntfy' "$VAR/status.json")"; fail=1; }
    request "ACTION='ntfyuse'" "TOPIC='dsm'" || fail=1
    poll dsm | grep -q 'a test from your Synology' && echo "  ok   the test reached ntfy's dsm topic" || { echo "  FAIL no test in ntfy: $(poll dsm | head -c 300)"; fail=1; }
    docker exec "$NT" ntfy access changedetection 2>&1 | grep -q "write-only access to topic dsm" && echo "  ok   ntfy's sender may only post to dsm" || { echo "  FAIL sender access: $(docker exec "$NT" ntfy access changedetection 2>&1 | tr '\n' ' ')"; fail=1; }
    wait_for '.app.ntfy.connected == true and (.app.notes | length == 1) and (.app.notes[0].label | test("tk_") | not)' 30 && echo "  ok   shown as connected, without its token: $(jq -r '.app.notes[0].label' "$VAR/status.json")" || { echo "  FAIL ntfy status: $(jq -c '{ntfy: .app.ntfy, notes: .app.notes}' "$VAR/status.json")"; fail=1; }
    request "ACTION='ntfyuse'" "TOPIC='dsm'" >/dev/null || fail=1
    [[ "$(docker exec "$NT" ntfy token list changedetection 2>&1 | grep -c tk_)" == 1 ]] && jq -e '.app.notes | length == 1' "$VAR/status.json" >/dev/null && echo "  ok   connecting again replaces the token and address" || { echo "  FAIL tokens piled up: $(docker exec "$NT" ntfy token list changedetection 2>&1 | tr '\n' ' ')"; fail=1; }
  fi

  # A change: the page changes, "check now" finds it — the window, DSM's notifications and ntfy all hear of it.
  docker exec "$PAGE" sed -i 's/24.99/19.99/' /www/index.html
  request "ACTION='watchcheck'" "WATCH_ID='$id'" || fail=1
  wait_for "[.app.watches[] | select(.id == \"$id\") | .changed > 0 and (.viewed | not)] == [true]" 90 && echo "  ok   the change was detected and isn't viewed yet" || { echo "  FAIL no change: $(jq -c --arg i "$id" '.app.watches[] | select(.id == $i)' "$VAR/status.json")"; fail=1; }
  local i; for i in $(seq 1 30); do grep -qE 'told DSM: changed|notification \(changed\)' "$VAR/package.log" && break; touch "$VAR/watching"; sleep 2; done
  grep -qE "told DSM: changed|a DSM notification \(changed\)" "$VAR/package.log" && echo "  ok   the change went to DSM's notifications ($(grep -oE 'told DSM: changed|notification \(changed\) didn.t go' "$VAR/package.log" | tail -n 1) — no DSM here)" || { echo "  FAIL no DSM notification attempt for the change"; fail=1; }
  if [[ -n "${NT_OURS:-}" ]]; then for i in $(seq 1 30); do poll dsm | grep -q "$ip:8000" && break; sleep 2; done
    poll dsm | grep -q "$ip:8000" && echo "  ok   Changedetection.io's own notification of the change reached ntfy" || { echo "  FAIL no change notification in ntfy: $(poll dsm | tail -c 400)"; fail=1; }; fi

  # Pause, resume, check everything.
  request "ACTION='watchpause'" "WATCH_ID='$id'" || fail=1
  wait_for "[.app.watches[] | select(.id == \"$id\") | .paused] == [true]" 20 && echo "  ok   paused" || { echo "  FAIL not paused"; fail=1; }
  request "ACTION='watchresume'" "WATCH_ID='$id'" || fail=1
  wait_for "[.app.watches[] | select(.id == \"$id\") | .paused] == [false]" 20 && echo "  ok   resumed" || { echo "  FAIL not resumed"; fail=1; }
  request "ACTION='checkall'" || fail=1

  # Notification addresses: add one with a secret (shown without it), refuse junk, test, remove.
  request "ACTION='noteadd'" "NOTE_B64='$(b64u "mailtos://someone:hunter2secret@mail.example.com?to=me@example.com")'" || fail=1
  wait_for '.app.notes | map(.label) | index("email · mail.example.com")' 20 && ! grep -q hunter2secret "$VAR/status.json" && echo "  ok   listed as \"email · mail.example.com\", without its password" || { echo "  FAIL note label: $(jq -c '.app.notes' "$VAR/status.json")"; fail=1; }
  request "ACTION='noteadd'" "NOTE_B64='$(b64u "javascript:alert(1)")'" >/dev/null && { echo "  FAIL junk address taken"; fail=1; } || echo "  ok   a junk address is refused by the setup container too"
  [[ -n "${NT_OURS:-}" ]] && { request "ACTION='notetest'" "NOTE_ID='$(jq -r '.app.notes[] | select(.label | startswith("ntfy")) | .id' "$VAR/status.json")'" || fail=1; }
  request "ACTION='notedel'" "NOTE_ID='$(jq -r '.app.notes[] | select(.label | startswith("email")) | .id' "$VAR/status.json")'" || fail=1
  wait_for '.app.notes | map(.label) | index("email · mail.example.com") | not' 20 && echo "  ok   removed" || { echo "  FAIL not removed"; fail=1; }
  if [[ -n "${NT_OURS:-}" ]]; then
    request "ACTION='notedel'" "NOTE_ID='$(jq -r '.app.notes[] | select(.label | startswith("ntfy")) | .id' "$VAR/status.json")'" || fail=1
    [[ "$(docker exec "$NT" ntfy token list changedetection 2>&1 | grep -c tk_)" == 0 ]] && echo "  ok   removing the ntfy address removes its token from ntfy" || { echo "  FAIL ntfy token left: $(docker exec "$NT" ntfy token list changedetection 2>&1 | tr '\n' ' ')"; fail=1; }
  fi

  # DSM notifications: the setting, and a test (which can only fail here — there's no DSM).
  request "ACTION='dsmnotify'" "NOTIFY='all'" || fail=1
  jq -e '.app.notify == "all"' "$VAR/status.json" >/dev/null && echo "  ok   notify=all" || { echo "  FAIL notify setting"; fail=1; }
  request "ACTION='dsmnotify'" "NOTIFY='changes'" >/dev/null || fail=1
  request "ACTION='dsmtest'" >/dev/null; grep -qE "told DSM: dsmtest|a DSM notification \(dsmtest\) didn't go" "$VAR/package.log" && echo "  ok   the DSM test was tried ($(grep -oE "told DSM: dsmtest|didn't go" "$VAR/package.log" | tail -n 1) — no DSM here)" || { echo "  FAIL no DSM test attempt"; fail=1; }

  # Access: a new password, your own, and off.
  request "ACTION='pwnew'" || fail=1
  pw2=$(jq -r 'select(.kind == "access") | .password' "$VAR/secret.json" 2>/dev/null); rm -f "$VAR/secret.json"
  cd_signin "$pw2" && ! cd_signin "$pw" && echo "  ok   the new password signs in, the old one doesn't" || { echo "  FAIL new password"; fail=1; }
  request "ACTION='pwset'" "PASS_B64='$(b64u "correct horse's \$(id) battery")'" || fail=1
  cd_signin "correct horse's \$(id) battery" && ! cd_signin "$pw2" && echo "  ok   your own password (quotes, \$, spaces) signs in" || { echo "  FAIL own password"; fail=1; }
  request "ACTION='pwoff'" || fail=1
  open_to_all && jq -e '.app.password == false' "$VAR/status.json" >/dev/null && echo "  ok   protection off: / is open" || { echo "  FAIL protection still on"; fail=1; }
  request "ACTION='pwnew'" >/dev/null || fail=1; rm -f "$VAR/secret.json"
  ! open_to_all && echo "  ok   and on again" || { echo "  FAIL not on again"; fail=1; }

  # Behind DSM's reverse proxy: X-Forwarded headers honoured; the address goes into notification links.
  request "ACTION='settings'" "APP_URL='https://changes.example.com'" "HTTP_PORT='$PORT'" "SSL_PROXY='1'" "APP_TZ='Europe/London'" || fail=1
  [[ "$(docker exec $CS printenv USE_X_SETTINGS)" == 1 && "$(docker exec $CS printenv BASE_URL)" == https://changes.example.com ]] && echo "  ok   behind a proxy: USE_X_SETTINGS=1, BASE_URL=https://changes.example.com" || { echo "  FAIL proxy settings"; fail=1; }
  request "ACTION='settings'" "APP_URL='http://127.0.0.1:$PORT'" "HTTP_PORT='$PORT'" "SSL_PROXY='0'" "APP_TZ='Europe/London'" >/dev/null || fail=1
  [[ -z "$(docker exec $CS printenv USE_X_SETTINGS)" ]] && echo "  ok   and back" || { echo "  FAIL USE_X_SETTINGS still set"; fail=1; }

  # The browser: on, a watch through Chrome, off — skipped when this box is short of memory.
  local avail; avail=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
  if (( avail < 1500 )); then echo "  (only $avail MB available — the browser step is skipped)"; else
  request "ACTION='browser'" "ON='1'" || fail=1
  docker ps --format '{{.Names}}' | grep -qx changedetection-browser && [[ "$(docker exec $CS printenv PLAYWRIGHT_DRIVER_URL)" == ws://browser:3000 ]] && echo "  ok   the browser runs and the server uses it" || { echo "  FAIL browser on"; fail=1; }
  request "ACTION='watchadd'" "URL_B64='$(b64u "${url}?js")'" "VIA_BROWSER='1'" || fail=1
  wait_for "[.app.watches[] | select(.url == \"${url}?js\") | .checked > 0 and .error == \"\" and .via_browser] == [true]" 120 && echo "  ok   a page fetched through Chrome: $(jq -c --arg u "${url}?js" '.app.watches[] | select(.url == $u) | {title: (.title // .page_title), page_title, via_browser}' "$VAR/status.json")" || { echo "  FAIL browser watch: $(jq -c --arg u "${url}?js" '.app.watches[] | select(.url == $u)' "$VAR/status.json")"; docker logs --tail 15 changedetection-browser 2>&1 | sed 's/^/       /'; fail=1; }
  request "ACTION='browser'" "ON='0'" || fail=1
  ! docker ps -a --format '{{.Names}}' | grep -qx changedetection-browser && [[ -z "$(docker exec $CS printenv PLAYWRIGHT_DRIVER_URL)" ]] && echo "  ok   the browser is off and gone" || { echo "  FAIL browser off"; fail=1; }
  fi

  # Backup and restore: a watch added after the backup is gone again, the one before is back.
  request "ACTION='backup'" || fail=1
  local bk; bk=$(jq -r '.backups[0].name' "$VAR/status.json")
  request "ACTION='watchadd'" "URL_B64='$(b64u "${url}?later")'" || fail=1
  wait_for "[.app.watches[] | select(.url == \"${url}?later\")] | length == 1" 20 || { echo "  FAIL later watch"; fail=1; }
  request "ACTION='restore'" "BACKUP='$bk'" || fail=1
  wait_for "([.app.watches[] | select(.url == \"${url}?later\")] | length == 0) and ([.app.watches[] | select(.id == \"$id\")] | length == 1)" 60 && echo "  ok   restored: the later watch is gone, the earlier ones are back" || { echo "  FAIL restore: $(jq -c '[.app.watches[].url]' "$VAR/status.json")"; fail=1; }
  [[ "$(grep -c "told DSM: changed\|notification (changed)" "$VAR/package.log")" -le 2 ]] && echo "  ok   no burst of old changes after the restore" || { echo "  FAIL notifications after restore"; fail=1; }

  # Updates: a pinned release is compared with GitHub's newest; updating moves the tag (pretend the pin is older).
  docker exec "$NAME" sed -i "s|^CD_IMAGE=.*|CD_IMAGE=ghcr.io/dgtlmoon/changedetection.io:0.60.8|" "$APP/.env"   # .env is root's: changed from the setup container
  request "ACTION='check'" || fail=1
  jq -e '.image_update.available == true and .image_update.current == "0.60.8"' "$VAR/status.json" >/dev/null && echo "  ok   newer release seen: $(jq -c '.image_update | {current, latest, available}' "$VAR/status.json")" || { echo "  FAIL update check: $(jq -c '.image_update' "$VAR/status.json")"; fail=1; }
  request "ACTION='updateapp'" || fail=1
  [[ "$(docker exec "$NAME" grep '^CD_IMAGE=' "$APP/.env")" == "CD_IMAGE=ghcr.io/dgtlmoon/changedetection.io:$(jq -r .image_update.latest "$VAR/status.json")" ]] && jq -e '.image_update.available == false' "$VAR/status.json" >/dev/null && echo "  ok   updated: $(docker exec "$NAME" grep '^CD_IMAGE=' "$APP/.env")" || { echo "  FAIL update: $(docker exec "$NAME" grep '^CD_IMAGE=' "$APP/.env") $(jq -c .image_update "$VAR/status.json")"; fail=1; }
  grep -q "docker image prune\|images prune" "$VAR/package.log" && { echo "  FAIL something pruned"; fail=1; } || true

  e2e_cleanup
  (( fail == 0 )) && echo "  changedetection.io: all passed" || echo "  changedetection.io: something FAILED"
  return $fail
}
