#!/bin/bash
## ======================================================================
## Container initialization script
## Two paths:
##   First boot  — gpinitsystem → configure PGAA → start Seafowl
##   Restart     — gpstart      → start Seafowl
## The /data/master/gpinitsystem_complete flag (in the named volume) is
## the persistent signal that first-boot already ran.
## ======================================================================

# ----------------------------------------------------------------------
# SSH daemon + environment (runs every boot, all hosts)
# ----------------------------------------------------------------------
if ! sudo /usr/sbin/sshd; then
    echo "Failed to start SSH daemon" >&2
    exit 1
fi

sudo ln -sf /usr/bin/python2.7 /usr/bin/python
sudo rm -rf /run/nologin

# Fix ownership of greenplum paths
sudo chown -R gpadmin.gpadmin /usr/local/greenplum-db \
                              /tmp/gpinitsystem_config \
                              /tmp/hostfile_gpinitsystem \
                              /tmp/gpdb-hosts

if [ "$HOSTNAME" == "cdw" ]; then
    sudo chown -R gpadmin.gpadmin /data
else
    sudo chown -R gpadmin.gpadmin /data1
    sudo chown -R gpadmin.gpadmin /data2
fi

# ----------------------------------------------------------------------
# SSH key setup (runs every boot so segment containers get the right keys)
# ----------------------------------------------------------------------
mkdir -p /home/gpadmin/.ssh
chmod 700 /home/gpadmin/.ssh

if [ ! -f /home/gpadmin/.ssh/id_rsa ]; then
    ssh-keygen -t rsa -b 4096 -C gpadmin -f /home/gpadmin/.ssh/id_rsa -P "" > /dev/null 2>&1
fi

cat /home/gpadmin/.ssh/id_rsa.pub >> /home/gpadmin/.ssh/authorized_keys
chmod 600 /home/gpadmin/.ssh/authorized_keys
# Trust all cluster hosts without interactive prompts.
# gpstart uses SSH internally and would hang on unknown host fingerprints.
cat > /home/gpadmin/.ssh/config <<'SSHCFG'
Host cdw sdw1 sdw2
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
SSHCFG
chmod 600 /home/gpadmin/.ssh/config

ssh-keyscan -t rsa cdw sdw1 sdw2 >> /home/gpadmin/.ssh/known_hosts 2>/dev/null

source /usr/local/greenplum-db/greenplum_path.sh
export MASTER_DATA_DIRECTORY=/data/master/gpseg-1

# ----------------------------------------------------------------------
# Seafowl analytics engine — must run on EVERY host (coordinator + segments).
# PGAA scans of Iceberg tables are dispatched to the segments, and each segment
# reaches its executor at its own localhost:47470. If Seafowl runs only on the
# coordinator, distributed reads/writes (e.g. INSERT..SELECT from an Iceberg
# read-handle into a local table) fail on the segments with
# "tcp connect error 127.0.0.1:47470". Defined here so both the segment branch
# below and the coordinator paths further down can call it.
# ----------------------------------------------------------------------
start_seafowl() {
    nohup /usr/edb/whpg7/bin/seafowl -c /etc/edb/pgaa/seafowl.toml --json-logs \
        > /tmp/seafowl.log 2>&1 &
    sleep 2
    if ss -tlnp | grep -q 47470; then
        echo "Seafowl analytics engine started on $HOSTNAME (port 47470)"
    else
        echo "WARNING: Seafowl did not start on $HOSTNAME — check /tmp/seafowl.log" >&2
    fi
}

# Segment hosts: start Seafowl, then idle (the coordinator handles all GP init).
if [ "$HOSTNAME" != "cdw" ]; then
    echo "Segment host $HOSTNAME ready (sshd running, waiting for coordinator)"
    start_seafowl
    /bin/bash
    exit 0
fi

# ----------------------------------------------------------------------
# CDW only from here
# ----------------------------------------------------------------------

INIT_FLAG=/data/master/gpinitsystem_complete

if [ -f "$INIT_FLAG" ]; then
    # ==================================================================
    # RESTART PATH — cluster already initialised, just bring it back up
    # ==================================================================
    echo "Cluster already initialised — starting WHPG cluster..."
    gpstart -a

    echo "Starting Seafowl..."
    start_seafowl

    # Re-create the ephemeral healthcheck flag (not in a volume)
    sudo touch /gpinitsystem_complete

else
    # ==================================================================
    # FIRST BOOT — full gpinitsystem + PGAA setup
    # ==================================================================

    sshpass -p "changeme@123" ssh-copy-id -o StrictHostKeyChecking=no sdw1
    sshpass -p "changeme@123" ssh-copy-id -o StrictHostKeyChecking=no sdw2

    gpinitsystem -a \
                 -c /tmp/gpinitsystem_config \
                 -h /tmp/hostfile_gpinitsystem \
                 --max_connections=100

    printf "sdw1\nsdw2\n" >> /tmp/gpdb-hosts

    # Allow any host to connect
    echo 'host all all 0.0.0.0/0 trust' >> /data/master/gpseg-1/pg_hba.conf
    gpstop -u

    psql -d template1 -c "ALTER USER gpadmin PASSWORD 'changeme@123'"

    cat <<-'EOF'

======================================================================
Demo: WarehousePG with PGAA Database Cluster details
======================================================================
EOF

    echo "Current time: $(date)"
    source /etc/os-release
    echo "OS Version: ${NAME} ${VERSION}"

    psql -P pager=off -d template1 -c "SELECT VERSION()"
    psql -P pager=off -d template1 -c "SELECT * FROM gp_segment_configuration ORDER BY dbid"
    psql -P pager=off -d template1 -c "SHOW optimizer"

    echo ""
    echo "Configuring PGAA and PGFS..."

    # Step 1: Add PGAA + PGFS to shared_preload_libraries, restart to activate hooks
    gpconfig -c shared_preload_libraries -v 'pgaa,pgfs'
    gpstop -a -M fast -r

    # Step 2: Create extensions
    # (pgaa.autostart_seafowl was removed in PGAA v1.9.0 — Seafowl is started
    # explicitly below instead of relying on a GUC)
    psql -d kestrel -c 'CREATE EXTENSION IF NOT EXISTS pgaa CASCADE'
    psql -d kestrel -c 'CREATE EXTENSION IF NOT EXISTS pgfs CASCADE'

    echo ""
    echo "PGAA Version:"
    psql -P pager=off -d kestrel -c 'SELECT pgaa.pgaa_version()'

    echo ""
    echo "Installed Extensions:"
    psql -P pager=off -d kestrel -c '\dx'

    # Step 3: Start Seafowl
    # systemd is not PID 1 in this container so seafowl.service never fires.
    echo "Starting Seafowl analytics engine..."
    start_seafowl

    # Persist the completion flag in the volume so restarts take the fast path
    touch "$INIT_FLAG"
    # Also create the ephemeral flag checked by the Docker healthcheck
    sudo touch /gpinitsystem_complete

fi

echo '
===========================
=  DEPLOYMENT SUCCESSFUL  =
===========================


======================================================================
 __          __            _                          _____   _____
 \ \        / /           | |                        |  __ \ / ____|
  \ \  /\  / /_ _ _ __ ___| |__   ___  _   _ ___  ___| |__) | |  __
   \ \/  \/ / _` | '"'"'__/ _ \ '"'"'_ \ / _ \| | | / __|/ _ \  ___/| | |_ |
    \  /\  / (_| | | |  __/ | | | (_) | |_| \__ \  __/ |    | |__| |
     \/  \/ \__,_|_|  \___|_| |_|\___/ \__,_|___/\___|_|     \_____|

======================================================================'

/bin/bash
