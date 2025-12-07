# Anomaly Detection System

Sistema de detecção de anomalias

---

## Sobre

Este repositório documenta o processo de desenho de um sistema de detecção de anomalias.

## Pré-requisitos

- **Docker**: 29.1.1, build: 0aedba5
- **kubectl**: v1.34.2
- **Kustomize**: v5.7.1
- **Minikube**: v1.37.0, commit: 65318f4
- **Helm**: v3.19.2, commit: 8766e71
- **Git**: 2.43.0
- **GitHub Personal Access Token** com permissões:
  - `repo` (acesso a repositórios privados)
  - `read:packages` (ler imagens do GHCR)


## Instalando as dendencias

Você pode instalar as dependências corretas usando o script:

```bash
chmod +x scripts/0-install-dependencies.sh
./scripts/0-install-dependencies.sh
```

## Documentação

0. [Contexto](docs/00-domain-context.md) - Contexto de domínio
1. [Requisitos](docs/01-requirements.md) - Requisitos funcionais e não-funcionais
2. [Estimativa de Capacidade](docs/02-capacity-estimation.md) - Cálculo de escala
3. [Desenho da API](docs/03-api-design.md) - Contratos de API
4. [Desenho de alto nível](docs/04-high-level-design.md) - Desenho de alto nível
