INVENTORY ?= inventories/container
LAB       ?= *
AGENTS    ?= 1
HOST      ?= k3s-server01
KUBECONFIG_LAB := artifacts/kubeconfig-k3s-server01.yaml
COMPOSE   := docker compose -f lab/compose.yml

.PHONY: help preflight lab-up lab-build lab-stop lab-status lab-down shell kubectl provision idempotence healthcheck update test lint

help: ## Lista os comandos disponiveis
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'

lab-up: preflight ## Sobe o lab (LAB=web|k3s, AGENTS=n; padrao: todos, 1 agent)
	$(COMPOSE) --profile '$(LAB)' up -d $(if $(filter web,$(LAB)),,--scale k3s-agent=$(AGENTS))
	@sleep 2 && ansible-inventory -i $(INVENTORY) --graph

lab-build: ## Reconstroi a imagem dos servidores (recria os conteineres no proximo lab-up)
	$(COMPOSE) --profile '*' build --pull

lab-stop: ## Desliga o lab mantendo o estado (LAB=web|k3s)
	$(COMPOSE) --profile '$(LAB)' stop

lab-status: ## Mostra quais servidores estao ligados
	$(COMPOSE) --profile '*' ps -a --format 'table {{.Name}}\t{{.Status}}'

# k3s e Docker dentro dos conteineres consomem instancias inotify do kernel
# do host; o padrao do Ubuntu (128) se esgota e o kubelet nao sobe.
preflight:
	@test $$(sysctl -n fs.inotify.max_user_instances) -ge 512 || { \
		echo 'ERRO: fs.inotify.max_user_instances muito baixo. Rode:'; \
		echo '  echo fs.inotify.max_user_instances=512 | sudo tee /etc/sysctl.d/99-ansible-lab.conf'; \
		echo '  sudo sysctl --system'; \
		exit 1; }

lab-down: ## Destroi todos os labs e os volumes
	$(COMPOSE) --profile '*' down -v --remove-orphans
	rm -rf artifacts/

shell: ## Entra em um host do lab (make shell HOST=web01)
	docker exec -it $(HOST) bash

kubectl: ## Mostra nos e pods do cluster pelo kubeconfig exportado
	@test -f $(KUBECONFIG_LAB) || { echo 'Cluster nao provisionado: rode make provision'; exit 1; }
	KUBECONFIG=$(KUBECONFIG_LAB) kubectl get nodes -o wide
	KUBECONFIG=$(KUBECONFIG_LAB) kubectl get pods -A

provision: ## Roda o site.yml completo
	ansible-playbook -i $(INVENTORY) playbooks/site.yml

idempotence: ## Roda de novo e falha se algo mudar
	ansible-playbook -i $(INVENTORY) playbooks/site.yml | tee /dev/stderr | \
		grep -qE 'changed=[1-9]' && { echo 'FALHA: playbook nao e idempotente'; exit 1; } || echo 'OK: idempotente'

healthcheck: ## Verifica a saude dos hosts
	ansible-playbook -i $(INVENTORY) playbooks/healthcheck.yml

update: ## Atualizacao rolling
	ansible-playbook -i $(INVENTORY) playbooks/update.yml

test: provision idempotence healthcheck ## Teste completo: provisiona, idempotencia e healthcheck

lint: ## yamllint + ansible-lint
	yamllint .
	ansible-lint
