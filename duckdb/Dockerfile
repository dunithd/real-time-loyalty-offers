# Interactive DuckDB CLI for the Kestrel lakehouse walkthrough — a neutral,
# non-EDB engine reading the same Iceberg tables through Lakekeeper. Adapted from
# the Voltline reference. The iceberg + httpfs extensions are baked in at build
# time, so the live session needs no network to LOAD them.
#
# The CLI is fetched with Python (already in the base image, with CA certs) so the
# build needs no apt packages — avoids a flaky apt index on build day.

FROM python:3.12-slim

# Same version as the verifier's DuckDB (1.4.1) so behaviour matches.
RUN python3 - <<'PY'
import gzip, os, platform, shutil, urllib.request
ver = "1.4.1"
arch = "arm64" if platform.machine() in ("aarch64", "arm64") else "amd64"
url = f"https://github.com/duckdb/duckdb/releases/download/v{ver}/duckdb_cli-linux-{arch}.gz"
dst = "/usr/local/bin/duckdb"
with urllib.request.urlopen(url) as r, open(dst, "wb") as f:
    shutil.copyfileobj(gzip.GzipFile(fileobj=r), f)
os.chmod(dst, 0o755)
print("installed duckdb CLI", ver, arch)
PY

# Pre-install extensions so the live LOADs need no network.
RUN duckdb -c "INSTALL iceberg; INSTALL httpfs;"

COPY duckdb_init.sql /root/

# Default: interactive session that attaches the Kestrel lakehouse on startup.
ENTRYPOINT ["duckdb"]
CMD ["-init", "/root/duckdb_init.sql"]
