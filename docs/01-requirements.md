# Requisitos

Este documento define os requisitos funcionais e não-funcionais do sistema de detecção de anomalias.

---

## Requisitos Funcionais

#### 1. Gerenciamento de modelos

- Treinar modelos de detecção de anomalia a partir de valores com registro de data e hora via API
- O sistema deve suportar o treinamento e inferência para múltiplas e distintas séries temporais, cada uma identificada por uma única _series_id_.
- O sistema deve persistir os 'pesos' do modelo, versionamento e prover predições em tempo real.
- Persistir modelos treinados para reuso.
- Manter modelos separados por _series_id_ com suporte a versionamento.
- Suportar o retreinamento do modelo de cada _series_id_, versionando cada modelo.
- Ferramenta de visualização: prover um `/plot?series_id=sensor_XYZ&version=v3` endpoint para mostrar os dados de treinamento.
- Lidar com solicitações concorrentes de treinamento e predição.
- **Warm model loading**: pré-carregar modelos mais acessados em memória ao inicializar pods

#### 2. Predições

- Validação preliminar: rejeitar dados de treinamento insuficientes, constantes ou inválidos
- Prever se o novo ponto é anômalo dado uma _series_id_
- Retornar a versão do modelo e a predição
- Suportar predições com versão específica do modelo via query parameter
- **Batch predictions**: endpoint para predizer múltiplos pontos de uma vez (otimização de throughput)
- **Fallback**: se modelo treinado falhar ou não existir, usar modelo baseline Z-score (|x - μ| > 3σ)

#### 3. Monitoramento

- Reportar métricas de performance a nível de sistema (latência, carga, etc.)
- Endpoint `/healthcheck` com métricas agregadas:
  - Número de séries treinadas
  - Latência média e P95 de inferência
  - Latência média e P95 de treinamento
  - Número de modelos em cache
  - Uptime do serviço
- Endpoint `/readiness` para Kubernetes readiness probe
- Endpoint `/liveness` para Kubernetes liveness probe

#### 4. Persistência e Versionamento

- Cada modelo deve ter identificador único composto por `series_id` + `version`
- Versionamento semântico incremental: v1, v2, v3... (automático)
- Armazenamento durável de:
  - Pesos do modelo (mean, std)
  - Metadados (timestamp de criação, número de pontos usados, hash dos dados de treino)
  - Dados de treinamento (opcional, para visualização) - armazenar apenas últimos N pontos
  - Métricas de treino (std, min, max, quantis)
- Rollback: capacidade de usar versões anteriores do modelo
- **Model registry**: catálogo centralizado de todos os modelos com metadados searchable
- **Retention policy**: manter últimas 10 versões por series_id, arquivar versões antigas

#### 5. Validação de Entrada

- **Dados de Treinamento**:
  - Mínimo de pontos necessários (>= 10_000)
  - Rejeitar séries constantes (std < 1e-6)
  - Validar timestamps em ordem cronológica crescente
  - Validar formato Unix timestamp (int64, positivo)
  - Rejeitar valores NaN, infinitos ou fora de range físico plausível
  - Validar que não há duplicatas de timestamp
  - Máximo de pontos aceitos (<= 100.000 para evitar OOM)

- **Dados de Predição**:
  - Validar que series_id existe e tem modelo treinado
  - Validar formato do timestamp e value
  - Retornar warning se timestamp está muito no passado ou futuro

#### 6. Deployment e Release

- **Shadow Deployment**: 
  - Rodar nova versão do modelo em paralelo sem afetar produção
  - Comparar predições da versão nova vs atual
  - Coletar métricas de comparação (agreement rate, latência)
  - Promover para produção quando agreement rate > 95%

- **Canary Deployment (Testes A/B)**:
  - Distribuir tráfego gradualmente entre versões (5% → 25% → 50% → 100%)
  - Comparar métricas de ML em produção (precision, recall, F1, false positive rate)
  - Monitorar degradação de performance (latência, error rate)
  - Rollback automático se métricas piorarem além do threshold configurado
  - Promover para 100% quando métricas de negócio validarem superioridade
---

## Requisitos Não-Funcionais

#### 1. Disponibilidade

- 99.99% de uptime (downtime máximo: ~52min/ano)
- Sistema deve ser resiliente a falhas de componentes individuais
- Graceful degradation: se um modelo falhar, não deve afetar outros
- **Circuit breaker**: evitar cascading failures se storage backend ficar lento
- **Multi-AZ deployment**: pods distribuídos em múltiplas availability zones
- **Health checks**: liveness (pod está vivo) e readiness (pod está pronto para tráfego)

#### 2. Performance

- **Latência**:
  - Carregamento de modelos (cold start): < 2s
  - Inferência P50: < 10ms
  - Inferência P95: < 30ms  
  - Inferência P99: < 50ms
  - Treinamento P99: < 5s para datasets típicos (~1000 pontos)
  - Treinamento máximo: < 30s para datasets grandes (100k pontos)
  
- **Throughput**:
  - Suportar 100.000 sensores enviando dados a cada 5 minutos
  - Peak load: ~333 req/s de inferência (100k / 300s)
  - Cada sensor: 3 canais × ~15.360 pontos/canal
  - Cada ponto processado por 30 modelos independentes
  - **Total de inferências**: 100k sensores × 3 canais × 30 modelos = 9M predições a cada 5 min
  - **Throughput efetivo**: ~30.000 predições/segundo no pico

- **Resource Limits** (por pod):
  - CPU request: 500m, limit: 2 cores
  - Memory request: 1Gi, limit: 4Gi
  - Tempo de resposta mesmo com carga alta: < 100ms P99

#### 3. Escalabilidade

- **Horizontal Scaling**: 
  - Adicionar instâncias de API conforme demanda (HPA baseado em CPU/memória)
  - Target: 70% CPU utilization
  - Min replicas: 3 (high availability)
  - Max replicas: 50 (ou conforme budget)
  
- **Vertical Scaling**: 
  - Otimizar uso de CPU/memória por requisição
  - Vectorização de operações (numpy)
  - Evitar cópias desnecessárias de arrays

- **Caching Strategy**:
  - LRU cache em memória para modelos mais acessados
  - Cache hit target: > 70%
  - TTL configurável (default: sem expiração, apenas eviction por LRU)
  - Warm-up: pré-carregar top 100 modelos mais usados ao iniciar pod

- **Storage Scaling**:
  - PostgreSQL com read replicas para queries de metadados
  - Object storage (S3/GCS) para model artifacts
  - Redis para cache distribuído (opcional, para clusters grandes)

#### 4. Consistência

- **Leitura**: 
  - Eventual consistency aceitável para modelos (cache de até 5 min)
  - Cache invalidation ao treinar nova versão
  
- **Escrita**: 
  - Strong consistency para versionamento de modelos
  - Transações atômicas (ACID) para criação de nova versão
  - Idempotência: retreinar mesmo model_id múltiplas vezes cria apenas uma versão

- **Concorrência**:
  - Otimistic locking para prevenir race conditions
  - Se dois treinos simultâneos: um sucede, outro retorna versão existente
  - Serializable isolation level para operações críticas

#### 5. Durabilidade

- **Código**: 
  - Versionamento via Git com tags semânticas
  - CI/CD pipeline automatizado (GitHub Actions / GitLab CI)
  - Testes automatizados (unit, integration, e2e)
  
- **Modelos**: 
  - Persistência em storage durável com replicação
  - S3 standard com versioning habilitado
  - Ou: PostgreSQL com backups automáticos diários
  
- **Backup**: 
  - Replicação cross-region ou multi-AZ
  - Backup incremental a cada 6 horas
  - Backup completo diário com retention de 30 dias
  
- **Disaster Recovery**:
  - Recovery Point Objective (RPO): < 1 hora
  - Recovery Time Objective (RTO): < 15 minutos
  - Runbooks documentados para cenários comuns de falha

#### 6. Usabilidade

- Interface responsiva para visualização de dados de treinamento
- Documentação OpenAPI/Swagger disponível em `/docs`
- Logs estruturados (JSON) para debugging eficiente
- Mensagens de erro claras e acionáveis com códigos de erro consistentes
- **Error codes**:
  - `MODEL_NOT_FOUND`: series_id não tem modelo treinado
  - `INVALID_VERSION`: versão solicitada não existe
  - `INSUFFICIENT_DATA`: dados de treino insuficientes
  - `CONSTANT_SERIES`: série temporal constante
  - `INVALID_TIMESTAMP`: timestamp fora de ordem ou formato inválido

#### 7. Observabilidade

- **Métricas de Sistema** (expostas via Prometheus `/metrics`):
  - Request rate, error rate, duration (RED metrics)
  - Latência por endpoint (P50, P95, P99)
  - Taxa de cache hit/miss para modelos
  - Número de modelos em memória vs total no registry
  - Uso de CPU, memória, disco por pod
  - Tempo de warm-up após deploy
  - Request queue depth (se usando workers)

- **Métricas de ML**:
  - Taxa de anomalias detectadas por series_id (agregada por hora/dia)
  - Distribuição de Z-scores (histograma)
  - Drift detection: KL-divergence entre distribuição de treino e inferência
  - Número de retreinamentos por período
  - Latência de carregamento de modelo por versão
  - Taxa de erro por versão de modelo
  - Agreement rate entre versões (em shadow/canary deployments)
  - **Métricas de Canary**:
    - Precision, recall, F1-score por versão (quando ground truth disponível)
    - False positive rate comparativo entre versões
    - Distribuição de tráfego atual (% por versão)
    - Taxa de rollback automático
    - Tempo médio até promoção completa

- **Logs**:
  - Estruturados (JSON) com campos padronizados
  - Trace ID (UUID) para rastreamento end-to-end de requisições
  - Correlation ID para rastrear retreinamentos e deploys
  - Span ID para distributed tracing (OpenTelemetry)
  - Nível configurável via env var (DEBUG, INFO, WARN, ERROR)
  - Sampling configurável para reduzir volume em produção (ex: 1% de DEBUG logs)
  - Centralização em Loki/CloudWatch/Datadog

- **Alertas** (configurados em Alertmanager/PagerDuty):
  - **Critical**:
    - Disponibilidade < 99.9% em janela de 5min
    - Error rate > 5% em janela de 1min
    - P99 latência > 100ms em janela de 5min
  - **Warning**:
    - Latência P99 > 50ms em janela de 5min
    - Error rate > 1% em janela de 5min
    - Cache miss rate > 30% em janela de 15min
    - Taxa de anomalias > 20% para algum series_id (possível drift)
  - **Info**:
    - Modelos falhando consistentemente (>5% erro em 5min)
    - Memória do pod > 80% do limite
    - Novo deploy completado com sucesso

- **Tracing**:
  - OpenTelemetry para distributed tracing
  - Spans para: HTTP request, DB query, model load, inference, training
  - Baggage propagation para contexto cross-service

#### 8. Segurança

- **Input Validation**:
  - Sanitização de series_id (permitir apenas alphanumeric + underscore)
  - Validação de entrada para prevenir injection attacks
  - Limites de tamanho de payload (max 10MB por request)

- **Rate Limiting**:
  - Por series_id: 1 treino/5min, 1000 predições/min
  - Global por IP: 100 treinos/hora, 10000 predições/min
  - Usar algoritmo token bucket ou sliding window

- **Autenticação & Autorização** (opcional no MVP):
  - API key via header `X-API-Key`
  - Ou: JWT com claims para permissões (read/write)
  - RBAC: roles de viewer, trainer, admin

- **Auditoria**:
  - Logs de auditoria para todas as operações de treino/retreinamento
  - Quem (user/service), quando (timestamp), o quê (series_id, version)
  - Retenção de logs de auditoria: 1 ano

- **Network Security**:
  - HTTPS obrigatório (TLS 1.2+)
  - Network policies no Kubernetes para isolar pods
  - Secrets management via Kubernetes Secrets ou Vault

---

## Assunções

#### Sobre os Dados
- Um sensor envia amostras a cada 5 minutos
- Cada ponto possui 3 canais: radial, horizontal e vertical
- Ciclo de amostras de cada canal possui em média 15.360 pontos
- Cada amostra é processada por 30 modelos independentes (por quê? diferentes frequências, diferentes features?)

#### Sobre o Modelo
- Modelo baseline (fallback): Z-score simples com threshold de 3σ
- Modelos em produção: podem ser mais complexos (Isolation Forest, LSTM, etc.)
- Modelo é stateless: não usa histórico de predições anteriores
- Retreinamento pode usar dados dos últimos N dias (janela deslizante)

#### Sobre a Infraestrutura
- Kubernetes cluster já provisionado e operacional
- GitOps configurado (ArgoCD, Github)
- Gerenciamento dos experimentos e model registry (Mlflow, Github)
- Monitoring stack disponível (Prometheus, Grafana)
- Storage backend disponível (S3 ou PostgreSQL)

> **Nota sobre Ambientes vs Deployment Strategies:**
> - **Ambientes** = onde o código roda (dev/stg/prod)
> - **Deployment Strategies** = como você libera código/modelos
> - Rolling Update para API, Shadow para modelos ML
> - Staging valida antes de production

---

## Restrições

#### Técnicas

- **Linguagem**: Python 3.12+
- **Framework web**: FastAPI (async/await para concorrência)
- **Containerização**: Docker com multi-stage builds
- **Orquestração**: Kubernetes
- **Serialização**: Pickle para modelos simples, ou joblib para performance

#### De Negócio

- **Budget**: limitado, preferir soluções open-source
- **Time to market**: MVP funcional em 5 dias.
- **Manutenibilidade**: código simples e bem documentado (equipe pequena)
- **Vendor lock-in**: evitar dependências de cloud providers específicos quando possível

#### Operacionais

- **Deploy**: cloud pública (AWS, GCP, ou Azure)
- **GitOps**: usar ArgoCD ou Flux para gerenciar cluster Kubernetes
- **CI/CD**: pipeline automatizado com testes obrigatórios

- **Ambientes (Infraestrutura)**:
  - **Development (dev)**: Minikube local para desenvolvimento
  - **Staging (stg)**: Namespace dedicado no cluster K8s (pode ser mesmo cluster que prod para economia)
  - **Production (prd)**: Namespace `production` no cluster K8s com dados reais

- **Load Balancing**: 
  - Ingress controller (NGINX ou Traefik)
  - Service mesh (Istio ou Linkerd) para traffic management avançado

- **Deployment Strategies** (dentro de cada ambiente):
  - **Rolling Update**: estratégia padrão do Kubernetes para releases de API/código
  - **Shadow Deployment**: para validação de novos modelos de ML
    - Rodar em paralelo sem afetar produção
    - Comparar agreement rate entre versões
    - Promover quando > 95%    

---

## Anexos

### A. Diagrama: Ambientes vs Deployment Strategies

```
┌────────────────────────────────────────────────────────┐
│                      INFRAESTRUTURA (Ambientes)        │
├────────────────────────────────────────────────────────┤
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │
│  │ Development  │  │   Staging    │  │  Production  │  │
│  │   (Local)    │  │  (Namespace  │  │  (Namespace  │  │
│  │  - Minikube  │  │  staging)    │  │  production) │  │
│  │  - Docker    │  │  - Validação │  │  - Dados     │  │
│  │    Compose   │  │    Pré-Prod  │  │    Reais     │  │
│  └──────────────┘  └──────────────┘  └──────────────┘  │
│                                             │          │
└─────────────────────────────────────────────┼──────────┘
                                              │
        ┌─────────────────────────────────────┴────┐
        │   DEPLOYMENT STRATEGIES                  │
        ├──────────────────────────────────────────┤
        │  1. Rolling Update (Padrão K8s)          │
        │     Pod v1 → Pod v2 (um de cada vez)     │
        │                                          │
        │  2. Canary Deployment                    │
        │     ┌─────────┬─────────┐                │
        │     │ v1: 95% │ v2: 5%  │ ← Validar      │
        │     │ v1: 50% │ v2: 50% │ ← Aumentar     │
        │     │ v1: 0%  │ v2: 100%│ ← Completo     │
        │     └─────────┴─────────┘                │
        │                                          │
        │  3. Shadow Deployment (ML Models)        │
        │     ┌──────────┬──────────┐              │
        │     │ Model v1 │ Model v2 │              │
        │     │ (produz) │(só mede) │              │
        │     └──────────┴──────────┘              │
        │     Compara agreement rate               │
        └──────────────────────────────────────────┘
```
