# High-Level Design - Sistema MLOps de Detecção de Anomalias

Este documento descreve a arquitetura de alto nível do sistema MLOps para detecção de anomalias em dados de sensores industriais, detalhando componentes, fluxos de dados, estratégias de resiliência e operações em produção.

---

## Visão Geral da Arquitetura

O sistema é projetado para processar **285.000 séries temporais simultâneas** (95.000 sensores × 3 eixos), cada uma representando um sensor industrial monitorando equipamentos críticos. A arquitetura é construída sobre três pilares fundamentais:

1. **Separação de Responsabilidades**: Treinamento (assíncrono) e Inferência (síncrono) operam independentemente
2. **Resiliência Multi-Camadas**: Fallbacks em todos os níveis críticos (MLflow → Cache → Z-score)
3. **Observabilidade Profunda**: Métricas, logs e tracing em todos os componentes

### Decisões Arquiteturais Críticas

**Por que separar Training e Inference?**
- Inferência nunca depende da disponibilidade do sistema de treinamento
- Permite escalar cada workload independentemente (treino = compute-intensive, inferência = latency-sensitive)
- Falhas de treinamento não afetam predições em produção

**Por que KServe?**
- Autoscaling nativo baseado em métricas de ML (RPS, concurrency)
- Suporte a canary deployments e traffic splitting
- Integração transparente com Istio para observabilidade

**Por que MLflow como Model Registry?**
- Fonte única de verdade para versionamento de modelos
- APIs padronizadas para registro, promoção e servir modelos
- Integração com S3 para armazenamento de artifacts

---

## Arquitetura de Componentes

```
┌─────────────────────────────────────────────────────────────────┐
│                    Istio Ingress Gateway                        │
│         (mTLS, Rate Limiting, JWT Validation, Routing)          │
└─────────────┬───────────────────────────────┬───────────────────┘
              │                               │
    ┌─────────▼──────────┐           ┌────────▼─────────┐
    │  Training API      │           │  Inference API   │
    │  (FastAPI)         │           │  (KServe)        │
    │                    │           │                  │
    │  POST /training    │           │  POST /predict   │
    │  GET /jobs         │           │  POST /predict/  │
    │  GET /models       │           │       batch      │
    │  POST /promote     │           │  GET /health     │
    │  GET /plot         │           │                  │
    └─────────┬──────────┘           └────────┬─────────┘
              │                               │
              │     ┌─────────────────┐       │
              │     │  Airflow        │       │
              │     │  (Orchestrator) │       │
              │     │                 │       │
              │     │  - Weekly       │       │
              │     │  - Drift detect │       │
              │     │  - Shadow→Canary│       │
              │     └────────┬────────┘       │
              │              │                │
              └──────┬───────┘                │
                     │                        │
    ┌────────────────▼──────────┐             │
    │  RabbitMQ Queue           │             │
    │  (Training Jobs)          │             │
    └────────────┬──────────────┘             │
                 │                            │
    ┌────────────▼──────────┐      ┌──────────▼─────────┐
    │  Training Workers     │      │  Predictor Pods    │
    │  (Celery/Custom)      │      │  (HPA: 3-50)       │
    │                       │      │                    │
    │  - Load job           │      │  - Warm Loading    │
    │  - Validate data      │      │  - LRU Cache       │
    │  - Train model        │      │  - Fallback        │
    │  - Save to MLflow     │      │                    │
    └────────────┬──────────┘      └──────────┬─────────┘
                 │                            │
                 │         ┌──────────────────┘
                 │         │
    ┌────────────▼─────────▼──────────────────────────┐
    │           MLflow Tracking Server                │
    │  (Model Registry + Experiment Tracking)         │
    │                                                 │
    │  - Register models & versions                   │
    │  - Track metrics & parameters                   │
    │  - Manage model stages (None/Staging/Production)│
    │  - Serve model URIs                             │
    └─────────┬──────────────┬────────────────────────┘
              │              │
    ┌─────────▼──────┐  ┌────▼─────────────────┐
    │  PostgreSQL    │  │  MinIO/S3            │
    │  (Metadata)    │  │  (Model Artifacts)   │
    │                │  │                      │
    │  - Runs        │  │  - Serialized models │
    │  - Params      │  │  - Training data     │
    │  - Metrics     │  │  - Plots/visualiza-  │
    │  - Model       │  │    tions             │
    │    Registry    │  │                      │
    └────────────────┘  └──────────────────────┘
```

---

## Componentes Detalhados

### 1. Istio Service Mesh

**Responsabilidades:**
- **Roteamento inteligente**: Direcionar tráfego baseado em headers, paths, pesos
- **mTLS automático**: Criptografia transparente entre serviços
- **Observabilidade**: Métricas L7, distributed tracing, logs de acesso
- **Resiliência**: Circuit breaking, retries, timeouts
- **Segurança**: JWT validation, RBAC, rate limiting

**Configuração para Canary Deployment:**

```yaml
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: anomaly-detector-predictor
spec:
  hosts:
  - anomaly-detector-predictor.ml-production.svc.cluster.local
  http:
  - match:
    - headers:
        series_id:
          exact: "sensor_001_radial"
    route:
    - destination:
        host: anomaly-detector-predictor
        subset: v23-canary
      weight: 20
    - destination:
        host: anomaly-detector-predictor
        subset: v22-production
      weight: 80
```

**Por que Istio?**
- Evita instrumentar código com lógica de roteamento/observabilidade
- Permite mudanças de configuração sem redeploy de aplicação
- Fornece métricas consistentes em todos os serviços

---

### 2. Training API (FastAPI)

**Responsabilidades:**
- Validar requests de treinamento
- Enfileirar jobs no RabbitMQ com prioridade
- Consultar status de jobs
- Gerenciar versionamento e promoção de modelos
- Servir visualizações de dados de treinamento

**Endpoints Principais:**
```
POST   /api/v1/training/{series_id}                             # Iniciar treinamento
GET    /api/v1/training/jobs/{job_id}                           # Status do job
GET    /api/v1/training/jobs                                    # Listar jobs
DELETE /api/v1/training/jobs/{job_id}                           # Cancelar job
POST   /api/v1/models/{series_id}/versions/{version}/promote    # Promover modelo
GET    /api/v1/models/{series_id}/deployment-config             # Config de deployment
GET    /api/v1/plot                                             # Visualização de dados
```

**Fluxo de Treinamento:**

```
1. Cliente envia POST /training/sensor_001_radial
2. FastAPI valida payload (timestamps crescentes, valores finitos, etc)
3. FastAPI cria job no PostgreSQL com status "queued"
4. FastAPI publica mensagem no RabbitMQ
5. FastAPI retorna 202 Accepted com job_id
6. Cliente pode fazer GET /training/jobs/{job_id} para polling
```

**Validações Implementadas:**
- Mínimo 10.000 pontos, máximo 100.000
- Timestamps em ordem crescente, sem duplicatas
- Valores finitos (não NaN/Inf)
- Desvio padrão > 1e-6 (rejeitar séries constantes)
- Rate limiting: 1 treino/5min por series_id

---

### 3. Airflow (Orchestrator)

**Responsabilidades:**
- Orquestrar retreinamento periódico semanal de todas as séries
- Detectar drift e triggar retreinamentos urgentes
- Gerenciar pipeline shadow → canary → production
- Coordenar análises batch e relatórios

**DAGs Principais:**

**1. Weekly Retraining DAG**
```python
from airflow import DAG
from airflow.operators.python import PythonOperator
from datetime import datetime, timedelta

dag = DAG(
    'weekly_model_retraining',
    schedule_interval='0 2 * * 0',  # Domingo 2am
    start_date=datetime(2024, 1, 1),
    catchup=False
)

def get_active_series():
    """Busca séries ativas do catálogo."""
    # Query database ou MLflow para séries com modelos production
    return ['sensor_001_radial', 'sensor_002_axial', ...]

def submit_training_job(series_id):
    """Envia job de treinamento via Training API."""
    response = requests.post(
        f"{TRAINING_API}/api/v1/training/{series_id}",
        json={
            "config": {
                "window_hours": 168,  # 7 dias
                "algorithm": "statistical"
            }
        },
        headers={"Authorization": f"Bearer {API_TOKEN}"}
    )
    return response.json()['job_id']

# Tarefa para cada série
for series_id in get_active_series():
    train_task = PythonOperator(
        task_id=f'train_{series_id}',
        python_callable=submit_training_job,
        op_kwargs={'series_id': series_id},
        dag=dag
    )
```

**2. Drift Detection DAG**
```python
dag = DAG(
    'drift_detection',
    schedule_interval='0 */6 * * *',  # A cada 6h
    start_date=datetime(2024, 1, 1)
)

def check_drift_for_series(series_id):
    """Verifica data drift e concept drift."""
    # Busca métricas via Training API
    metrics = requests.get(
        f"{TRAINING_API}/api/v1/models/{series_id}/metrics",
        params={"window": "24h"}
    ).json()
    
    # Detecta drift
    if metrics['drift_detection']['data_drift_detected']:
        # Trigga retreinamento urgente
        submit_training_job(series_id)
        send_alert(f"Data drift detected for {series_id}")
    
    if metrics['drift_detection']['concept_drift_detected']:
        send_alert(f"Concept drift detected for {series_id}")
```

**3. Shadow Deployment DAG**
```python
dag = DAG(
    'shadow_deployment_pipeline',
    schedule_interval=None,  # Trigger manual ou via webhook
    start_date=datetime(2024, 1, 1)
)

def deploy_shadow_cluster(series_id, model_version):
    """Deploy cluster shadow com champion e challenger."""
    # Via Kubernetes API ou Helm
    subprocess.run([
        'kubectl', 'apply', '-f', 
        f'shadow-deployment-{series_id}-v{model_version}.yaml'
    ])

def configure_traffic_mirroring(series_id):
    """Configura Istio para duplicar tráfego."""
    # Atualiza VirtualService
    ...

def analyze_shadow_metrics(series_id, model_version):
    """Analisa métricas após 48h de shadow."""
    # Query Prometheus
    metrics = query_prometheus(...)
    
    if metrics['challenger_better_than_champion']:
        # Aprova para canary
        requests.post(
            f"{TRAINING_API}/api/v1/models/{series_id}/versions/{model_version}/promote",
            json={"strategy": "canary", "canary_config": {...}}
        )
    else:
        # Rejeita
        send_alert(f"Model v{model_version} failed shadow validation")

deploy = PythonOperator(task_id='deploy_shadow', ...)
configure = PythonOperator(task_id='configure_mirroring', ...)
wait = TimeDeltaSensor(task_id='wait_48h', delta=timedelta(hours=48))
analyze = PythonOperator(task_id='analyze_metrics', ...)

deploy >> configure >> wait >> analyze
```

**Benefícios do Airflow:**
- Visualização de pipelines e status no UI
- Retry automático com backoff exponencial
- Paralelização de tarefas (treinar múltiplas séries simultaneamente)
- Alerting integrado via email/Slack
- Histórico completo de execuções

---

### 4. Training Workers

**Responsabilidades:**
- Consumir jobs da fila RabbitMQ
- Executar algoritmo de treinamento (Z-score, Isolation Forest, etc)
- Registrar modelo e métricas no MLflow
- Atualizar status do job no PostgreSQL

**Implementação:**

```python
class TrainingWorker:
    def __init__(self):
        self.mlflow_client = MlflowClient(tracking_uri=MLFLOW_URI)
        self.queue = RabbitMQConsumer(queue_name="training_jobs")
    
    def process_job(self, job_data: dict):
        """
        Processa um job de treinamento.
        """
        series_id = job_data['series_id']
        job_id = job_data['job_id']
        training_data = job_data['training_data']
        
        # Atualiza status para "processing"
        self.update_job_status(job_id, "processing")
        
        try:
            # Treina modelo
            model = self.train_model(
                timestamps=training_data['timestamps'],
                values=training_data['values'],
                hyperparameters=job_data['config']['hyperparameters']
            )
            
            # Registra no MLflow
            with mlflow.start_run():
                mlflow.log_params(job_data['config'])
                mlflow.log_metrics({
                    'mean': model.mean_,
                    'std': model.std_,
                    'training_points': len(training_data['values'])
                })
                
                # Serializa modelo
                mlflow.sklearn.log_model(
                    sk_model=model,
                    artifact_path="model",
                    registered_model_name=f"anomaly-detector-{series_id}"
                )
                
                run_id = mlflow.active_run().info.run_id
            
            # Obtém versão do modelo registrado
            model_version = self.get_latest_version(series_id)
            
            # Transiciona para Staging automaticamente
            self.mlflow_client.transition_model_version_stage(
                name=f"anomaly-detector-{series_id}",
                version=model_version,
                stage="Staging"
            )
            
            # Atualiza job como completo
            self.update_job_status(job_id, "completed", {
                'model_version': model_version,
                'mlflow_run_id': run_id
            })
            
        except Exception as e:
            logger.error(f"Training failed for job {job_id}: {e}")
            self.update_job_status(job_id, "failed", {'error': str(e)})
    
    def train_model(self, timestamps, values, hyperparameters):
        """
        Treina modelo de detecção de anomalias.
        """
        # Para modelo estatístico simples
        mean = np.mean(values)
        std = np.std(values)
        threshold = hyperparameters.get('threshold_sigma', 3.0)
        
        model = ZScoreAnomalyDetector(
            mean=mean,
            std=std,
            threshold=threshold
        )
        
        return model
```

**Escalabilidade:**
- Workers stateless, podem escalar horizontalmente
- Cada worker consome da mesma fila (competing consumers)
- Número de workers ajustado baseado em queue depth

---

### 4. MLflow Tracking Server

**Arquitetura:**

```
MLflow Tracking Server
├── Backend Store (PostgreSQL)
│   ├── Experiments
│   ├── Runs
│   ├── Params
│   ├── Metrics
│   └── Model Registry
│       ├── Registered Models
│       ├── Model Versions
│       └── Model Version Tags
└── Artifact Store (MinIO/S3)
    ├── models:/anomaly-detector-sensor_001_radial/1/
    ├── models:/anomaly-detector-sensor_001_radial/2/
    └── ...
```

**Model Registry - Ciclo de Vida:**

```
None (just registered)
  ↓
  → transition_model_version_stage(..., stage="Staging")
  ↓
Staging (validação)
  ↓
  → POST /api/v1/models/{series_id}/versions/{version}/promote
  ↓
Production (serving)
  ↓
  → Quando nova versão promovida, antiga vai para:
  ↓
Archived
```

**Consultas Comuns:**

```python
# Obter versão em produção
production_models = client.get_latest_versions(
    name=f"anomaly-detector-{series_id}",
    stages=["Production"]
)

# Listar todas as versões
all_versions = client.search_model_versions(
    filter_string=f"name='anomaly-detector-{series_id}'"
)

# Carregar modelo para inferência
model_uri = f"models:/anomaly-detector-{series_id}/Production"
model = mlflow.pyfunc.load_model(model_uri)
```

**Caching de Artifacts:**
- MLflow mantém cache local em `~/.mlflow/cache`
- Downloads de S3 apenas no primeiro load
- Em ambiente distribuído, cada pod tem seu próprio cache

---

### 5. KServe InferenceService

**Deployment Manifest:**

```yaml
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: anomaly-detector-predictor
  namespace: ml-production
spec:
  predictor:
    minReplicas: 3
    maxReplicas: 50
    
    # Autoscaling baseado em concurrency
    scaleTarget: 80  # 80 requisições concorrentes por pod
    scaleMetric: concurrency
    
    # Configuração de recursos
    resources:
      requests:
        cpu: "500m"
        memory: "1Gi"
      limits:
        cpu: "2000m"
        memory: "4Gi"
    
    # Container customizado
    containers:
    - name: kserve-container
      image: ghcr.io/company/anomaly-predictor:v2.1.0
      env:
      - name: MLFLOW_TRACKING_URI
        value: "http://mlflow-server.ml-infra.svc.cluster.local:5000"
      - name: CACHE_SIZE
        value: "100"  # LRU cache para top 100 modelos
      - name: FALLBACK_ENABLED
        value: "true"
      
      # Health checks
      livenessProbe:
        httpGet:
          path: /api/v1/liveness
          port: 8080
        initialDelaySeconds: 30
        periodSeconds: 10
      
      readinessProbe:
        httpGet:
          path: /api/v1/readiness
          port: 8080
        initialDelaySeconds: 10
        periodSeconds: 5
```

**Predictor Container - Implementação:**

```python
class AnomalyPredictor:
    def __init__(self):
        self.mlflow_client = MlflowClient(tracking_uri=MLFLOW_URI)
        self.model_cache = LRUCache(maxsize=100)
        self.fallback_models = {}  # Z-score models computados on-the-fly
        
        # Warm loading: pré-carregar top modelos
        self.warm_load_models()
    
    def warm_load_models(self):
        """
        Pré-carrega os modelos mais acessados na inicialização.
        """
        # Busca top 100 séries mais consultadas nas últimas 24h
        top_series = self.get_top_series_by_traffic(limit=100)
        
        for series_id in top_series:
            try:
                self.load_model(series_id, stage="Production")
                logger.info(f"Warm loaded model for {series_id}")
            except Exception as e:
                logger.warning(f"Failed to warm load {series_id}: {e}")
    
    def predict(self, series_id: str, timestamp: int, value: float) -> dict:
        """
        Predição single-point.
        """
        try:
            # Tenta carregar do cache
            model, source = self.get_model(series_id, stage="Production")
            
            # Predição
            is_anomaly = model.predict(value)
            anomaly_score = model.score(value)
            
            return {
                'anomaly': bool(is_anomaly),
                'anomaly_score': float(anomaly_score),
                'model_info': {
                    'version': model.version,
                    'stage': 'production',
                    'type': 'mlflow_trained' if source == 'mlflow' else 'cached_mlflow',
                    'loaded_from': source
                },
                'confidence': 'high' if source == 'mlflow' else 'medium'
            }
            
        except ModelNotFoundError:
            # Fallback para Z-score
            logger.warning(f"No trained model for {series_id}, using fallback")
            return self.predict_with_fallback(series_id, value)
    
    def get_model(self, series_id: str, stage: str = "Production"):
        """
        Obtém modelo com estratégia de caching multi-camada.
        """
        cache_key = f"{series_id}:{stage}"
        
        # L1: Cache em memória
        if cache_key in self.model_cache:
            logger.debug(f"Cache hit for {series_id}")
            return self.model_cache[cache_key], "cache"
        
        # L2: Carregar do MLflow
        logger.debug(f"Cache miss for {series_id}, loading from MLflow")
        try:
            model_uri = f"models:/anomaly-detector-{series_id}/{stage}"
            model = mlflow.pyfunc.load_model(model_uri)
            
            # Adiciona ao cache
            self.model_cache[cache_key] = model
            
            return model, "mlflow"
            
        except Exception as e:
            logger.error(f"Failed to load model from MLflow: {e}")
            raise ModelNotFoundError(f"No model found for {series_id}")
    
    def predict_with_fallback(self, series_id: str, value: float) -> dict:
        """
        Predição usando modelo Z-score de fallback.
        """
        # Busca estatísticas históricas (poderia vir de cache Redis)
        stats = self.get_historical_stats(series_id)
        
        if stats:
            mean, std = stats['mean'], stats['std']
        else:
            # Sem dados históricos, usa limites conservadores
            mean, std = 0.0, 1.0
        
        z_score = abs((value - mean) / std) if std > 0 else 0
        is_anomaly = z_score > 3.0
        
        return {
            'anomaly': bool(is_anomaly),
            'anomaly_score': float(z_score),
            'model_info': {
                'version': 'fallback',
                'stage': 'fallback',
                'type': 'fallback_zscore',
                'loaded_from': 'statistics'
            },
            'confidence': 'low'
        }
```

**Por que LRU Cache com Warm Loading?**
- 100 modelos mais acessados = ~80% das requisições (Pareto 80/20)
- Evita latência de cold start para modelos populares
- Eviccão automática de modelos menos usados

---

## Fluxos de Dados

### Fluxo 1: Treinamento de Modelo

**Dois modos de trigger:**

```
A. Manual (Cliente/API):
   Cliente → POST /training/{series_id} → Training API → RabbitMQ

B. Orquestrado (Airflow):
   Airflow DAG (semanal/drift) → POST /training/{series_id} → Training API → RabbitMQ
```

**Fluxo Completo:**

```
┌──────────────┐       ┌────────────────┐
│  Cliente ou  │  OU   │ Airflow DAG    │
│  API manual  │       │ (scheduled/    │
│              │       │  drift trigger)│
└──────┬───────┘       └──────┬─────────┘
       │                      │
       └───────┬──────────────┘
               │ POST /api/v1/training/sensor_001_radial
               ▼
       ┌───────────────┐
       │ Training API  │
       │               │
       │ 1. Valida     │
       │ 2. Cria job   │
       │ 3. Enfileira  │
       └───────┬───────┘
               │ 202 Accepted {"job_id": "..."}
               ▼
       ┌───────────────┐
       │   RabbitMQ    │
       └───────┬───────┘
               │
               ▼
       ┌───────────────┐
       │ Training      │
       │ Worker        │
       │               │
       │ • Treina      │
       │ • Registra    │
       │   MLflow      │
       │ • Staging     │
       └───────┬───────┘
               │
               ▼
       ┌───────────────┐
       │ MLflow Server │
       │ (v5: Staging) │
       └───────────────┘
```

**Airflow DAGs:**
- **Weekly Retraining**: Domingo 2am, 285k séries, submete via Training API
- **Drift Detection**: A cada 6h, verifica métricas, trigga retreino se drift detectado
- **Shadow Pipeline**: Orquestra deploy shadow → análise → aprovação/rejeição canary

**Latências típicas:**
- Validação: ~5ms
- Criação de job no Postgres: ~10ms
- Publicação no RabbitMQ: ~2ms
- **Total API response**: ~20ms (202 Accepted)
- Processamento assíncrono: 30-90s dependendo do tamanho

---

### Fluxo 2: Promoção para Produção (Direct)

```
┌─────────────┐
│   Cliente   │
└──────┬──────┘
       │ POST /api/v1/models/sensor_001_radial/versions/v5/promote
       │ {"strategy": "direct", "archive_existing": true}
       ▼
┌─────────────────┐
│  Training API   │
│                 │
│ 1. Valida:      │
│    ✓ v5 exists  │
│    ✓ v5 está em │
│      Staging    │
│ 2. Obtém versão │
│    atual em     │
│    Production   │
│    (v4)         │
│ 3. Transiciona  │
│    v5 → Prod    │
│ 4. Se archive:  │
│    v4 → Archive │
└──────┬──────────┘
       │ 200 OK
       │ {"version": "v5", "stage": "Production",
       │  "previous_version": "v4", "archived": true}
       ▼
┌─────────────────┐
│  MLflow Server  │
│                 │
│ Model Registry: │
│ ┌─────────────┐ │
│ │ v5: Prod    │ │ ← Agora servindo
│ │ v4: Archive │ │
│ │ v3: Archive │ │
│ └─────────────┘ │
└─────────────────┘
       │
       │ (Próxima requisição de inferência)
       ▼
┌─────────────────┐
│ Predictor Pod   │
│                 │
│ 1. Cache miss   │
│    para v5      │
│ 2. Load do      │
│    MLflow       │
│    (Prod stage) │
│ 3. Adiciona ao  │
│    LRU cache    │
└─────────────────┘
```

**Invalidação de Cache:**

Opção 1 - Lazy (padrão):
- Cache é invalidado automaticamente ao carregar modelo
- Próxima predição carrega v5

Opção 2 - Eager (via admin API):
```bash
POST /api/v1/admin/reload/sensor_001_radial
```

---

### Fluxo 3: Promoção Canary

```
┌─────────────┐
│   Cliente   │
└──────┬──────┘
       │ POST /api/v1/models/sensor_001_radial/versions/v6/promote
       │ {"strategy": "canary",
       │  "canary_config": {
       │    "initial_percentage": 5,
       │    "increment_percentage": 15,
       │    "increment_interval_hours": 2
       │  }}
       ▼
┌─────────────────┐
│  Training API   │
│                 │
│ 1. Valida v6    │
│ 2. Cria promo-  │
│    tion record  │
│    no Postgres  │
│ 3. Configura    │
│    Istio VS:    │
│    - v5: 95%    │
│    - v6: 5%     │
│ 4. Agenda job   │
│    de increment │
└──────┬──────────┘
       │ 202 Accepted
       │ {"promotion_id": "xyz789",
       │  "current_percentage": 5,
       │  "next_increment_at": "..."}
       ▼
┌─────────────────┐
│  Istio Virtual  │
│  Service        │
│                 │
│ http:           │
│ - route:        │
│   - v5: 95%     │
│   - v6: 5%      │
└─────────────────┘
       │
       │ (a cada 2 horas, scheduled job)
       ▼
┌─────────────────┐
│  Increment Job  │
│  (Scheduler)    │
│                 │
│ 1. Valida       │
│    métricas:    │
│    ✓ error_rate │
│      < 0.005    │
│    ✓ p99_latency│
│      < 100ms    │
│ 2. Se OK:       │
│    Incrementa   │
│    5% → 20%     │
│ 3. Se NOK:      │
│    Rollback     │
│    automático   │
└─────────────────┘
       │
       ▼
┌─────────────────┐
│  After 6-8      │
│  increments:    │
│  v6 → 100%      │
│  v5 → Archived  │
└─────────────────┘
```

**Métricas Monitoradas:**
- Error rate (threshold: 0.5%)
- P99 latency (threshold: 100ms)
- Anomaly rate (deviation < 20% de baseline)

**Rollback Automático:**
- Detecta degradação em janela de 5min
- Reverte tráfego para versão estável
- Notifica time via Slack/PagerDuty

---

### Fluxo 4: Inferência (Predição)

```
┌─────────────┐
│   Cliente   │
└──────┬──────┘
       │ POST /api/v1/predict/sensor_001_radial
       │ {"timestamp": 1733587200, "value": 0.315}
       ▼
┌─────────────────┐
│  Istio Gateway  │
│                 │
│ 1. Valida JWT   │
│ 2. Rate limit   │
│ 3. Routing      │
└──────┬──────────┘
       │
       ▼
┌─────────────────┐
│ Predictor Pod   │
│ (KServe)        │
│                 │
│ ┌─────────────┐ │
│ │ L1: Cache   │ │
│ │ Check       │ │
│ └──────┬──────┘ │
│        │ HIT!   │
│        ▼        │
│ ┌─────────────┐ │
│ │ model.      │ │
│ │ predict()   │ │
│ │             │ │
│ │ z_score =   │ │
│ │ |x-μ|/σ     │ │
│ │             │ │
│ │ anomaly =   │ │
│ │ z_score>3.0 │ │
│ └─────────────┘ │
└──────┬──────────┘
       │ 200 OK (2.1ms)
       │ {"anomaly": false,
       │  "anomaly_score": 0.23,
       │  "model_info": {"version": "v5", ...}}
       ▼
┌─────────────┐
│   Cliente   │
└─────────────┘
```

**Fallback Strategy:**

```
┌─────────────────┐
│ Try: Load from  │
│      MLflow     │
└──────┬──────────┘
       │ FAIL (MLflow down)
       ▼
┌─────────────────┐
│ Try: Load from  │
│      local      │
│      cache      │
│      (~/.mlflow)│
└──────┬──────────┘
       │ FAIL (cache empty)
       ▼
┌─────────────────┐
│ Fallback:       │
│ Z-score with    │
│ historical stats│
│                 │
│ confidence:     │
│ "low"           │
└─────────────────┘
```

**Latências observadas:**
- Cache hit: 2-5ms (P95)
- MLflow load (cache miss): 50-200ms (primeira chamada)
- Fallback Z-score: 5-10ms

---

## Escalabilidade

### Horizontal Autoscaling

**Inference Pods (KServe HPA):**

```yaml
scaleTarget: 80  # 80 requisições concorrentes
minReplicas: 3
maxReplicas: 50

# Com traffic de 2.850 req/s (pico):
# Pods necessários = 2850 / 80 = ~36 pods
```

**Training Workers:**

```yaml
# Baseado em queue depth
minReplicas: 5
maxReplicas: 20

# Com 2.35 treinos/s (pico) e 30s por treino:
# Queue depth = 2.35 * 30 = ~70 jobs
# Workers necessários = 70 / 10 (jobs por worker) = 7 workers
```

### Vertical Scaling

**Resource Requests/Limits:**

```yaml
# Predictor Pod
resources:
  requests:
    cpu: 500m      # 0.5 cores
    memory: 1Gi
  limits:
    cpu: 2000m     # 2 cores
    memory: 4Gi

# Training Worker
resources:
  requests:
    cpu: 1000m     # 1 core
    memory: 2Gi
  limits:
    cpu: 4000m     # 4 cores
    memory: 8Gi
```

**Cálculo de Capacidade Total:**

```
Inference:
- 50 pods × 4Gi = 200Gi RAM
- 50 pods × 2 cores = 100 cores CPU

Training:
- 20 workers × 8Gi = 160Gi RAM
- 20 workers × 4 cores = 80 cores CPU

Total:
- 360Gi RAM
- 180 cores CPU
```

---

## Multi-Tenancy e Isolamento

### Namespaces Kubernetes

```
ml-production/
├── anomaly-detector-predictor (Deployment)
├── training-api (Deployment)
├── training-workers (Deployment)
├── mlflow-server (StatefulSet)
├── postgresql (StatefulSet)
└── rabbitmq (StatefulSet)

ml-staging/
└── (mesmo conjunto de recursos)

ml-infra/
├── prometheus
├── grafana
└── alertmanager
```

### Network Policies

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: predictor-ingress
  namespace: ml-production
spec:
  podSelector:
    matchLabels:
      app: anomaly-detector-predictor
  policyTypes:
  - Ingress
  ingress:
  # Apenas tráfego do Istio gateway
  - from:
    - namespaceSelector:
        matchLabels:
          name: istio-system
    ports:
    - protocol: TCP
      port: 8080
  
  # MLflow server
  - from:
    - podSelector:
        matchLabels:
          app: anomaly-detector-predictor
    - podSelector:
        matchLabels:
          app: mlflow-server
    ports:
    - protocol: TCP
      port: 5000
```

---

## Resiliência e Disaster Recovery

### Circuit Breaker (Istio)

```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: mlflow-circuit-breaker
spec:
  host: mlflow-server.ml-infra.svc.cluster.local
  trafficPolicy:
    connectionPool:
      tcp:
        maxConnections: 100
      http:
        http1MaxPendingRequests: 50
        maxRequestsPerConnection: 2
    outlierDetection:
      consecutiveErrors: 5
      interval: 30s
      baseEjectionTime: 60s
      maxEjectionPercent: 50
```

**Comportamento:**
- Após 5 erros consecutivos, pod é ejetado por 60s
- Máximo 50% dos pods podem ser ejetados simultaneamente
- Evita cascata de falhas

### Backup e Recovery

**PostgreSQL (Metadados):**
```yaml
# CronJob para backup incremental a cada 6h
apiVersion: batch/v1
kind: CronJob
metadata:
  name: postgres-backup
spec:
  schedule: "0 */6 * * *"
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: pg-dump
            image: postgres:15
            command:
            - pg_dump
            - -h
            - postgresql.ml-production.svc.cluster.local
            - -U
            - mlflow
            - -Fc
            - -f
            - /backups/mlflow_$(date +%Y%m%d_%H%M%S).dump
            volumeMounts:
            - name: backup-volume
              mountPath: /backups
          volumes:
          - name: backup-volume
            persistentVolumeClaim:
              claimName: postgres-backup-pvc
```

**S3/MinIO (Artifacts):**
- Versionamento habilitado no bucket
- Lifecycle policy: transition para Glacier após 90 dias
- Cross-region replication (se disponível)

**Recovery Objectives:**
- **RPO (Recovery Point Objective)**: < 1 hora
- **RTO (Recovery Time Objective)**: < 15 minutos

**Disaster Recovery Runbook:**

1. **MLflow indisponível:**
   - Predictor continua servindo do cache local
   - Treinamentos ficam em fila até recovery
   - Alertar time de infra

2. **PostgreSQL corrompido:**
   - Restore do backup mais recente (< 6h atrás)
   - Replay de WAL logs se disponível
   - Validar integridade de model registry

3. **S3/MinIO indisponível:**
   - Predictor usa cache local (warm loaded models)
   - Novos treinamentos ficam bloqueados
   - Escalar para S3 secundário se configurado

---

## Observabilidade

### Métricas (Prometheus)

**RED Metrics (Request, Error, Duration):**

```promql
# Request Rate
sum(rate(http_requests_total{service="anomaly-predictor"}[5m]))

# Error Rate
sum(rate(http_requests_total{service="anomaly-predictor",status=~"5.."}[5m])) 
  / 
sum(rate(http_requests_total{service="anomaly-predictor"}[5m]))

# Duration (P95)
histogram_quantile(0.95, 
  sum(rate(http_request_duration_seconds_bucket{service="anomaly-predictor"}[5m])) by (le)
)
```

**USE Metrics (Utilization, Saturation, Errors):**

```promql
# CPU Utilization
rate(container_cpu_usage_seconds_total{pod=~"anomaly-predictor.*"}[5m])

# Memory Saturation
container_memory_working_set_bytes{pod=~"anomaly-predictor.*"} 
  / 
container_spec_memory_limit_bytes{pod=~"anomaly-predictor.*"}

# Disk Errors
rate(node_disk_io_errors_total[5m])
```

**Custom ML Metrics:**

```python
from prometheus_client import Counter, Histogram, Gauge

# Predições
predictions_total = Counter(
    'anomaly_predictions_total',
    'Total predictions made',
    ['series_id', 'model_version', 'anomaly']
)

# Latência de carregamento de modelo
model_load_duration = Histogram(
    'model_load_duration_seconds',
    'Time to load model',
    ['series_id', 'source'],  # source: mlflow, cache, fallback
    buckets=[0.01, 0.05, 0.1, 0.5, 1.0, 5.0]
)

# Cache hit rate
cache_hit_rate = Gauge(
    'model_cache_hit_rate',
    'Model cache hit rate'
)

# Tamanho da fila de treinamento
training_queue_depth = Gauge(
    'training_queue_depth',
    'Number of jobs in training queue'
)
```

### Distributed Tracing (Jaeger + OpenTelemetry)

```python
from opentelemetry import trace
from opentelemetry.exporter.jaeger import JaegerExporter
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor

# Setup
tracer_provider = TracerProvider()
jaeger_exporter = JaegerExporter(
    agent_host_name="jaeger-agent.ml-infra.svc.cluster.local",
    agent_port=6831
)
tracer_provider.add_span_processor(BatchSpanProcessor(jaeger_exporter))
trace.set_tracer_provider(tracer_provider)

tracer = trace.get_tracer(__name__)

# Instrumentação
@tracer.start_as_current_span("predict")
def predict(series_id: str, value: float):
    span = trace.get_current_span()
    span.set_attribute("series_id", series_id)
    
    with tracer.start_as_current_span("load_model"):
        model = load_model(series_id)
    
    with tracer.start_as_current_span("inference"):
        result = model.predict(value)
    
    span.set_attribute("anomaly", result['anomaly'])
    return result
```

**Exemplo de Trace:**

```
predict (152ms)
├── load_model (145ms)
│   ├── check_cache (2ms)
│   ├── mlflow_load (140ms)
│   │   ├── download_artifact (120ms)
│   │   └── deserialize (20ms)
│   └── cache_store (3ms)
└── inference (7ms)
    ├── preprocess (1ms)
    ├── compute_zscore (5ms)
    └── format_response (1ms)
```

### Alerting (Alertmanager)

```yaml
groups:
- name: anomaly_detector_alerts
  interval: 30s
  rules:
  
  # Disponibilidade
  - alert: HighErrorRate
    expr: |
      sum(rate(http_requests_total{service="anomaly-predictor",status=~"5.."}[5m])) 
        / 
      sum(rate(http_requests_total{service="anomaly-predictor"}[5m])) 
      > 0.05
    for: 5m
    labels:
      severity: critical
    annotations:
      summary: "High error rate on anomaly predictor"
      description: "Error rate is {{ $value | humanizePercentage }}"
  
  # Latência
  - alert: HighLatency
    expr: |
      histogram_quantile(0.99,
        sum(rate(http_request_duration_seconds_bucket{service="anomaly-predictor"}[5m])) by (le)
      ) > 0.1
    for: 5m
    labels:
      severity: warning
    annotations:
      summary: "High P99 latency on predictor"
      description: "P99 latency is {{ $value }}s"
  
  # Cache
  - alert: LowCacheHitRate
    expr: model_cache_hit_rate < 0.7
    for: 15m
    labels:
      severity: warning
    annotations:
      summary: "Low model cache hit rate"
      description: "Cache hit rate is {{ $value | humanizePercentage }}"
  
  # Fila de treinamento
  - alert: TrainingQueueBacklog
    expr: training_queue_depth > 1000
    for: 10m
    labels:
      severity: warning
    annotations:
      summary: "Large backlog in training queue"
      description: "{{ $value }} jobs waiting in queue"
  
  # Drift detection
  - alert: ModelDriftDetected
    expr: |
      sum(increase(model_drift_detected_total[1h])) by (series_id) > 0
    labels:
      severity: info
    annotations:
      summary: "Model drift detected for {{ $labels.series_id }}"
      description: "Consider retraining model"
```

### Dashboards (Grafana)

**Dashboard 1: System Overview**
- Request rate (global)
- Error rate (global)
- P50/P95/P99 latency
- Pod count e autoscaling
- Resource utilization (CPU/RAM)

**Dashboard 2: ML Metrics**
- Anomaly detection rate por série
- Cache hit rate
- Model load latency
- Training job throughput
- Queue depth

**Dashboard 3: Model Performance**
- Precision/Recall (quando ground truth disponível)
- False positive rate
- Canary deployment progress
- A/B test results

---

## Segurança

### Autenticação e Autorização

**JWT Token Validation (Istio):**

```yaml
apiVersion: security.istio.io/v1beta1
kind: RequestAuthentication
metadata:
  name: jwt-auth
  namespace: ml-production
spec:
  selector:
    matchLabels:
      app: anomaly-detector-predictor
  jwtRules:
  - issuer: "https://auth.company.com"
    jwksUri: "https://auth.company.com/.well-known/jwks.json"
    audiences:
    - "anomaly-detector-api"
```

**RBAC (AuthorizationPolicy):**

```yaml
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: predictor-authz
  namespace: ml-production
spec:
  selector:
    matchLabels:
      app: anomaly-detector-predictor
  action: ALLOW
  rules:
  # Viewers podem apenas fazer predições
  - from:
    - source:
        requestPrincipals: ["*"]
    to:
    - operation:
        methods: ["POST"]
        paths: ["/api/v1/predict/*"]
    when:
    - key: request.auth.claims[roles]
      values: ["viewer", "data_scientist", "ml_engineer", "admin"]
  
  # Apenas ML engineers podem promover modelos
  - from:
    - source:
        requestPrincipals: ["*"]
    to:
    - operation:
        methods: ["POST"]
        paths: ["/api/v1/models/*/versions/*/promote"]
    when:
    - key: request.auth.claims[roles]
      values: ["ml_engineer", "admin"]
```

### Network Security

**mTLS entre serviços:**

```yaml
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
  namespace: ml-production
spec:
  mtls:
    mode: STRICT  # Força mTLS em todo tráfego interno
```

**Secrets Management:**

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: mlflow-db-credentials
  namespace: ml-production
type: Opaque
data:
  username: bWxmbG93  # base64
  password: c3VwZXJzZWNyZXQ=  # base64
```

Montado em pods via:

```yaml
env:
- name: MLFLOW_DB_USERNAME
  valueFrom:
    secretKeyRef:
      name: mlflow-db-credentials
      key: username
```

---

## Deployment e CI/CD

### GitOps com ArgoCD

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: anomaly-detector
  namespace: argocd
spec:
  project: ml-production
  source:
    repoURL: https://github.com/company/mlops-manifests
    targetRevision: main
    path: anomaly-detector/overlays/production
  destination:
    server: https://kubernetes.default.svc
    namespace: ml-production
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
```

### CI/CD Pipeline (GitHub Actions)

```yaml
name: Build and Deploy

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v3
    - name: Run unit tests
      run: pytest tests/
    - name: Run integration tests
      run: pytest tests/integration/
  
  build:
    needs: test
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v3
    - name: Build Docker image
      run: |
        docker build -t ghcr.io/company/anomaly-predictor:${{ github.sha }} .
    - name: Push image
      run: |
        docker push ghcr.io/company/anomaly-predictor:${{ github.sha }}
  
  deploy:
    needs: build
    runs-on: ubuntu-latest
    if: github.ref == 'refs/heads/main'
    steps:
    - name: Update manifest
      run: |
        cd manifests/
        kustomize edit set image ghcr.io/company/anomaly-predictor:${{ github.sha }}
        git commit -am "Update image to ${{ github.sha }}"
        git push
    - name: Trigger ArgoCD sync
      run: |
        argocd app sync anomaly-detector
```
