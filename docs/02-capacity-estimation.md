# Estimativas de Capacidade - MLOps Anomaly Detection System

Este documento calcula os recursos necessários para suportar o sistema MLOps de detecção de anomalias em séries temporais univariadas.

---

## Premissas Base

### Sensores e Dados

- **Sensores instalados:** 100.000 sensores
- **Frequência de coleta:** A cada 5 minutos (288 amostras/dia)
- **Eixos por amostra:** 3 (radial, horizontal, vertical)
- **Pontos médios por eixo:** 15.360 pontos ((4096+8192+16384+32768)/4)
- **Pontos totais por amostra:** 46.080 pontos (15.360 × 3 eixos)
- **Séries temporais únicas:** 300.000 (100k sensores × 3 eixos)

### Comportamento do Sistema

- **Taxa de retreinamento:** 1 vez por semana por série (média)
- **Predições por série:** 288 predições/dia (1 a cada 5 min)
- **Modos de predição:**
  - Single: 1 ponto (timestamp + value) - 80% das requests
  - Batch: 1 amostra com 15.360 pontos/eixo - 20% das requests
- **Versões mantidas por série:** 5 versões
- **Retention de modelos:** 90 dias

### Distribuição de Uso

- **Sensores ativos (coletando):** 95% (95.000 sensores)
- **Séries ativas:** 285.000 (95k × 3 eixos)
- **Modelos treinados:** 100% das séries ativas
- **Hit rate de cache:** 80% para metadados

---

## Tráfego e Throughput

### Treinamento de Modelos

**Treinamentos por semana:**
```
285.000 séries ativas × 1 treinamento/semana = 285.000 treinamentos/semana
```

**Treinamentos por dia (média):**
```
285.000 ÷ 7 dias = 40.714 treinamentos/dia
```

**Treinamentos por segundo (média):**
```
40.714 ÷ 86.400s ≈ 0,47 treinamentos/s
```

**Treinamentos por segundo (pico - 5x média, assumindo retreinos em batch):**
```
0,47 × 5 ≈ 2,35 treinamentos/s
```

### Inferência (Predições)

**Predições por dia:**
```
285.000 séries × 288 predições/dia = 82.080.000 predições/dia
```

**Distribuição Single vs Batch:**
```
Single (80%): 82.080.000 × 0,8 = 65.664.000 predições/dia
Batch (20%): 82.080.000 × 0,2 = 16.416.000 predições/dia
```

**Predições por segundo (média):**
```
Single: 65.664.000 ÷ 86.400s ≈ 760 predições/s
Batch: 16.416.000 ÷ 86.400s ≈ 190 predições/s
Total: 950 predições/s
```

**Predições por segundo (pico - 3x média):**
```
Single: 760 × 3 = 2.280 predições/s
Batch: 190 × 3 = 570 predições/s
Total: 2.850 predições/s
```

**Razão Inferência:Treinamento:**
```
950 ÷ 0,47 ≈ 2.021:1
```

### Healthcheck

**Requisições de healthcheck (assumindo monitoramento a cada 30s):**
```
86.400s/dia ÷ 30s = 2.880 requisições/dia
```

**Healthcheck por segundo (média):**
```
2.880 ÷ 86.400s ≈ 0,033 requisições/s
```

---

## Estimativas de Armazenamento

### Dados de Treinamento

**Tamanho médio dos dados de treinamento por série:**
```
Assumindo janela de 7 dias para treinamento (2.016 amostras):
- Cada amostra: 15.360 pontos × 8 bytes (float64) = 122.880 bytes
- 2.016 amostras × 122.880 bytes = 247.726.080 bytes ≈ 247,73MB por série
```

**Armazenamento de dados de treinamento (último snapshot por série):**
```
285.000 séries × 247,73MB = 70.603.050MB ≈ 70,6TB
```

**Com histórico de 4 snapshots (mensal):**
```
70,6TB × 4 = 282,4TB
```

**Alternativa: Janela deslizante de 24h (288 amostras):**
```
288 amostras × 122.880 bytes = 35.389.440 bytes ≈ 35,39MB por série
285.000 séries × 35,39MB = 10.086.150MB ≈ 10,09TB (snapshot atual)
Com 4 snapshots: 10,09TB × 4 = 40,36TB
```

### Modelos Treinados

**Tamanho médio por modelo (simples - mean + std):**
```
- Mean: 8 bytes (float64)
- Std: 8 bytes (float64)
- Series ID: 50 bytes (string)
- Version: 20 bytes (string)
- Metadata (timestamps, config): ~200 bytes
---
Total: ~286 bytes por modelo
```

**Modelos ativos (1 versão atual por série):**
```
285.000 séries × 286 bytes = 81.510.000 bytes ≈ 81,51MB
```

**Modelos com versionamento (5 versões por série):**
```
285.000 séries × 5 versões × 286 bytes = 407.550.000 bytes ≈ 407,55MB
```

**Com retention de 90 dias (assumindo 12-13 versões no período):**
```
285.000 séries × 13 versões × 286 bytes ≈ 1,06GB
```

### Metadados de Predições

**Dados por predição recebida:**
```
Single request:
- Timestamp: 8 bytes
- Value (1 ponto): 8 bytes
- Total: 16 bytes

Batch request:
- Timestamp: 8 bytes  
- Values (15.360 pontos): 15.360 × 8 bytes = 122.880 bytes
- Total: 122.888 bytes
```

**Metadados armazenados por predição (para métricas):**
```
- Series ID: 50 bytes
- Timestamp: 8 bytes
- Value: 8 bytes (agregado)
- Anomaly flag: 1 byte
- Model version: 20 bytes
- Latency: 8 bytes
- Request type: 1 byte (single/batch)
---
Total: ~96 bytes por predição
```

**Predições diárias totais:**
```
95.000 sensores × 288 amostras/dia × 3 eixos = 82.080.000 predições/dia
```

**Metadados diários (retenção de 7 dias para métricas):**
```
82.080.000 predições/dia × 96 bytes = 7.879.680.000 bytes ≈ 7,88GB/dia
```

**Armazenamento de metadados (7 dias):**
```
7,88GB/dia × 7 dias = 55,16GB
```

### Métricas de Performance

**Dados de latência agregados:**
```
- Training latency (P95, Avg): 285.000 séries × 2 métricas × 8 bytes = 4,56MB
- Inference latency (P95, Avg): 285.000 séries × 2 métricas × 8 bytes = 4,56MB
- Counter (series_trained): 8 bytes
---
Total: ~9,12MB
```

**Histórico de métricas (30 dias, granularidade de 1h):**
```
30 dias × 24 horas × 9,12MB ≈ 6,57GB
```

### Logs de Sistema

**Logs de treinamento:**
```
40.714 treinamentos/dia × 1KB/log = 40.714KB/dia ≈ 40,71MB/dia
```

**Logs de inferência (sampling de 1%):**
```
82.080.000 predições/dia × 1% × 500 bytes = 410.400.000 bytes ≈ 410,4MB/dia
```

**Logs totais por dia:**
```
40,71MB + 410,4MB = 451,11MB/dia
```

**Logs (retention de 30 dias):**
```
451,11MB/dia × 30 dias = 13.533,3MB ≈ 13,53GB
```

---

## Resumo de Armazenamento

| Tipo de Dado | Armazenamento (24h window) | Armazenamento (7d window) |
|--------------|----------------------------|---------------------------|
| Dados de Treinamento (snapshots) | ~40,36TB | ~282,4TB |
| Modelos Persistidos (90d retention) | ~1,06GB | ~1,06GB |
| Metadados de Predições (7d) | ~55,16GB | ~55,16GB |
| Métricas de Performance (30d) | ~6,57GB | ~6,57GB |
| Logs (30d) | ~13,53GB | ~13,53GB |
| **TOTAL (24h window)** | **~40,45TB** | - |
| **TOTAL (7d window)** | - | **~282,56TB** |

**Observação importante:** O tamanho do armazenamento depende criticamente da janela de treinamento escolhida:
- **Janela de 24h:** Mais prático para MLOps, retreinamento rápido, ~40TB
- **Janela de 7 dias:** Melhor captura de padrões, retreinamento mais lento, ~283TB

**Armazenamento anual estimado (24h window):**
```
40,45TB base + crescimento mensal
40,45TB × 12 meses × 1,05 (buffer) ≈ 509TB/ano
```

**Armazenamento anual estimado (7d window):**
```
282,56TB base + crescimento mensal
282,56TB × 12 meses × 1,05 (buffer) ≈ 3,56PB/ano
```

---

## Estimativas de Computação

### Treinamento

**Latência assumida por treinamento:**
```
Janela 24h (288 amostras × 15.360 pontos): ~5 segundos
Janela 7d (2.016 amostras × 15.360 pontos): ~35 segundos
```

**CPU-time diário (média) - Janela 24h:**
```
40.714 treinamentos/dia × 5s = 203.570s ≈ 56,55 horas de CPU/dia
```

**CPU-time diário (média) - Janela 7d:**
```
40.714 treinamentos/dia × 35s = 1.424.990s ≈ 395,83 horas de CPU/dia
```

**CPU-time por segundo (média) - Janela 24h:**
```
0,47 treinamentos/s × 5s = 2,35 CPU-cores utilizados
```

**CPU-time por segundo (média) - Janela 7d:**
```
0,47 treinamentos/s × 35s = 16,45 CPU-cores utilizados
```

**CPU-time por segundo (pico) - Janela 24h:**
```
2,35 treinamentos/s × 5s = 11,75 CPU-cores utilizados
```

**CPU-time por segundo (pico) - Janela 7d:**
```
2,35 treinamentos/s × 35s = 82,25 CPU-cores utilizados
```

**Servidores necessários (pico, com overhead 30%) - Janela 24h:**
```
11,75 cores × 1,3 = 15,28 cores ≈ 2 servidores (8 cores cada)
```

**Servidores necessários (pico, com overhead 30%) - Janela 7d:**
```
82,25 cores × 1,3 = 106,93 cores ≈ 14 servidores (8 cores cada)
```

### Inferência

**Latência assumida por predição:**
```
Single: 10ms (cálculo simples com 1 ponto)
Batch: 50ms (processamento de 15.360 pontos)
```

**CPU-time por segundo (média):**
```
Single: 760 predições/s × 0,01s = 7,6 CPU-cores
Batch: 190 predições/s × 0,05s = 9,5 CPU-cores
Total: 17,1 CPU-cores utilizados
```

**CPU-time por segundo (pico):**
```
Single: 2.280 predições/s × 0,01s = 22,8 CPU-cores
Batch: 570 predições/s × 0,05s = 28,5 CPU-cores
Total: 51,3 CPU-cores utilizados
```

**Servidores necessários (pico, com overhead 30%):**
```
51,3 cores × 1,3 = 66,69 cores ≈ 9 servidores (8 cores cada)
```

### Total de Servidores de Aplicação

**Média - Janela 24h:**
```
Training: 1 servidor + Inference: 3 servidores = 4 servidores
```

**Média - Janela 7d:**
```
Training: 2 servidores + Inference: 3 servidores = 5 servidores
```

**Pico (com redundância) - Janela 24h:**
```
Training: 2 servidores + Inference: 9 servidores = 11 servidores × 1,2 (HA) ≈ 14 servidores
```

**Pico (com redundância) - Janela 7d:**
```
Training: 14 servidores + Inference: 9 servidores = 23 servidores × 1,2 (HA) ≈ 28 servidores
```

---

## Memória (RAM)

### Cache de Modelos em Memória

**Modelos ativos (hot models - últimas 24h de uso):**
```
Assumindo 80% das séries ativas são consultadas diariamente:
285.000 × 80% = 228.000 modelos

228.000 modelos × 286 bytes ≈ 65,21MB
```

**Cache de metadados de série:**
```
228.000 séries × 500 bytes (series_id, config, stats) = 114MB
```

**Total cache quente:**
```
65,21MB + 114MB ≈ 180MB
```

### Buffers de Processamento

**Buffer de treinamento (batch processing):**
```
100 treinamentos simultâneos × 38KB/dados = 3,8MB
```

**Buffer de inferência:**
```
1.000 requisições simultâneas × 200 bytes = 200KB
```

**Total buffers:**
```
3,8MB + 0,2MB = 4MB
```

### Métricas em Memória (Time-Series DB)

**Últimas 24h de métricas:**
```
9,12MB/snapshot × 24 snapshots/dia = 218,88MB
```

### Memória Total por Servidor

- **Aplicação (base):** 2GB
- **Cache de modelos:** 180MB
- **Buffers:** 4MB
- **Métricas:** 220MB
- **OS + Overhead:** 1GB
- **Total por servidor:** ~3,5GB
- **Recomendado:** 8GB RAM por servidor

---

## Banco de Dados

### Armazenamento de Metadados

**Tabela: series**
```
285.000 séries × 500 bytes = 142,5MB
```

**Tabela: models**
```
285.000 séries × 13 versões × 286 bytes ≈ 1,06GB
```

**Tabela: training_data (24h window):**
```
285.000 séries × 35,39MB = 10,09TB
```

**Tabela: training_data (7d window):**
```
285.000 séries × 247,73MB = 70,6TB
```

**Tabela: predictions (7 dias):**
```
54,6GB
```

**Tabela: metrics (30 dias):**
```
6,57GB
```

**Total (24h window):** ~10,15TB

**Total (7d window):** ~70,66TB

**Com índices (30% overhead):**
- **24h window:** ~13,2TB
- **7d window:** ~91,86TB

### Throughput de Banco de Dados

**Writes por segundo (média):**
```
Training: 0,47 writes/s
Predictions: 950 writes/s
Metrics updates: ~1 write/s
---
Total: ~951 writes/s
```

**Reads por segundo (média):**
```
Model fetch: 950 reads/s
Healthcheck: 0,033 reads/s
Metrics queries: ~10 reads/s
---
Total: ~960 reads/s
```

**Razão Read:Write:** ~1:1

---

## Rede (Bandwidth)

### API Requests

**Tamanho médio request/response:**
```
Training request: 
- Janela 24h: 288 amostras × 122.880 bytes = 35,39MB
- Janela 7d: 2.016 amostras × 122.880 bytes = 247,73MB

Training response: 500 bytes

Prediction Single request: 
- Timestamp: 8 bytes
- Value: 8 bytes
- Total: 16 bytes

Prediction Batch request:
- Timestamp: 8 bytes
- Values: 15.360 × 8 bytes = 122.880 bytes
- Total: 122.888 bytes

Prediction response: 150 bytes

Healthcheck: 200 bytes
```

**Bandwidth de entrada (média) - Janela 24h:**
```
Training: 0,47 req/s × 35,39MB = 16,63MB/s
Prediction Single: 760 req/s × 16 bytes = 12.160 bytes/s = 11,88KB/s
Prediction Batch: 190 req/s × 122.888 bytes = 23.348.720 bytes/s = 22,77MB/s
Healthcheck: 0,033 req/s × 200 bytes = 6,6 bytes/s
---
Total: 39,41MB/s ≈ 315,28Mbits/s
```

**Bandwidth de entrada (média) - Janela 7d:**
```
Training: 0,47 req/s × 247,73MB = 116,43MB/s
Prediction Single: 760 req/s × 16 bytes = 12.160 bytes/s = 11,88KB/s
Prediction Batch: 190 req/s × 122.888 bytes = 23.348.720 bytes/s = 22,77MB/s
Healthcheck: 0,033 req/s × 200 bytes = 6,6 bytes/s
---
Total: 139,21MB/s ≈ 1,11Gbits/s
```

**Bandwidth de saída (média):**
```
Training: 0,47 req/s × 500 bytes = 235 bytes/s
Prediction Single: 760 req/s × 150 bytes = 114.000 bytes/s = 111,33KB/s
Prediction Batch: 190 req/s × 150 bytes = 28.500 bytes/s = 27,83KB/s
Healthcheck: 0,033 req/s × 200 bytes = 6,6 bytes/s
---
Total: 139,16KB/s ≈ 0,14MB/s ≈ 1,12Mbits/s
```

**Bandwidth pico (3x média) - Janela 24h:**
```
Entrada: 315,28Mbits/s × 3 = 945,84Mbits/s
Saída: 1,12Mbits/s × 3 = 3,36Mbits/s
```

**Bandwidth pico (3x média) - Janela 7d:**
```
Entrada: 1,11Gbits/s × 3 = 3,33Gbits/s
Saída: 1,12Mbits/s × 3 = 3,36Mbits/s
```

---

## Resumo de Recursos

### Janela de Treinamento 24h

| Recurso | Média | Pico |
|---------|-------|------|
| **Armazenamento Total** | ~40,45TB | - |
| **Armazenamento Anual** | ~509TB/ano | - |
| **Bandwidth Entrada** | ~315,28Mbits/s | ~946Mbits/s |
| **Bandwidth Saída** | ~1,12Mbits/s | ~3,36Mbits/s |
| **RAM por Servidor** | ~3,5GB | - |
| **Servidores de Aplicação** | 4 servidores | 14 servidores |
| **Database Storage** | ~120GB | - |
| **RPS - Treinamento** | ~0,47/s | ~2,35/s |
| **RPS - Inferência Single** | ~760/s | ~2.280/s |
| **RPS - Inferência Batch** | ~190/s | ~570/s |
| **RPS - Healthcheck** | ~0,033/s | - |
| **RPS Total** | ~951/s | ~2.853/s |
| **Training Latency Target** | <10s | - |
| **Inference Single Latency** | <50ms | - |
| **Inference Batch Latency** | <200ms | - |

### Janela de Treinamento 7d

| Recurso | Média | Pico |
|---------|-------|------|
| **Armazenamento Total** | ~282,56TB | - |
| **Armazenamento Anual** | ~3,56PB/ano | - |
| **Bandwidth Entrada** | ~1,11Gbits/s | ~3,33Gbits/s |
| **Bandwidth Saída** | ~1,12Mbits/s | ~3,36Mbits/s |
| **RAM por Servidor** | ~3,5GB | - |
| **Servidores de Aplicação** | 5 servidores | 28 servidores |
| **Database Storage** | ~350GB | - |
| **RPS - Treinamento** | ~0,47/s | ~2,35/s |
| **RPS - Inferência Single** | ~760/s | ~2.280/s |
| **RPS - Inferência Batch** | ~190/s | ~570/s |
| **RPS - Healthcheck** | ~0,033/s | - |
| **RPS Total** | ~951/s | ~2.853/s |
| **Training Latency Target** | <60s | - |
| **Inference Single Latency** | <50ms | - |
| **Inference Batch Latency** | <200ms | - |

**Recomendação:** Janela de 24h oferece melhor custo-benefício (40TB vs 283TB) com retreinamento mais rápido e armazenamento significativamente menor.

---

## Arquitetura de Deployment Recomendada

### Configuração Mínima (MVP)

**Application Layer:**
- 2 servidores API (8 cores, 8GB RAM cada)
- Load balancer (HAProxy ou NGINX)

**Database:**
- PostgreSQL (1 instância principal + 1 réplica)
- 100GB SSD storage
- 16GB RAM

**Cache:**
- Redis (1 instância)
- 2GB RAM
- Cache de modelos + métricas recentes

**Armazenamento de Modelos:**
- S3-compatible object storage (MinIO)
- 10GB para modelos

**Monitoring:**
- Prometheus + Grafana
- 4GB RAM, 50GB storage

**Total estimado:** ~6 VMs

### Configuração Produção (Escalável)

**Application Layer:**
- 6 servidores API (8 cores, 16GB RAM cada)
- Auto-scaling group
- Load balancer (ALB/NLB)

**Database:**
- PostgreSQL cluster (1 principal + 2 réplicas de leitura)
- RDS ou managed PostgreSQL
- 200GB SSD storage, 32GB RAM

**Cache:**
- Redis cluster (3 nós)
- 4GB RAM cada

**Model Storage:**
- S3 ou equivalente
- Lifecycle policies para arquivamento

**Message Queue (para processamento assíncrono):**
- RabbitMQ ou SQS
- 2GB RAM

**Monitoring Stack:**
- Prometheus + Grafana + AlertManager
- 8GB RAM, 100GB storage

**Total estimado:** ~15-20 instâncias