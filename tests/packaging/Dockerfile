# Verified OCI index: native linux/amd64 and linux/arm64/v8, Rocky 8.10.
FROM rockylinux/rockylinux:8.10@sha256:e8a49c5403b687db05d4d67333fa45808fbe74f36e683cec7abb1f7d0f2338c6
ARG PG
RUN case "$PG" in 15|16|17|18) ;; *) exit 1 ;; esac && \
    dnf -y install ca-certificates binutils python3 util-linux && \
    dnf -y module disable postgresql && \
    case "$(uname -m)" in \
      x86_64) PGDG_KEY=PGDG-RPM-GPG-KEY-RHEL ;; \
      aarch64) PGDG_KEY=PGDG-RPM-GPG-KEY-AARCH64-RHEL ;; \
      *) exit 1 ;; \
    esac && \
    printf '[pgdg]\nname=Official PGDG EL8\nbaseurl=https://download.postgresql.org/pub/repos/yum/%s/redhat/rhel-8-$basearch\nenabled=1\ngpgcheck=1\nrepo_gpgcheck=1\ngpgkey=https://download.postgresql.org/pub/repos/yum/keys/%s\n[pgdg-common]\nname=Official PGDG common EL8\nbaseurl=https://download.postgresql.org/pub/repos/yum/common/redhat/rhel-8-$basearch\nenabled=1\ngpgcheck=1\nrepo_gpgcheck=1\ngpgkey=https://download.postgresql.org/pub/repos/yum/keys/%s\n' "$PG" "$PGDG_KEY" "$PGDG_KEY" > /etc/yum.repos.d/pgdg-smoke.repo && \
    dnf -y --enablerepo=powertools --setopt=install_weak_deps=False install "postgresql${PG}-server" "postgresql${PG}-devel" "postgresql${PG}-libs" && \
    dnf clean all
ENV PG_MAJOR=${PG}
ENV PATH=/usr/pgsql-${PG}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
COPY scripts/archive-smoke.py /smoke/archive-smoke.py
COPY tests/packaging/smoke.sh /smoke/smoke.sh
ENTRYPOINT ["bash", "/smoke/smoke.sh"]
