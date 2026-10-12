# Reuse the baked WarehousePG 7 image (a prebaked EDB base image) — it already
# has warehouse-pg-7 + edb-whpg7-pgfs + edb-whpg7-pgaa, the gpadmin user, sshd, and
# the Greenplum toolchain. Building FROM it skips the dnf/EDB rpm install: no
# EDB_SUBSCRIPTION_TOKEN and no multi-GB download. We only layer OUR init + configs
# (notably init_system.sh, which starts Seafowl on the coordinator AND every segment).
FROM whpg7_cdw:latest

COPY gpinitsystem_config /tmp/
COPY hostfile_gpinitsystem /tmp/
COPY init_system.sh /tmp/

USER root
RUN echo "cdw" > /tmp/gpdb-hosts && \
    chmod 777 /tmp/gpinitsystem_config /tmp/hostfile_gpinitsystem /tmp/init_system.sh

USER gpadmin
ENV USER=gpadmin
WORKDIR /home/gpadmin
EXPOSE 5432 22
CMD ["bash","-c","/tmp/init_system.sh"]
