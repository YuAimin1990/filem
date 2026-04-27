SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export LD_LIBRARY_PATH="${SCRIPT_DIR}/lib_Linux_x86-64:${LD_LIBRARY_PATH}"

NGINX_BIN="openresty/nginx/sbin/nginx"
NGINX_PREFIX="running/"
NGINX_CONF="${NGINX_PREFIX}conf/nginx.conf"
PID_FILE="${NGINX_PREFIX}logs/nginx.pid"

if [ ! -x "$NGINX_BIN" ]; then
  echo "nginx not found: $NGINX_BIN" >&2
  exit 1
fi

if [ ! -f "$NGINX_CONF" ]; then
  echo "nginx.conf not found: $NGINX_CONF" >&2
  exit 1
fi

mkdir -p "${NGINX_PREFIX}logs" "${NGINX_PREFIX}html" "data"

if [ -f "$PID_FILE" ]; then
  PID=$(cat "$PID_FILE" 2>/dev/null)
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    "$NGINX_BIN" -c "conf/nginx.conf" -p "$NGINX_PREFIX" -s reload
    exit $?
  fi
fi

if command -v ss >/dev/null 2>&1; then
  if ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq '(:|\])8095$'; then
    echo "port 8095 is already in use" >&2
    exit 1
  fi
elif command -v netstat >/dev/null 2>&1; then
  if netstat -ltn 2>/dev/null | awk '{print $4}' | grep -Eq '(:|\])8095$'; then
    echo "port 8095 is already in use" >&2
    exit 1
  fi
fi

"$NGINX_BIN" -c "conf/nginx.conf" -p "$NGINX_PREFIX"
