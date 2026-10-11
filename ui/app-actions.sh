# Changedetection.io's actions, validated by the chassis CGI before they become a request file.
# Free text (web and Apprise addresses, titles, a password) travels base64url-encoded: the request file allows only a few characters.
b64u() { printf '%s' "$1" | base64 -w0 | tr '+/' '-_' | tr -d '='; }
app_cgi_post() {   # action body → sets $lines, or error
  local a=$1 body=$2 id u t via on mode n topic p
  case "$a" in
    checkall|dsmtest|pwnew|pwoff) lines="ACTION='$a'" ;;
    watchcheck|watchpause|watchresume)
      id=$(param id "$body"); [[ "$id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || error "400 Bad Request" "Pick a watch."
      lines="ACTION='$a'
WATCH_ID='$id'" ;;
    watchadd)
      u=$(decode "$(param url "$body")"); t=$(decode "$(param title "$body")"); via=$(param browser "$body")
      [[ "$u" =~ ^https?://[^[:space:][:cntrl:]]+$ ]] && (( ${#u} <= 2000 )) || error "400 Bad Request" "A web address, starting with http:// or https://."
      (( ${#t} <= 200 )) && [[ ! "$t" =~ [[:cntrl:]] ]] || error "400 Bad Request" "A title is one line, up to 200 characters."
      [[ "$via" =~ ^[01]?$ ]] || error "400 Bad Request" "With the browser, or without."
      lines="ACTION='watchadd'
URL_B64='$(b64u "$u")'
VIA_BROWSER='${via:-0}'"
      [[ -n "$t" ]] && lines="$lines
TITLE_B64='$(b64u "$t")'" ;;
    lanpages|browser)
      on=$(param on "$body"); [[ "$on" =~ ^[01]$ ]] || error "400 Bad Request" "On or off."
      lines="ACTION='$a'
ON='$on'" ;;
    dsmnotify)
      mode=$(param mode "$body"); [[ "$mode" =~ ^(changes|all|off)$ ]] || error "400 Bad Request" "Changes, changes and failed checks, or off."
      lines="ACTION='dsmnotify'
NOTIFY='$mode'" ;;
    noteadd)
      n=$(decode "$(param note "$body")")
      [[ "$n" =~ ^[a-z][a-z0-9+.-]{1,24}://[^[:space:][:cntrl:]]+$ ]] && (( ${#n} <= 1000 )) || error "400 Bad Request" "An Apprise address looks like ntfys://…, mailtos://…, tgram://… or discord://…"
      lines="ACTION='noteadd'
NOTE_B64='$(b64u "$n")'" ;;
    notedel|notetest)
      id=$(param id "$body"); [[ "$id" =~ ^[0-9a-f]{12}$ || ( "$a" == notetest && -z "$id" ) ]] || error "400 Bad Request" "Pick an address."
      lines="ACTION='$a'"; [[ -n "$id" ]] && lines="$lines
NOTE_ID='$id'" ;;
    ntfyuse)
      topic=$(decode "$(param topic "$body")"); [[ "$topic" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || error "400 Bad Request" "A topic: letters, digits, dash, underscore — up to 64."
      lines="ACTION='ntfyuse'
TOPIC='$topic'" ;;
    pwset)
      p=$(decode "$(param password "$body")")
      (( ${#p} >= 8 && ${#p} <= 128 )) && [[ ! "$p" =~ [[:cntrl:]] ]] || error "400 Bad Request" "A password is 8 to 128 characters."
      umask 077   # the request file is only for the setup container
      lines="ACTION='pwset'
PASS_B64='$(b64u "$p")'" ;;
  esac
}
