# Imagem de "servidor" para o lab em conteiner: Ubuntu com systemd como PID 1,
# para que as roles rodem como em uma VM (servicos, handlers, timers).
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    container=docker

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        systemd systemd-sysv dbus python3 sudo openssh-server \
        iproute2 iptables kmod ca-certificates tzdata \
    && rm -rf /var/lib/apt/lists/* \
    # Em VMs o ssh sobe por socket activation; aqui o servico precisa
    # estar ativo para o handler de reload e o healthcheck.
    && systemctl disable ssh.socket \
    && systemctl enable ssh.service \
    && systemctl mask getty.target systemd-logind.service

STOPSIGNAL SIGRTMIN+3
CMD ["/lib/systemd/systemd"]
