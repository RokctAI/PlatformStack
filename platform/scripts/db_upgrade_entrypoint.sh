#!/bin/bash
set -e

DATA_DIR="/var/lib/postgresql/data"
VERSION_FILE="$DATA_DIR/PG_VERSION"

# Only perform upgrade check if data directory exists and PG_VERSION is present
if [ -s "$VERSION_FILE" ]; then
    OLD_VERSION=$(cat "$VERSION_FILE" | tr -d '[:space:]')
    # Extract current running major version from postgres binary
    NEW_VERSION=$(postgres -V | awk '{print $3}' | cut -d. -f1)

    if [ "$OLD_VERSION" = "16" ] && [ "$NEW_VERSION" = "17" ]; then
        echo "========================================================================"
        echo "🚨 AUTOMATED UPGRADE DETECTED: Data directory is PG 16, but binary is PG 17."
        echo "🔄 Initiating zero-copy link-mode pg_upgrade..."
        echo "========================================================================"

        # Prepare clean data directory for the PG 17 target
        OLD_DATA="/var/lib/postgresql/data"
        NEW_DATA="/var/lib/postgresql/data_new"
        
        # Ensure we run as postgres user for database catalog initializations
        if [ "$(id -u)" = '0' ]; then
            chown -R postgres:postgres /var/lib/postgresql
            
            # Run initdb and pg_upgrade under postgres user context
            su - postgres -c "
                mkdir -p $NEW_DATA && \
                initdb -D $NEW_DATA && \
                pg_upgrade \
                  -d $OLD_DATA \
                  -D $NEW_DATA \
                  -b /usr/lib/postgresql/16/bin \
                  -B /usr/lib/postgresql/17/bin \
                  --link
            "
            # Swap data directories safely as root
            mv "$OLD_DATA" "/var/lib/postgresql/data_old_backup"
            mv "$NEW_DATA" "$OLD_DATA"
            chown -R postgres:postgres "$OLD_DATA"
        else
            mkdir -p "$NEW_DATA"
            initdb -D "$NEW_DATA"
            pg_upgrade \
              -d "$OLD_DATA" \
              -D "$NEW_DATA" \
              -b /usr/lib/postgresql/16/bin \
              -B /usr/lib/postgresql/17/bin \
              --link
            
            mv "$OLD_DATA" "/var/lib/postgresql/data_old_backup"
            mv "$NEW_DATA" "$OLD_DATA"
        fi

        echo "========================================================================"
        echo "✅ AUTOMATED UPGRADE COMPLETED: Data upgraded successfully to PG 17!"
        echo "🔄 Fallback backup created under /var/lib/postgresql/data_old_backup"
        echo "========================================================================"
    fi
fi

# Execute standard upstream entrypoint
exec docker-entrypoint.sh "$@"
