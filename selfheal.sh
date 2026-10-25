#!/usr/bin/env bash
# WP Self-Healing Helper for the n8n template "Update and roll back WordPress plugins and themes via SSH"
# Install: copy to ~/wp-selfheal/selfheal.sh on the server (called by the workflow via SSH)
# Usage: selfheal.sh <command> <wp-path> <site-url> [more args]
set -u
BASE="$HOME/wp-selfheal"
CMD="$1"; WP_PATH="$2"; SITE_URL="$(printf '%s' "$3" | sed 's#/*$##')"; shift 3
WP_BIN="$(printenv WP_BIN || echo wp)"
WPC="$WP_BIN --path=$WP_PATH"
WPS="$WP_BIN --path=$WP_PATH --skip-plugins --skip-themes"
CRIT_RE='critical error on this website|kritischen Fehler auf|experiencing technical difficulties|technische Schwierigkeiten|Error establishing a database connection|Fehler beim Aufbau einer Datenbankverbindung|Briefly unavailable for scheduled maintenance'
PHPL='function l($f){$s=(string)@file_get_contents($f);$i=strpos($s,"[{");$j=strrpos($s,"}]");if($i===false||$j===false){return [];}$d=json_decode(substr($s,$i,$j-$i+2),true);return is_array($d)?$d:[];}'
mkdir -p "$BASE/runs"

out() {
  php -r '$o=[]; foreach (array_slice($argv,1) as $a) { $p=explode("=",$a,2); $o[$p[0]]=isset($p[1])?$p[1]:""; } echo json_encode($o, JSON_UNESCAPED_SLASHES|JSON_UNESCAPED_UNICODE|JSON_INVALID_UTF8_SUBSTITUTE);' -- "$@"
}

http_check() {
  curl -s -L --max-time 30 -o "$2" -w '%{http_code}' -H 'Cache-Control: no-cache' -A 'Mozilla/5.0 (compatible; WP-SelfHeal-Check)' "$SITE_URL/?selfheal=$1" 2>/dev/null || true
}

site_ok() {
  local OK=1
  case "$1" in 5*|000|"") OK=0 ;; esac
  case "$3" in *SELFHEAL_OK*) ;; *) OK=0 ;; esac
  if [ -f "$2" ] && grep -qiE "$CRIT_RE" "$2"; then OK=0; fi
  echo "$OK"
}

restore_consts() {
  local R="$1"
  [ -f "$R/consts-saved" ] || return 0
  for C in WP_DEBUG WP_DEBUG_LOG WP_DEBUG_DISPLAY; do
    if [ -f "$R/const-$C" ]; then
      $WPS config set "$C" "$(cat "$R/const-$C")" --raw --type=constant >/dev/null 2>&1
    else
      $WPS config delete "$C" --type=constant >/dev/null 2>&1
    fi
  done
  rm -f "$R/consts-saved"
}

target_of() {
  if [ "$1" = "plugin" ]; then
    local ROOT D
    ROOT="$($WPS plugin path 2>/dev/null)"
    D="$($WPS plugin path "$2" --dir 2>/dev/null)"
    if [ -n "$D" ] && [ "$D" = "$ROOT" ]; then $WPS plugin path "$2" 2>/dev/null; else echo "$D"; fi
  else
    $WPS theme path "$2" --dir 2>/dev/null
  fi
}

case "$CMD" in
prepare)
  RUN_ID="$1"; KEEP="$2"; PHPLOG="$3"
  RUN="$BASE/runs/$RUN_ID"
  find "$BASE/runs" -mindepth 1 -maxdepth 1 -type d -mtime +"$KEEP" -exec rm -rf {} + 2>/dev/null
  find "$BASE" -maxdepth 1 -name lock -type d -mmin +360 -exec rm -rf {} + 2>/dev/null
  if ! mkdir "$BASE/lock" 2>/dev/null; then out state=error error="Another update run is already in progress (lock $BASE/lock, released automatically after 6 hours)."; exit 0; fi
  if ! $WP_BIN cli version >/dev/null 2>&1; then rm -rf "$BASE/lock"; out state=error error="WP-CLI ($WP_BIN) is not available on the server."; exit 0; fi
  if ! $WPS core is-installed >/dev/null 2>&1; then rm -rf "$BASE/lock"; out state=error error="No WordPress installation found at $WP_PATH."; exit 0; fi
  CUR="$($WPS config get WP_DEBUG_LOG --type=constant 2>/dev/null)"
  case "$CUR" in
    *selfheal-*)
      for D in "$BASE"/runs/*; do
        if [ -f "$D/logpath" ] && [ "$(cat "$D/logpath")" = "$CUR" ]; then
          restore_consts "$D"
          [ -f "$CUR" ] && mv "$CUR" "$D/debug.log"
        fi
      done
      ;;
  esac
  mkdir -p "$RUN"
  $WPC plugin list --update=available --fields=name,status,version,update_version --format=json > "$RUN/plugins.json" 2>/dev/null
  $WPC theme list --update=available --fields=name,status,version,update_version --format=json > "$RUN/themes.json" 2>/dev/null
  COUNT="$(php -r "$PHPL"' echo count(l($argv[1]))+count(l($argv[2]));' -- "$RUN/plugins.json" "$RUN/themes.json")"
  if [ "$COUNT" = "0" ]; then rm -rf "$RUN" "$BASE/lock"; out state=none; exit 0; fi
  if ! $WPS db export "$RUN/db-before.sql" >/dev/null 2>"$RUN/db-export.err"; then rm -rf "$BASE/lock"; out state=error error="Database backup failed, nothing was changed: $(head -c 400 "$RUN/db-export.err")"; exit 0; fi
  gzip -f "$RUN/db-before.sql"
  CFG="$($WPS config path 2>/dev/null)"
  [ -n "$CFG" ] && cp "$CFG" "$RUN/wp-config.php.bak"
  for C in WP_DEBUG WP_DEBUG_LOG WP_DEBUG_DISPLAY; do
    if $WPS config has "$C" --type=constant >/dev/null 2>&1; then
      $WPS config get "$C" --type=constant --format=var_export > "$RUN/const-$C" 2>/dev/null
    fi
  done
  touch "$RUN/consts-saved"
  CONTENT_DIR="$($WPS eval 'echo WP_CONTENT_DIR;' 2>/dev/null)"
  [ -d "$CONTENT_DIR" ] || CONTENT_DIR="$WP_PATH/wp-content"
  LOG="$CONTENT_DIR/selfheal-$RUN_ID-$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' ').log"
  touch "$LOG"; chmod 666 "$LOG" 2>/dev/null
  echo "$LOG" > "$RUN/logpath"
  $WPS config set WP_DEBUG true --raw --type=constant >/dev/null 2>&1
  $WPS config set WP_DEBUG_LOG "'$LOG'" --raw --type=constant >/dev/null 2>&1
  $WPS config set WP_DEBUG_DISPLAY false --raw --type=constant >/dev/null 2>&1
  $WPS cache flush >/dev/null 2>&1
  BOOT="$($WPC eval 'echo "SELFHEAL_OK";' 2>&1 | tail -c 1500)"
  HTTP="$(http_check "baseline$(date +%s)" "$RUN/baseline.html")"
  if [ "$(site_ok "$HTTP" "$RUN/baseline.html" "$BOOT")" != "1" ]; then
    restore_consts "$RUN"; mv "$LOG" "$RUN/debug.log" 2>/dev/null; rm -rf "$BASE/lock"
    out state=error error="The site was already broken BEFORE the updates or is not reachable from the server (HTTP $HTTP). Nothing was updated." boot="$BOOT"; exit 0
  fi
  sleep 1
  WPV="$($WPS core version 2>/dev/null)"
  PHPV="$(php -r 'echo PHP_VERSION;')"
  php -r "$PHPL"' echo json_encode(["state"=>"updates","run"=>$argv[1],"http"=>$argv[2],"wpVersion"=>$argv[3],"phpVersion"=>$argv[4],"baselineLog"=>$argv[5],"plugins"=>l($argv[6]),"themes"=>l($argv[7])], JSON_UNESCAPED_SLASHES|JSON_UNESCAPED_UNICODE|JSON_INVALID_UTF8_SUBSTITUTE);' -- "$RUN_ID" "$HTTP" "$WPV" "$PHPV" "$(tail -c 8000 "$LOG" 2>/dev/null)" "$RUN/plugins.json" "$RUN/themes.json"
  ;;
update)
  RUN_ID="$1"; TYPE="$2"; NAME="$3"; PHPLOG="$4"
  RUN="$BASE/runs/$RUN_ID"; LOG="$(cat "$RUN/logpath" 2>/dev/null)"
  TARGET="$(target_of "$TYPE" "$NAME")"
  if [ -z "$TARGET" ] || [ ! -e "$TARGET" ]; then out ok=0 error="$TYPE $NAME was not found on the server."; exit 0; fi
  BK="$RUN/$TYPE-$NAME.tar.gz"
  if [ ! -f "$BK" ]; then
    if ! tar -czf "$BK" -C "$(dirname "$TARGET")" "$(basename "$TARGET")" 2>"$RUN/$TYPE-$NAME.tar.err"; then
      rm -f "$BK"; out ok=0 error="Backup failed, update skipped: $(head -c 300 "$RUN/$TYPE-$NAME.tar.err")"; exit 0
    fi
    echo "$TARGET" > "$RUN/$TYPE-$NAME.target"
  fi
  OLDV="$($WPS "$TYPE" get "$NAME" --field=version 2>/dev/null)"
  OFF1="$(wc -c < "$LOG" 2>/dev/null)"; [ -z "$OFF1" ] && OFF1=0
  OFF2=0; if [ -n "$PHPLOG" ] && [ -f "$PHPLOG" ]; then OFF2="$(wc -c < "$PHPLOG")"; fi
  $WPC "$TYPE" update "$NAME" > "$RUN/$TYPE-$NAME.update.out" 2>&1; RC=$?
  rm -f "$WP_PATH/.maintenance"
  sleep 3
  $WPS cache flush >/dev/null 2>&1
  NEWV="$($WPS "$TYPE" get "$NAME" --field=version 2>/dev/null)"
  out ok=1 oldVersion="$OLDV" installedVersion="$NEWV" rc="$RC" off1="$OFF1" off2="$OFF2" output="$(tail -c 1500 "$RUN/$TYPE-$NAME.update.out")"
  ;;
check)
  RUN_ID="$1"; OFF1="$2"; OFF2="$3"; PHPLOG="$4"
  RUN="$BASE/runs/$RUN_ID"; LOG="$(cat "$RUN/logpath" 2>/dev/null)"
  BOOT="$($WPC eval 'echo "SELFHEAL_OK";' 2>&1 | tail -c 1500)"
  sleep 1
  L1="$(tail -c +$((OFF1+1)) "$LOG" 2>/dev/null | tail -c 15000)"
  L2=""
  if [ -n "$PHPLOG" ] && [ -f "$PHPLOG" ]; then L2="$(tail -c +$((OFF2+1)) "$PHPLOG" 2>/dev/null | tail -c 15000)"; fi
  out ok=1 boot="$BOOT" log1="$L1" log2="$L2"
  ;;
rollback)
  RUN_ID="$1"; TYPE="$2"; NAME="$3"
  RUN="$BASE/runs/$RUN_ID"
  BK="$RUN/$TYPE-$NAME.tar.gz"
  if [ ! -f "$BK" ] || [ ! -f "$RUN/$TYPE-$NAME.target" ]; then out ok=0 error="No backup available for $TYPE $NAME."; exit 0; fi
  TARGET="$(cat "$RUN/$TYPE-$NAME.target")"
  case "$TARGET" in
    */plugins/*|*/themes/*) ;;
    *) out ok=0 error="Unexpected target path, rollback aborted for safety: $TARGET"; exit 0 ;;
  esac
  rm -rf "$TARGET"
  tar -xzf "$BK" -C "$(dirname "$TARGET")" 2>"$RUN/$TYPE-$NAME.restore.err"
  rm -f "$WP_PATH/.maintenance"
  $WPS cache flush >/dev/null 2>&1
  sleep 3
  RESTV="$($WPS "$TYPE" get "$NAME" --field=version 2>/dev/null)"
  BOOT="$($WPC eval 'echo "SELFHEAL_OK";' 2>&1 | tail -c 1500)"
  HTTP="$(http_check "rollback$(date +%s)" "$RUN/rollback.html")"
  out ok="$(site_ok "$HTTP" "$RUN/rollback.html" "$BOOT")" restoredVersion="$RESTV" http="$HTTP" boot="$BOOT" error="$(head -c 400 "$RUN/$TYPE-$NAME.restore.err" 2>/dev/null)"
  ;;
finish)
  RUN_ID="$1"
  RUN="$BASE/runs/$RUN_ID"
  restore_consts "$RUN"
  LOG="$(cat "$RUN/logpath" 2>/dev/null)"
  if [ -n "$LOG" ] && [ -f "$LOG" ]; then mv "$LOG" "$RUN/debug.log"; fi
  rm -rf "$BASE/lock"
  STILL="$($WPS config get WP_DEBUG_LOG --type=constant 2>/dev/null)"
  case "$STILL" in *selfheal-*) out ok=0 error="WP_DEBUG_LOG still points to the run log file." ;; *) out ok=1 ;; esac
  ;;
*)
  out ok=0 error="Unknown command: $CMD"
  ;;
esac
