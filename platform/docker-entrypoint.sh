#!/bin/bash
set -e
set -x

# Ensure /usr/local/bin is prioritized in PATH (where the rokct bench fork lives)
export PATH="/usr/local/bin:$PATH"

# Navigate to bench directory so all bench commands and relative site paths resolve correctly
cd /home/frappe/frappe-bench || exit 1

step() {
  printf "  - %s... " "$1"
}
step_done() { echo "✓ DONE"; }
step_fail() { echo "✗ FAILED: $1"; }

# --- Environment Injection is now handled inside setup_site to ensure bench context exists ---

# Function to setup the site based on MODE
setup_site() {
  echo "🚀 RPanel entrypoint starting (MODE=$MODE SITE=$SITE_NAME)..."

  # Improved Exim Detection:
  # Only skip if EXIM_MODE is explicitly 'host' or if we are NOT in full mode.
  # In 'full' mode, we WANT to bootstrap exim4 unless it's managed by the host.
  if [ "$EXIM_MODE" = "host" ] || [ "$MODE" != "full" ]; then
    echo "Exim managed by host or not in Full mode -> Docker mail stack disabled"
    export SKIP_EXIM=1
  fi

  # 0. First-Boot Volume Seeding
  # When a named volume is mounted over /sites, it shadows the baked site.
  # If common_site_config.json is missing, seed it from the image-baked copy.
  IMAGE_BAKED_SITES="/home/frappe/frappe-bench-image-sites"
  if [ ! -f "sites/common_site_config.json" ] && [ -d "$IMAGE_BAKED_SITES" ]; then
    step "Seeding sites volume from Golden Build"
    cp -a "$IMAGE_BAKED_SITES/." sites/
    step_done
  fi

  # 1. Robust Site Discovery (Req 1)
  # Probe for any initialized site (containing site_config.json)
  step "Discovering baked site"
  BAKED_SITE=$(ls sites/*/site_config.json 2>/dev/null | head -1 | cut -d/ -f2)
  step_done

  if [ ! -d "sites/$SITE_NAME" ]; then
    echo "🔥 Target site '$SITE_NAME' not found in volume."

    # If we have a baked/existing site, RENAME it to the target site name
    if [ -n "$BAKED_SITE" ] && [ "$SITE_NAME" != "$BAKED_SITE" ]; then
      step "Renaming site '$BAKED_SITE' to '$SITE_NAME'"
      mv "sites/$BAKED_SITE" "sites/$SITE_NAME"
      step_done

      # Improvement 1: Install apps after rename
      if [ -n "$INSTALL_APPS" ]; then
        echo "📦 Installing additional apps for renamed site: $INSTALL_APPS"
        for app in $INSTALL_APPS; do
          bench --site "$SITE_NAME" install-app "$app" --force || echo "⚠️ Failed to install $app (might already be installed)"
        done
      fi
    else
      echo "✨ Initializing brand new site '$SITE_NAME'..."
      # 1. Database Connection Check (Retry logic for portable spokes)
      if [ -n "$DB_HOST" ]; then
        echo "⏳ Waiting for Database at $DB_HOST..."
        MAX_TRIES=60
        COUNT=0
        until nc -z "$DB_HOST" "${DB_PORT:-5432}" 2>/dev/null ||
          bash -c "echo >/dev/tcp/$DB_HOST/${DB_PORT:-5432}" 2>/dev/null; do
          COUNT=$((COUNT + 1))
          if [ $COUNT -ge $MAX_TRIES ]; then
            echo "❌ Database at $DB_HOST unreachable after $MAX_TRIES seconds. Exiting."
            exit 1
          fi
          sleep 1
        done
      fi

      # 2. Base Installation / Restoration
      BASE_APPS="rcore brain"
      if [ "$MODE" = "full" ]; then BASE_APPS="rpanel rcore paas control brain"; fi

      # Merge base apps with additional apps, ensuring no duplicates
      # Use :- to guard against unset variables (Req 5)
      FINAL_APPS=$(echo "$BASE_APPS ${INSTALL_APPS:-}" | tr ' ' '\n' | sort -u | tr '\n' ' ')

      # Use an array for flags to handle spaces and empty lists cleanly (Req 2)
      INSTALL_APP_FLAGS=()
      for app in $FINAL_APPS; do
        INSTALL_APP_FLAGS+=(--install-app "$app")
      done

      if [ -f "apps/seed_data/seed.sql.gz" ]; then
        echo "✨ Restoring from Golden Seed (Apps: $FINAL_APPS)..."
        bench new-site "$SITE_NAME" \
          --source-sql "apps/seed_data/seed.sql.gz" \
          --admin-password "${ADMIN_PASSWORD:-admin}" \
          --db-root-password "${DB_ROOT_PASSWORD:-admin}" \
          "${INSTALL_APP_FLAGS[@]}" \
          --force
      else
        echo "⚠️ No Golden Seed found. Performing clean install (Apps: $FINAL_APPS)..."
        bench new-site "$SITE_NAME" \
          --admin-password "${ADMIN_PASSWORD:-admin}" \
          --db-root-password "${DB_ROOT_PASSWORD:-admin}" \
          "${INSTALL_APP_FLAGS[@]}" \
          --force
      fi
    fi

    # 3. Final configuration (Req 3: Map api -> tenant)
    # This block runs for both new-site and rename paths.
    DETERMINED_ROLE="$MODE"
    if [ "$MODE" = "api" ]; then DETERMINED_ROLE="tenant"; fi

    echo "⚙️ Finalizing configuration (Role: $DETERMINED_ROLE)..."
    python3 -c "import json; p='sites/$SITE_NAME/site_config.json'; c=json.load(open(p)); c['app_role']='${APP_ROLE:-$DETERMINED_ROLE}'; json.dump(c, open(p, 'w'), indent=1)"
  else
    echo "✅ Site '$SITE_NAME' already exists in volume."
    # Ensure any updated ENV variables are applied to the existing site
    if [ -n "$DB_HOST" ]; then
      python3 -c "import json; p='sites/$SITE_NAME/site_config.json'; c=json.load(open(p)); c['db_host']='$DB_HOST'; json.dump(c, open(p, 'w'), indent=1)"
    fi
  fi

  # Ensure the default site is set for this container session
  echo "$SITE_NAME" > sites/currentsite.txt

  # --- Global Config Injection (Moved from top to ensure common_site_config.json exists) ---
  python3 -c "
import json, os
p = 'sites/common_site_config.json'
c = json.load(open(p)) if os.path.exists(p) else {}
if os.environ.get('DB_HOST'): c['db_host'] = os.environ['DB_HOST']
if os.environ.get('REDIS_CACHE'): c['redis_cache'] = os.environ['REDIS_CACHE']
if os.environ.get('REDIS_QUEUE'): c['redis_queue'] = os.environ['REDIS_QUEUE']
if os.environ.get('REDIS_SOCKETIO'): c['redis_socketio'] = os.environ['REDIS_SOCKETIO']
json.dump(c, open(p, 'w'), indent=1)
"

  # --- ROK persistence ---
  mkdir -p "sites/$SITE_NAME/private/rok"
  if [ ! -L "/home/frappe/.rok" ]; then
    rm -rf "/home/frappe/.rok" || true
    ln -sfn "$PWD/sites/$SITE_NAME/private/rok" "/home/frappe/.rok"
  fi
}

# Function to start services
start_services() {
  case "$MODE" in
  "full")
    echo "💻 Full Mode (Control Hub): Starting Web + Mail + Bench..."
    if [ "$(id -u)" = "0" ]; then
      if [ "$SKIP_EXIM" != "1" ]; then
        echo "📧 Bootstrapping Exim4..."
        # Run bootstrap, skipping its internal service restart as we do it here
        SKIP_EXIM=1 sudo -E /usr/local/bin/exim4_bootstrap.sh || echo "⚠️ Exim bootstrap warned/failed, attempting start anyway"
        service exim4 start || true
      else
        echo "Skipping Exim bootstrap/start (host-managed)"
      fi
      nginx -g 'daemon off;' &
      mkdir -p /var/run/supervisor || true
      exec sudo -u frappe bench start
    else
      exec bench start
    fi
    ;;
  "api")
    echo "🔌 API Mode (Headless Spoke): Starting Gunicorn + Workers..."
    bench worker &
    WORKER_PID=$!
    bench schedule &
    SCHED_PID=$!
    # wait -n requires bash 4.3+ (Ubuntu 24.04 ships 5.2)
    bench serve --port 8000 &
    SERVE_PID=$!

    wait -n
    CODE=$?

    # Identify which process triggered the exit for better logs
    for pid in $WORKER_PID $SCHED_PID $SERVE_PID; do
      if ! kill -0 "$pid" 2>/dev/null; then
        echo "🚨 Process PID $pid has exited with code $CODE. Shutting down container..."
      fi
    done
    exit $CODE
    ;;
  "iot")
    echo "🔋 IoT Mode (Edge Spoke): Starting Workers + Scheduler only..."
    bench schedule &
    SCHED_PID=$!
    bench worker &
    WORKER_PID=$!
    # wait -n requires bash 4.3+ (Ubuntu 24.04 ships 5.2)
    wait -n
    CODE=$?

    for pid in $WORKER_PID $SCHED_PID; do
      if ! kill -0 "$pid" 2>/dev/null; then
        echo "🚨 Process PID $pid has exited with code $CODE. Shutting down container..."
      fi
    done
    exit $CODE
    ;;
  *)
    echo "⚠️ Unknown MODE: $MODE. Executing: $@"
    exec "$@"
    ;;
  esac
}

# RUN LOGIC
if [ "$1" = "bench" ] && [ "$2" = "start" ]; then
  setup_site
  start_services
fi

exec "$@"
