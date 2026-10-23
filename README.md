# ansible-playbooks

[![ci](https://github.com/and3510/ansible/actions/workflows/ci.yml/badge.svg)](https://github.com/and3510/ansible/actions/workflows/ci.yml)

Infraestrutura como Código (IaC) com Ansible: roles reutilizáveis para provisionar servidores Linux, Docker e um cluster Kubernetes (k3s), testadas de ponta a ponta em um laboratório local com contêineres, sem precisar de VM.

## O que tem aqui

| Role | O que faz |
|------|-----------|
| [`common`](roles/common) | Baseline: pacotes, timezone, atualizações automáticas de segurança, sudo, hardening de SSH e firewall (UFW) opcional |
| [`docker`](roles/docker) | Docker Engine pelo repositório oficial (chave GPG em keyring dedicado), Buildx, Compose v2 e `daemon.json` com rotação de logs |
| [`k3s`](roles/k3s) | Cluster k3s (1 server + N agents) com versão fixa, configuração declarativa em `config.yaml`, token sem segredo versionado e kubeconfig exportado |
| [`nginx`](roles/nginx) | Site estático ou proxy reverso, com headers de segurança e `nginx -t` antes de todo reload |

## Playbooks de operação

Além do provisionamento, há playbooks para o dia a dia (*day-2 operations*):

| Playbook | O que faz |
|----------|-----------|
| [`update.yml`](playbooks/update.yml) | Atualização **rolling** (um host por vez): drena o nó do k3s, aplica updates, reinicia só se `/var/run/reboot-required` existir, espera o nó ficar `Ready` e faz `uncordon`. Qualquer falha interrompe o rollout. |
| [`healthcheck.yml`](playbooks/healthcheck.yml) | Verificação **somente leitura**: serviços esperados por grupo, disco, memória, reboot e updates pendentes, resposta HTTP, nós e pods do k3s. Consolida tudo num resumo e falha se houver problema, o que permite usá-lo como gate no CI ou num cron. |

```bash
ansible-playbook playbooks/healthcheck.yml
ansible-playbook playbooks/update.yml -l k3s_agent -e update_serial=2
```

## Estrutura

```
.
├── ansible.cfg
├── requirements.yml           # collections necessárias
├── Makefile                   # atalhos: make lab-up, make test...
├── lab/                       # laboratório em contêiner (Dockerfile + compose)
├── inventories/
│   └── container/             # inventário do lab em contêiner
│       ├── docker.yml         # inventário DINÂMICO (descobre os contêineres)
│       └── group_vars/
├── playbooks/
│   ├── site.yml               # tudo, na ordem certa
│   ├── update.yml             # atualização rolling
│   ├── healthcheck.yml        # verificação de saúde
│   ├── common.yml
│   ├── docker.yml
│   ├── webservers.yml
│   └── k3s.yml
├── roles/
│   └── <role>/{defaults,tasks,handlers,templates,meta}
└── .github/workflows/ci.yml   # lint + teste e2e no lab em contêiner
```

Os playbooks ficam finos e só ligam grupos do inventário a roles. A lógica fica nas roles e tudo o que muda por ambiente fica em `inventories/<ambiente>/group_vars`. Para um novo ambiente, basta criar outro diretório em `inventories/`, sem tocar em nenhuma role.

## Como rodar

### Laboratório local (sem VM)

Pré-requisitos: Ansible >= 2.15 e Docker. Cada "servidor" é um contêiner Ubuntu com systemd ([lab/](lab)), e o Ansible conecta via `docker exec`, sem SSH.

```bash
ansible-galaxy collection install -r requirements.yml

make lab-up        # sobe web01, k3s-server01 e 1 agent em segundos
make test          # site.yml + checagem de idempotência + healthcheck
make update        # atualização rolling
make lab-down      # destrói tudo

# kubectl no cluster provisionado
export KUBECONFIG=$PWD/artifacts/kubeconfig-k3s-server01.yaml
kubectl get nodes
```

O CI roda exatamente esse fluxo a cada push (job `e2e`).

Cada laboratório pode ser ligado sozinho:

| Comando | Sobe |
|---------|------|
| `make lab-up` | Todos |
| `make lab-up LAB=web` | `web01` |
| `make lab-up LAB=k3s` | `k3s-server01` + 1 agent |
| `make lab-up LAB=k3s AGENTS=5` | `k3s-server01` + 5 agents (também escala um cluster já rodando) |
| `make lab-stop LAB=k3s` | Desliga mantendo o estado; `lab-up` religa |
| `make lab-status` | Mostra o que está ligado |
| `make lab-build` | Reconstrói a imagem dos servidores (os contêineres são recriados no próximo `lab-up`) |
| `make shell HOST=web01` | Abre um shell em um host do lab |
| `make kubectl` | Lista nós e pods pelo kubeconfig exportado |

O inventário é **dinâmico** ([docker.yml](inventories/container/docker.yml)): o plugin `community.docker.docker_containers` lista os contêineres pelo label `lab.role` e monta os grupos sozinho, como o `aws_ec2` faz na nuvem. Para crescer o cluster, basta `make lab-up LAB=k3s AGENTS=5 && ansible-playbook playbooks/k3s.yml`: os nodes existentes não mudam, e os novos entram no cluster.

Reduzir `AGENTS` remove os contêineres, mas o nó continua listado no cluster como `NotReady` até um `kubectl delete node <nome>`.

Com só um lab ligado, limite os playbooks aos hosts dele: `ansible-playbook playbooks/site.yml --limit k3s_cluster`.

> Os contêineres compartilham o kernel do host, e o k3s consome instâncias inotify. Se o `make lab-up` reclamar do limite, aumente uma vez:
> `echo fs.inotify.max_user_instances=512 | sudo tee /etc/sysctl.d/99-ansible-lab.conf && sudo sysctl --system`

### Servidores reais

As roles são as mesmas, só muda o inventário. Crie um em `inventories/<ambiente>/` com os mesmos grupos, apontando para hosts acessíveis por SSH com sudo:

```yaml
# inventories/homelab/hosts.yml
all:
  vars:
    ansible_user: deploy
    ansible_ssh_private_key_file: ~/.ssh/id_ed25519
  children:
    webservers:
      hosts:
        web01: { ansible_host: 10.0.0.10 }
    docker_hosts:
      hosts:
        web01:
    k3s_cluster:
      children:
        k3s_server:
          hosts:
            k3s-server01: { ansible_host: 10.0.0.11 }
        k3s_agent:
          hosts:
            k3s-agent01: { ansible_host: 10.0.0.12 }
```

```bash
ansible-playbook -i inventories/homelab playbooks/site.yml --check --diff   # dry run
ansible-playbook -i inventories/homelab playbooks/site.yml
```

## Decisões de projeto

- **Idempotência**: rodar duas vezes não muda nada. Comandos usam `creates`/`changed_when` e as configs são aplicadas via template com handlers.
- **Versões fixas**: o k3s é instalado com `k3s_version` explícito, então o cluster é reproduzível.
- **Sem segredos no repositório**: o token do k3s é lido do server em tempo de execução (`no_log`). Se preferir um token fixo, defina `k3s_token` com `ansible-vault`.
- **Falha segura**: `validate:` em sudoers e sshd, e `nginx -t` antes de recarregar. Uma configuração inválida falha o playbook em vez de derrubar o serviço.
- **Configuração por ambiente**: nada específico de ambiente fica no `ansible.cfg` nem nas roles. Usuário, chave e IPs ficam no inventário.
- **Qualidade contínua**: a cada push o CI roda `ansible-lint` (perfil `production`) e `yamllint`, provisiona o ambiente inteiro em contêineres, confirma que a segunda execução não altera nada (idempotência) e roda o healthcheck e a atualização rolling.

## Próximos passos

- [ ] Testes com Molecule por role
- [ ] k3s em HA (embedded etcd, 3 servers)
- [ ] Role de observabilidade (Prometheus node_exporter)

## Licença

[MIT](LICENSE)
