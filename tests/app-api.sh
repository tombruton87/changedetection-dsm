# Changedetection.io's CGI checks (sourced by chassis/tests/test-api.sh).
W=0b5e2d6c-3f1a-4c2e-9d7b-1a2b3c4d5e6f
expect "watchcheck good" 202 "$(post "$me" watchcheck "action=watchcheck&id=$W")"; request_is "watchcheck request" "ACTION='watchcheck'
WATCH_ID='$W'
BY='$me'"
expect "watchpause bad id" 400 "$(post "$me" watchpause 'action=watchpause&id=1;rm')"
expect "watchadd good" 202 "$(post "$me" watchadd 'action=watchadd&url=https%3A%2F%2Fexample.com%2Fprices%3Fa%3D1%26b%3D2&title=Prices+%26+stock&browser=1')"; request_is "watchadd request (base64url)" "ACTION='watchadd'
URL_B64='aHR0cHM6Ly9leGFtcGxlLmNvbS9wcmljZXM_YT0xJmI9Mg'
VIA_BROWSER='1'
TITLE_B64='UHJpY2VzICYgc3RvY2s'
BY='$me'"
expect "watchadd no scheme" 400 "$(post "$me" watchadd 'action=watchadd&url=javascript%3Aalert(1)')"
expect "watchadd newline" 400 "$(post "$me" watchadd 'action=watchadd&url=https%3A%2F%2Fa.example%0AACTION%3D%27wipe%27')"
expect "watchadd title newline" 400 "$(post "$me" watchadd 'action=watchadd&url=https%3A%2F%2Fa.example&title=a%0Ab')"
expect "lanpages good" 202 "$(post "$me" lanpages 'action=lanpages&on=1')"; rm -f "$CHASSIS_VAR/request"
expect "browser bad" 400 "$(post "$me" browser 'action=browser&on=yes')"
expect "dsmnotify good" 202 "$(post "$me" dsmnotify 'action=dsmnotify&mode=all')"; rm -f "$CHASSIS_VAR/request"
expect "dsmnotify bad" 400 "$(post "$me" dsmnotify 'action=dsmnotify&mode=loud')"
expect "noteadd good" 202 "$(post "$me" noteadd 'action=noteadd&note=ntfys%3A%2F%2Ftk_abc%40ntfy.example.com%2Fdsm')"; request_is "noteadd request" "ACTION='noteadd'
NOTE_B64='bnRmeXM6Ly90a19hYmNAbnRmeS5leGFtcGxlLmNvbS9kc20'
BY='$me'"
expect "noteadd bad" 400 "$(post "$me" noteadd 'action=noteadd&note=not+an+address')"
expect "notetest all" 202 "$(post "$me" notetest 'action=notetest')"; rm -f "$CHASSIS_VAR/request"
expect "notedel needs an id" 400 "$(post "$me" notedel 'action=notedel')"
expect "ntfyuse good" 202 "$(post "$me" ntfyuse 'action=ntfyuse&topic=dsm')"; rm -f "$CHASSIS_VAR/request"
expect "ntfyuse bad topic" 400 "$(post "$me" ntfyuse 'action=ntfyuse&topic=a%2Fb')"
expect "pwset good" 202 "$(post "$me" pwset 'action=pwset&password=correct+horse%27s+%24(id)')"
[[ "$(stat -c %a "$CHASSIS_VAR/request" 2>/dev/null)" == 600 ]] && { (( pass++ )); echo "  ok   the password's request file is private (600)"; } || { (( fail++ )); echo "  FAIL request file mode $(stat -c %a "$CHASSIS_VAR/request" 2>/dev/null)"; }
request_is "pwset request (base64url)" "ACTION='pwset'
PASS_B64='Y29ycmVjdCBob3JzZSdzICQoaWQp'
BY='$me'"
expect "pwset short" 400 "$(post "$me" pwset 'action=pwset&password=short')"
expect "viewer can't pwnew" 403 "$(CHASSIS_ADMINS=no-such-group post "$me" pwnew 'action=pwnew')"
