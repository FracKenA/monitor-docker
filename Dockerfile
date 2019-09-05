FROM centos:6

# Install EPEL first or else tmux and multitail wont be installed
COPY /entrypoint.d /usr/libexec/entrypoint.d/

# ARG OP5_MONITOR_SOFTWARE_URL=https://d2ubxhm80y3bwr.cloudfront.net/Downloads/op5_monitor_archive/Latest/op5-monitor-latest.tar.gz
ARG OP5_MONITOR_SOFTWARE_URL=https://d2ubxhm80y3bwr.cloudfront.net/Downloads/op5_monitor_archive/op5-monitor-7.5.2.x64.tar.gz

LABEL op5_version="OP5 Monitor Latest Version"
LABEL maintainer="OP5,Ken Dobbins"

#ENV IS_POLLER=NO \
#MASTER= \
#IS_PEER=NO \
#HOSTGROUPS= \
#SELF_HOSTNAME=monitormaster \
#DEBUG=0 \
#ROOT_PASSWORD=monitor \
#IMPORT_BACKUP= \
#LICENSE_KEY= \
#VOLUME_MOUNT=NO \
#VOLUME_PATH=/mnt/junk/ \
#VOLUME_INITIALIZE=NO

STOPSIGNAL SIGTERM

RUN \
    yum -y install epel-release && \
    yum -y install wget nc tmux multitail openssh-server python-requests perl-Module-Load && \
    wget $OP5_MONITOR_SOFTWARE_URL -O /tmp/op5-software.tar.gz && \
    mkdir -p /tmp/op5-monitor && \ 
    tar -zxf /tmp/op5-software.tar.gz -C /tmp/op5-monitor --strip-components=1 && \
    cd /tmp/op5-monitor && \
    ./install.sh --silent && \
    rm -f /tmp/op5-software.tar.gz && \
    rm -rf /tmp/op5-monitor && \
    yum clean all && \
    chmod +x /usr/libexec/entrypoint.d/entrypoint.sh && \
    sed -i -E 's/^(\s*)system\(\);/\1unix-stream("\/dev\/log");/' /etc/syslog-ng/syslog-ng.conf && \
    sed -i -E '/\proc\/kmsg/ s/^#*/#/' /etc/syslog-ng/syslog-ng.conf

# Disable ipv6 binding for postfix
# sed -i 's/inet_protocols = all/inet_protocols = ipv4/g' /etc/postfix/main.cf && \
# Replace the system() source because inside Docker we can't access /proc/kmsg.
# https://groups.google.com/forum/#!topic/docker-user/446yoB0Vx6w


# OP5 Web UI, NRPE, Merlind, SSH, SNMPd 
EXPOSE 80 443 5666 15551 2222 161 162

HEALTHCHECK --interval=90s --timeout=10s --retries=3 \
      CMD mon check distribution --no-perfdata || exit 2

CMD ["/usr/libexec/entrypoint.d/entrypoint.sh"]
