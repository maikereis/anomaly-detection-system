# API Design - Sistema MLOps de Detecção de Anomalias

Este documento descreve o design completo das APIs do sistema, incluindo autenticação, endpoints de treinamento, inferência, gerenciamento de modelos, administração e monitoramento.

---

## 1. Autenticação e Autorização

### Estratégia de Autenticação

O sistema utiliza **JWT (JSON Web Tokens)** para autenticação stateless, implementado através do Istio Service Mesh. Isso permite validação de tokens no edge sem necessidade de consultas a banco de dados em cada requisição.

### Fluxo de Autenticação

```
Cliente → Istio Gateway (valida JWT) → Serviço Backend
```

### Token Structure

```json
{
  "sub": "user_12345",
  "name": "John Doe",
  "email": "john.doe@company.com",
  "roles": ["ml_engineer", "model_deployer"],
  "permissions": [
    "train:create",
    "train:read",
    "train:delete",
    "predict:read",
    "model:read",
    "model:promote",
    "admin:manage",
    "admin:read"
  ],
  "iat": 1733587200,
  "exp": 1733673600
}
```

### Níveis de Autorização

| Role | Permissões |
|------|------------|
| **viewer** | Leitura de predições, visualização de modelos e métricas |
| **data_scientist** | Tudo do viewer + criar treinamentos, visualizar jobs |
| **ml_engineer** | Tudo do data_scientist + promover modelos, invalidar cache, cancelar jobs |
| **admin** | Acesso completo incluindo gerenciamento de sistema e operações administrativas |

### Headers Requeridos

```http
Authorization: Bearer <jwt_token>
X-Request-ID: <uuid>  # Gerado pelo cliente ou gateway para tracing
X-Client-Version: <version>  # Para versionamento de API
```

---

## 2. API de Treinamento

### 2.1 POST /api/v1/training/{series_id}

Inicia um job de treinamento assíncrono para uma série temporal específica.

**Permissão requerida**: `train:create`

**Path Parameters:**
- `series_id` (string, required): Identificador único da série temporal (formato: `sensor_[id]_[axis]`)

**Request Body:**

```json
{
  "training_data": {
    "timestamps": [1733500000, 1733500300, 1733500600, ...],
    "values": [0.315, 0.298, 0.412, ...]
  },
  "config": {
    "window_hours": 168,
    "algorithm": "statistical",
    "hyperparameters": {
      "threshold_sigma": 3.0
    }
  },
  "metadata": {
    "triggered_by": "user@company.ai",
    "description": "Retreinamento semanal automático",
    "tags": ["weekly_retrain", "automated"],
    "priority": "normal"
  }
}
```

**Validações:**
- `training_data.timestamps`: mínimo 10.000 pontos, máximo 100.000 pontos
- `training_data.values`: mesma quantidade de timestamps, valores finitos (não NaN/Inf)
- `timestamps`: ordem cronológica crescente, sem duplicatas, formato Unix timestamp
- `values`: desvio padrão > 1e-6 (rejeitar séries constantes)
- `config.window_hours`: entre 24 e 168 horas
- `config.algorithm`: valores válidos: `statistical`, `isolation_forest`, `autoencoder`

**Response (202 Accepted):**

```json
{
  "status": "success",
  "data": {
    "job_id": "a7f3c8d1-4b6e-4f9a-b2c5-8d9e7f1a3b4c",
    "series_id": "sensor_001_radial",
    "status": "queued",
    "position_in_queue": 15,
    "estimated_start_time": "2024-12-07T15:23:45Z",
    "estimated_completion_time": "2024-12-07T15:24:30Z",
    "status_url": "/api/v1/training/jobs/a7f3c8d1-4b6e-4f9a-b2c5-8d9e7f1a3b4c"
  },
  "metadata": {
    "request_id": "req_f8e7d6c5b4a39281",
    "created_at": "2024-12-07T15:23:00Z",
    "version": "v1"
  }
}
```

**Error Responses:**

```json
// 400 Bad Request - Validação falhou
{
  "status": "error",
  "error": {
    "code": "INVALID_INPUT",
    "message": "Training data validation failed",
    "details": [
      {
        "field": "training_data.values",
        "issue": "Contains 15 null values at indices [42, 103, ...]"
      },
      {
        "field": "training_data.timestamps",
        "issue": "Not in ascending order at index 42"
      }
    ]
  },
  "metadata": {
    "request_id": "req_f8e7d6c5b4a39281",
    "timestamp": "2024-12-07T15:23:00Z"
  }
}

// 409 Conflict - Job já existe
{
  "status": "error",
  "error": {
    "code": "TRAINING_IN_PROGRESS",
    "message": "Training job already in progress for this series",
    "existing_job_id": "b8g4d9e2-5c7f-5g0b-c3d6-9e0f8g2b4c5d",
    "status_url": "/api/v1/training/jobs/b8g4d9e2-5c7f-5g0b-c3d6-9e0f8g2b4c5d"
  },
  "metadata": {
    "request_id": "req_f8e7d6c5b4a39281",
    "timestamp": "2024-12-07T15:23:00Z"
  }
}

// 422 Unprocessable Entity - Série constante
{
  "status": "error",
  "error": {
    "code": "CONSTANT_SERIES",
    "message": "Time series has zero variance",
    "details": [
      {
        "field": "training_data.values",
        "issue": "Standard deviation is 0.0 (constant series)",
        "suggestion": "Verify sensor is functioning correctly"
      }
    ]
  },
  "metadata": {
    "request_id": "req_f8e7d6c5b4a39281",
    "timestamp": "2024-12-07T15:23:00Z"
  }
}

// 422 Unprocessable Entity - Dados insuficientes
{
  "status": "error",
  "error": {
    "code": "INSUFFICIENT_DATA",
    "message": "Insufficient training data points",
    "details": [
      {
        "field": "training_data",
        "issue": "Received 8547 points, minimum required is 10000",
        "suggestion": "Collect more historical data before training"
      }
    ]
  },
  "metadata": {
    "request_id": "req_f8e7d6c5b4a39281",
    "timestamp": "2024-12-07T15:23:00Z"
  }
}

// 429 Too Many Requests
{
  "status": "error",
  "error": {
    "code": "RATE_LIMIT_EXCEEDED",
    "message": "Too many training requests",
    "retry_after_seconds": 60,
    "limit": "1 training per 5 minutes per series_id"
  },
  "metadata": {
    "request_id": "req_f8e7d6c5b4a39281",
    "timestamp": "2024-12-07T15:23:00Z"
  }
}
```

---

### 2.2 GET /api/v1/training/jobs/{job_id}

Consulta o status de um job de treinamento.

**Permissão requerida**: `train:read`

**Path Parameters:**
- `job_id` (string, required): UUID do job de treinamento

**Response (200 OK) - Job em processamento:**

```json
{
  "status": "success",
  "data": {
    "job_id": "a7f3c8d1-4b6e-4f9a-b2c5-8d9e7f1a3b4c",
    "series_id": "sensor_001_radial",
    "status": "processing",
    "progress": {
      "current_step": "model_training",
      "steps_completed": 2,
      "total_steps": 4,
      "percentage": 50
    },
    "created_at": "2024-12-07T15:23:00Z",
    "started_at": "2024-12-07T15:23:50Z",
    "estimated_completion": "2024-12-07T15:24:30Z",
    "worker_id": "training-worker-03"
  },
  "metadata": {
    "request_id": "req_f8e7d6c5b4a39281",
    "timestamp": "2024-12-07T15:25:00Z"
  }
}
```

**Response (200 OK) - Job completo:**

```json
{
  "status": "success",
  "data": {
    "job_id": "a7f3c8d1-4b6e-4f9a-b2c5-8d9e7f1a3b4c",
    "series_id": "sensor_001_radial",
    "status": "completed",
    "created_at": "2024-12-07T15:23:00Z",
    "started_at": "2024-12-07T15:23:50Z",
    "completed_at": "2024-12-07T15:24:32Z",
    "duration_seconds": 42,
    "result": {
      "model_version": "v5",
      "model_stage": "staging",
      "mlflow_run_id": "f8d7e6c5b4a39281",
      "model_uri": "models:/anomaly-detector-sensor_001_radial/5",
      "metrics": {
        "training_points_used": 10080,
        "mean": 0.315,
        "std": 0.087,
        "median": 0.312,
        "q1": 0.267,
        "q3": 0.356,
        "threshold_sigma": 3.0,
        "expected_anomaly_rate": 0.003
      }
    }
  },
  "metadata": {
    "request_id": "req_f8e7d6c5b4a39281",
    "timestamp": "2024-12-07T15:25:00Z"
  }
}
```

**Response (200 OK) - Job falhou:**

```json
{
  "status": "success",
  "data": {
    "job_id": "a7f3c8d1-4b6e-4f9a-b2c5-8d9e7f1a3b4c",
    "series_id": "sensor_001_radial",
    "status": "failed",
    "created_at": "2024-12-07T15:23:00Z",
    "started_at": "2024-12-07T15:23:50Z",
    "failed_at": "2024-12-07T15:24:10Z",
    "error": {
      "code": "TRAINING_FAILED",
      "message": "Model training encountered an error",
      "details": "Unable to compute robust statistics due to extreme outliers (>5 sigma)",
      "retryable": true,
      "retry_count": 0,
      "max_retries": 3
    }
  },
  "metadata": {
    "request_id": "req_f8e7d6c5b4a39281",
    "timestamp": "2024-12-07T15:25:00Z"
  }
}
```

**Status Values:**
- `queued`: Aguardando worker disponível
- `processing`: Treinamento em execução
- `completed`: Concluído com sucesso
- `failed`: Falhou após todas as tentativas
- `cancelled`: Cancelado manualmente

---

### 2.3 GET /api/v1/training/jobs

Recupera histórico de jobs de treinamento com filtros e paginação.

**Permissão requerida**: `train:read`

**Query Parameters:**
- `series_id` (string, optional): Filtrar por série
- `status` (string, optional): Filtrar por status (`queued`, `processing`, `completed`, `failed`, `cancelled`)
- `triggered_by` (string, optional): Filtrar por usuário que criou
- `from_date` (ISO 8601, optional): Data inicial
- `to_date` (ISO 8601, optional): Data final
- `page` (integer, optional): Número da página (default: 1)
- `page_size` (integer, optional): Itens por página (default: 20, max: 100)
- `sort_by` (string, optional): Campo para ordenação (`created_at`, `completed_at`, `duration`, default: `created_at`)
- `sort_order` (string, optional): Ordem (`asc`, `desc`, default: `desc`)

**Request Example:**

```
GET /api/v1/training/jobs?series_id=sensor_001_radial&status=completed&page=1&page_size=20&sort_by=created_at&sort_order=desc
```

**Response (200 OK):**

```json
{
  "status": "success",
  "data": {
    "jobs": [
      {
        "job_id": "a7f3c8d1-4b6e-4f9a-b2c5-8d9e7f1a3b4c",
        "series_id": "sensor_001_radial",
        "status": "completed",
        "created_at": "2024-12-07T15:23:00Z",
        "started_at": "2024-12-07T15:23:50Z",
        "completed_at": "2024-12-07T15:24:32Z",
        "duration_seconds": 42,
        "model_version": "v5",
        "triggered_by": "user@company.ai",
        "priority": "normal"
      },
      {
        "job_id": "b8g4d9e2-5c7f-5g0b-c3d6-9e0f8g2b4c5d",
        "series_id": "sensor_001_radial",
        "status": "completed",
        "created_at": "2024-12-06T10:15:00Z",
        "started_at": "2024-12-06T10:15:45Z",
        "completed_at": "2024-12-06T10:16:28Z",
        "duration_seconds": 43,
        "model_version": "v4",
        "triggered_by": "scheduler@company.ai",
        "priority": "low"
      }
    ],
    "pagination": {
      "current_page": 1,
      "page_size": 20,
      "total_items": 47,
      "total_pages": 3,
      "has_next": true,
      "has_previous": false,
      "next_url": "/api/v1/training/jobs?page=2&page_size=20&series_id=sensor_001_radial&status=completed",
      "previous_url": null
    }
  },
  "metadata": {
    "request_id": "req_f8e7d6c5b4a39281",
    "timestamp": "2024-12-07T15:30:00Z"
  }
}
```

---

### 2.4 DELETE /api/v1/training/jobs/{job_id}

Cancela um job que está na fila ou em processamento.

**Permissão requerida**: `train:delete`

**Path Parameters:**
- `job_id` (string, required): UUID do job

**Response (200 OK):**

```json
{
  "status": "success",
  "data": {
    "job_id": "a7f3c8d1-4b6e-4f9a-b2c5-8d9e7f1a3b4c",
    "status": "cancelled",
    "cancelled_at": "2024-12-07T15:25:00Z",
    "message": "Training job successfully cancelled"
  },
  "metadata": {
    "request_id": "req_f8e7d6c5b4a39281",
    "timestamp": "2024-12-07T15:25:00Z"
  }
}
```

**Error Response (400 Bad Request) - Job já completado:**

```json
{
  "status": "error",
  "error": {
    "code": "CANNOT_CANCEL",
    "message": "Cannot cancel job in current state",
    "current_status": "completed",
    "allowed_statuses": ["queued", "processing"]
  },
  "metadata": {
    "request_id": "req_f8e7d6c5b4a39281",
    "timestamp": "2024-12-07T15:25:00Z"
  }
}
```

---

## 3. API de Inferência

### 3.1 POST /api/v1/predict/{series_id}

Predição single-point síncrona.

**Permissão requerida**: `predict:read`

**Path Parameters:**
- `series_id` (string, required): Identificador da série temporal

**Query Parameters:**
- `version` (string, optional): Versão específica do modelo (default: Production)

**Request Body:**

```json
{
  "timestamp": 1733587200,
  "value": 0.315
}
```

**Response (200 OK):**

```json
{
  "status": "success",
  "data": {
    "timestamp": 1733587200,
    "value": 0.315,
    "prediction": {
      "anomaly": false,
      "anomaly_score": 0.23,
      "confidence": "high"
    },
    "model_info": {
      "version": "v5",
      "stage": "production",
      "type": "mlflow_trained",
      "loaded_from": "mlflow_registry"
    },
    "latency_ms": 2.1
  },
  "metadata": {
    "request_id": "req_f8e7d6c5b4a39281",
    "timestamp": "2024-12-07T15:30:00Z"
  }
}
```

**Model Types:**
- `mlflow_trained`: Modelo MLflow carregado do registry (atual)
- `cached_mlflow`: Modelo MLflow do cache local
- `fallback_zscore`: Modelo estatístico Z-score (fallback)

**Confidence Levels:**
- `high`: Modelo treinado em produção
- `medium`: Modelo do cache local
- `low`: Fallback estatístico

**Error Response (404 Not Found):**

```json
{
  "status": "error",
  "error": {
    "code": "MODEL_NOT_FOUND",
    "message": "No model found for series_id",
    "series_id": "sensor_999_radial",
    "suggestion": "Train a model for this series first"
  },
  "metadata": {
    "request_id": "req_f8e7d6c5b4a39281",
    "timestamp": "2024-12-07T15:30:00Z"
  }
}
```

---

### 3.2 POST /api/v1/predict/{series_id}/batch

Predição batch (máximo 32.768 pontos por requisição).

**Permissão requerida**: `predict:read`

**Path Parameters:**
- `series_id` (string, required): Identificador da série temporal

**Query Parameters:**
- `version` (string, optional): Versão específica do modelo (default: Production)

**Request Body:**

```json
{
  "data": [
    {"timestamp": 1733587200, "value": 0.315},
    {"timestamp": 1733587500, "value": 0.298},
    {"timestamp": 1733587800, "value": 0.412}
  ]
}
```

**Response (200 OK):**

```json
{
  "status": "success",
  "data": {
    "predictions": [
      {
        "timestamp": 1733587200,
        "value": 0.315,
        "anomaly": false,
        "anomaly_score": 0.23
      },
      {
        "timestamp": 1733587500,
        "value": 0.298,
        "anomaly": false,
        "anomaly_score": 0.18
      },
      {
        "timestamp": 1733587800,
        "value": 0.412,
        "anomaly": true,
        "anomaly_score": 3.45
      }
    ],
    "summary": {
      "total_points": 3,
      "anomalies_detected": 1,
      "anomaly_rate": 0.33,
      "processing_time_ms": 8.7
    },
    "model_info": {
      "version": "v5",
      "stage": "production",
      "type": "mlflow_trained"
    }
  },
  "metadata": {
    "request_id": "req_f8e7d6c5b4a39281",
    "timestamp": "2024-12-07T15:30:00Z"
  }
}
```

**Error Response (413 Payload Too Large):**

```json
{
  "status": "error",
  "error": {
    "code": "PAYLOAD_TOO_LARGE",
    "message": "Batch size exceeds maximum allowed",
    "received_points": 35000,
    "max_points": 32768,
    "suggestion": "Split request into multiple batches"
  },
  "metadata": {
    "request_id": "req_f8e7d6c5b4a39281",
    "timestamp": "2024-12-07T15:30:00Z"
  }
}
```

---

## 4. API de Gerenciamento de Modelos

### 4.1 GET /api/v1/models/{series_id}/versions

Lista histórico de versões de modelos para uma série.

**Permissão requerida**: `model:read`

**Path Parameters:**
- `series_id` (string, required): Identificador da série

**Query Parameters:**
- `stage` (string, optional): Filtrar por estágio (`None`, `Staging`, `Production`, `Archived`, `all`, default: `all`)
- `limit` (integer, optional): Número de versões (default: 10, max: 100)
- `offset` (integer, optional): Offset para paginação (default: 0)

**Response (200 OK):**

```json
{
  "status": "success",
  "data": {
    "series_id": "sensor_001_radial",
    "total_versions": 23,
    "versions": [
      {
        "version": "v23",
        "stage": "Production",
        "created_at": "2024-12-07T10:00:00Z",
        "promoted_at": "2024-12-07T18:30:00Z",
        "mlflow_run_id": "f8d7e6c5b4a39281",
        "metrics": {
          "mean": 0.315,
          "std": 0.087,
          "training_points": 10080
        },
        "performance": {
          "avg_latency_ms": 2.1,
          "total_predictions": 1547892,
          "anomaly_rate": 0.0022
        }
      },
      {
        "version": "v22",
        "stage": "Archived",
        "created_at": "2024-12-01T08:30:00Z",
        "promoted_at": "2024-12-01T09:00:00Z",
        "archived_at": "2024-12-07T18:30:00Z",
        "mlflow_run_id": "e7d6c5b4a3928172",
        "metrics": {
          "mean": 0.312,
          "std": 0.085,
          "training_points": 10080
        }
      }
    ]
  },
  "metadata": {
    "request_id": "req_f8e7d6c5b4a39281",
    "timestamp": "2024-12-07T15:35:00Z"
  }
}
```

---

### 4.2 POST /api/v1/models/{series_id}/versions/{version}/promote

Promove um modelo para produção com estratégia de deployment configurável.

**Permissão requerida**: `model:promote`

**Path Parameters:**
- `series_id` (string, required): Identificador da série
- `version` (string, required): Versão do modelo (ex: `v5`)

**Request Body (Direct Promotion):**

```json
{
  "strategy": "direct",
  "archive_existing": true
}
```

**Request Body (Canary Deployment):**

```json
{
  "strategy": "canary",
  "archive_existing": false,
  "canary_config": {
    "initial_percentage": 5,
    "increment_percentage": 15,
    "increment_interval_hours": 2,
    "max_percentage": 100,
    "rollback_on_error_rate": 0.005,
    "rollback_on_latency_p99_ms": 100
  }
}
```

**Response (200 OK) - Direct promotion:**

```json
{
  "status": "success",
  "data": {
    "series_id": "sensor_001_radial",
    "version": "v23",
    "previous_stage": "Staging",
    "new_stage": "Production",
    "promoted_at": "2024-12-07T16:00:00Z",
    "previous_production_version": "v22",
    "previous_production_archived": true
  },
  "metadata": {
    "request_id": "req_f8e7d6c5b4a39281",
    "timestamp": "2024-12-07T16:00:00Z"
  }
}
```

**Response (202 Accepted) - Canary deployment:**

```json
{
  "status": "success",
  "data": {
    "promotion_id": "e5d4c3b2-a1f0-4e9d-8c7b-6a5f4e3d2c1b",
    "series_id": "sensor_001_radial",
    "version": "v23",
    "strategy": "canary",
    "status": "in_progress",
    "current_percentage": 5,
    "next_increment_at": "2024-12-07T18:00:00Z",
    "tracking_url": "/api/v1/models/sensor_001_radial/promotions/e5d4c3b2-a1f0-4e9d-8c7b-6a5f4e3d2c1b"
  },
  "metadata": {
    "request_id": "req_f8e7d6c5b4a39281",
    "timestamp": "2024-12-07T16:00:00Z"
  }
}
```

**Error Response (409 Conflict):**

```json
{
  "status": "error",
  "error": {
    "code": "INVALID_STAGE_TRANSITION",
    "message": "Model must be in Staging before promoting to Production",
    "current_stage": "None",
    "required_stage": "Staging",
    "suggestion": "Promote to Staging first, then to Production"
  },
  "metadata": {
    "request_id": "req_f8e7d6c5b4a39281",
    "timestamp": "2024-12-07T16:00:00Z"
  }
}
```

---

### 4.3 GET /api/v1/models/{series_id}/promotions/{promotion_id}

Consulta status de uma promoção canary.

**Permissão requerida**: `model:read`

**Response (200 OK):**

```json
{
  "status": "success",
  "data": {
    "promotion_id": "e5d4c3b2-a1f0-4e9d-8c7b-6a5f4e3d2c1b",
    "series_id": "sensor_001_radial",
    "version": "v23",
    "strategy": "canary",
    "status": "in_progress",
    "current_percentage": 20,
    "started_at": "2024-12-07T16:00:00Z",
    "next_increment_at": "2024-12-07T20:00:00Z",
    "increments_history": [
      {
        "percentage": 5,
        "started_at": "2024-12-07T16:00:00Z",
        "metrics": {
          "error_rate": 0.0002,
          "p99_latency_ms": 8.3,
          "anomaly_rate": 0.0023
        }
      },
      {
        "percentage": 20,
        "started_at": "2024-12-07T18:00:00Z",
        "metrics": {
          "error_rate": 0.0001,
          "p99_latency_ms": 7.8,
          "anomaly_rate": 0.0022
        }
      }
    ],
    "config": {
      "initial_percentage": 5,
      "increment_percentage": 15,
      "increment_interval_hours": 2,
      "rollback_on_error_rate": 0.005,
      "rollback_on_latency_p99_ms": 100
    }
  },
  "metadata": {
    "request_id": "req_f8e7d6c5b4a39281",
    "timestamp": "2024-12-07T19:00:00Z"
  }
}
```

---

### 4.4 DELETE /api/v1/models/{series_id}/promotions/{promotion_id}

Cancela uma promoção canary em progresso (rollback).

**Permissão requerida**: `model:promote`

**Response (200 OK):**

```json
{
  "status": "success",
  "data": {
    "promotion_id": "e5d4c3b2-a1f0-4e9d-8c7b-6a5f4e3d2c1b",
    "status": "rolled_back",
    "rolled_back_at": "2024-12-07T19:30:00Z",
    "reason": "Manual rollback requested",
    "final_percentage": 20,
    "reverted_to_version": "v22"
  },
  "metadata": {
    "request_id": "req_f8e7d6c5b4a39281",
    "timestamp": "2024-12-07T19:30:00Z"
  }
}
```

---

### 4.5 GET /api/v1/models/{series_id}/deployment-config

Retorna configuração atual de deployment (production + canary se ativo).

**Permissão requerida**: `model:read`

**Response (200 OK):**

```json
{
  "status": "success",
  "data": {
    "series_id": "sensor_001_radial",
    "deployments": [
      {
        "version": "v22",
        "stage": "Production",
        "traffic_percentage": 80,
        "deployed_at": "2024-12-01T09:00:00Z"
      },
      {
        "version": "v23",
        "stage": "Canary",
        "traffic_percentage": 20,
        "deployed_at": "2024-12-07T16:00:00Z"
      }
    ],
    "canary_status": {
      "active": true,
      "promotion_id": "e5d4c3b2-a1f0-4e9d-8c7b-6a5f4e3d2c1b",
      "current_percentage": 20,
      "next_increment_at": "2024-12-07T20:00:00Z"
    }
  },
  "metadata": {
    "request_id": "req_f8e7d6c5b4a39281",
    "timestamp": "2024-12-07T19:00:00Z"
  }
}
```

---

### 4.6 GET /api/v1/models/{series_id}/metrics

Métricas agregadas de modelo em produção.

**Permissão requerida**: `model:read`

**Query Parameters:**
- `window` (string, optional): Janela de tempo (`1h`, `24h`, `7d`, `30d`, default: `24h`)
- `include_canary` (boolean, optional): Incluir métricas do canary separadamente (default: false)

**Response (200 OK):**

```json
{
  "status": "success",
  "data": {
    "series_id": "sensor_001_radial",
    "model_version": "v23",
    "window": "24h",
    "production_metrics": {
      "total_predictions": 28800,
      "anomalies_detected": 432,
      "anomaly_rate": 0.015,
      "avg_latency_ms": 2.3,
      "p95_latency_ms": 4.3,
      "p99_latency_ms": 8.7,
      "error_rate": 0.0001
    },
    "drift_detection": {
      "data_drift_detected": false,
      "concept_drift_detected": false,
      "last_check": "2024-12-07T19:00:00Z"
    },
    "canary_metrics": {
      "version": "v23",
      "traffic_percentage": 20,
      "total_predictions": 5760,
      "anomalies_detected": 84,
      "anomaly_rate": 0.0146,
      "avg_latency_ms": 2.1,
      "p95_latency_ms": 4.1,
      "p99_latency_ms": 7.8,
      "error_rate": 0.0001
    }
  },
  "metadata": {
    "request_id": "req_f8e7d6c5b4a39281",
    "timestamp": "2024-12-07T19:30:00Z"
  }
}
```

---

### 4.7 GET /api/v1/models/{series_id}/versions/{version}/metrics

Métricas detalhadas de uma versão específica.

**Permissão requerida**: `model:read`

**Response (200 OK):**

```json
{
  "status": "success",
  "data": {
    "series_id": "sensor_001_radial",
    "version": "v23",
    "training_info": {
      "trained_at": "2024-12-07T10:00:00Z",
      "training_duration_seconds": 42,
      "data_points_used": 10080,
      "data_window": {
        "start": "2024-11-30T10:00:00Z",
        "end": "2024-12-07T10:00:00Z"
      }
    },
    "model_metrics": {
      "mean": 0.315,
      "std": 0.087,
      "median": 0.312,
      "q1": 0.267,
      "q3": 0.356,
      "threshold_sigma": 3.0
    },
    "performance_metrics": {
      "avg_inference_latency_ms": 2.1,
      "p95_inference_latency_ms": 4.3,
      "p99_inference_latency_ms": 8.7,
      "total_predictions": 1547892,
      "anomalies_detected": 3421,
      "anomaly_rate": 0.0022
    },
    "validation_results": {
      "passed": true,
      "tests": [
        {
          "name": "smoke_test",
          "passed": true,
          "message": "Model loads successfully"
        },
        {
          "name": "sanity_check",
          "passed": true,
          "message": "Anomaly rate within expected range (0.001-0.005)"
        }
      ]
    }
  },
  "metadata": {
    "request_id": "req_f8e7d6c5b4a39281",
    "timestamp": "2024-12-07T19:30:00Z"
  }
}
```

---

## 5. API de Catálogo de Séries

### 5.1 GET /api/v1/series

Lista todas as séries temporais cadastradas no sistema.

**Permissão requerida**: `model:read`

**Query Parameters:**
- `sensor_type` (string, optional): Filtrar por tipo (`temperature`, `vibration`, `pressure`)
- `axis` (string, optional): Filtrar por eixo (`radial`, `horizontal`, `vertical`)
- `is_active` (boolean, optional): Filtrar por status ativo
- `has_model` (boolean, optional): Filtrar séries com modelo treinado
- `page` (integer, optional): Número da página (default: 1)
- `page_size` (integer, optional): Itens por página (default: 50, max: 200)

**Response (200 OK):**

```json
{
  "status": "success",
  "data": {
    "series": [
      {
        "series_id": "sensor_001_radial",
        "sensor_type": "vibration",
        "axis": "radial",
        "equipment_id": "motor_pump_A",
        "location": "plant_sao_paulo",
        "is_active": true,
        "model_status": {
          "has_model": true,
          "production_version": "v23",
          "staging_version": null,
          "last_trained": "2024-12-07T10:00:00Z",
          "total_versions": 23
        },
        "latest_metrics": {
          "last_prediction": "2024-12-07T19:30:00Z",
          "anomaly_rate_24h": 0.0022,
          "avg_latency_ms": 2.1
        }
      },
      {
        "series_id": "sensor_001_horizontal",
        "sensor_type": "vibration",
        "axis": "horizontal",
        "equipment_id": "motor_pump_A",
        "location": "plant_sao_paulo",
        "is_active": true,
        "model_status": {
          "has_model": true,
          "production_version": "v18",
          "staging_version": "v19",
          "last_trained": "2024-12-06T14:30:00Z",
          "total_versions": 19
        },
        "latest_metrics": {
          "last_prediction": "2024-12-07T19:30:00Z",
          "anomaly_rate_24h": 0.0018,
          "avg_latency_ms": 2.3
        }
      }
    ],
    "pagination": {
      "current_page": 1,
      "page_size": 50,
      "total_items": 285000,
      "total_pages": 5700,
      "has_next": true,
      "has_previous": false
    },
    "summary": {
      "total_series": 285000,
      "active_series": 282000,
      "series_with_models": 278500,
      "series_without_models": 6500
    }
  },
  "metadata": {
    "request_id": "req_f8e7d6c5b4a39281",
    "timestamp": "2024-12-07T19:30:00Z"
  }
}
```

---

### 5.2 GET /api/v1/series/{series_id}

Detalhes de uma série específica.

**Permissão requerida**: `model:read`

**Response (200 OK):**

```json
{
  "status": "success",
  "data": {
    "series_id": "sensor_001_radial",
    "sensor_type": "vibration",
    "axis": "radial",
    "equipment_id": "motor_pump_A",
    "location": "plant_sao_paulo",
    "sampling_config": {
      "frequency_hz": 16000,
      "duration_seconds": 1.0,
      "num_lines": 16384,
      "interval_seconds": 300
    },
    "is_active": true,
    "created_at": "2024-01-15T08:00:00Z",
    "model_status": {
      "has_model": true,
      "production_version": "v23",
      "staging_version": null,
      "last_trained": "2024-12-07T10:00:00Z",
      "total_versions": 23,
      "retention_policy": "keep_last_10_versions"
    },
    "statistics": {
      "total_predictions": 1547892,
      "total_training_jobs": 23,
      "first_prediction": "2024-01-20T10:00:00Z",
      "last_prediction": "2024-12-07T19:30:00Z"
    }
  },
  "metadata": {
    "request_id": "req_f8e7d6c5b4a39281",
    "timestamp": "2024-12-07T19:30:00Z"
  }
}
```

---

## 6. API de Visualização

### 6.1 GET /api/v1/plot

Gera visualização dos dados de treinamento e predições.

**Permissão requerida**: `model:read`

**Query Parameters:**
- `series_id` (string, required): Identificador da série
- `version` (string, optional): Versão do modelo (default: Production)
- `format` (string, optional): Formato de saída (`html`, `json`, default: `html`)
- `include_predictions` (boolean, optional): Incluir predições recentes (default: false)
- `prediction_window_hours` (integer, optional): Janela de predições (default: 24, max: 168)

**Response (200 OK) - HTML:**

Retorna página HTML interativa com gráfico Plotly mostrando:
- Dados de treinamento com média e bandas de desvio padrão
- Pontos anômalos destacados (se `include_predictions=true`)
- Métricas do modelo

**Response (200 OK) - JSON:**

```json
{
  "status": "success",
  "data": {
    "series_id": "sensor_001_radial",
    "version": "v23",
    "training_data": {
      "timestamps": [1733500000, 1733500300, ...],
      "values": [0.315, 0.298, ...],
      "count": 10080
    },
    "model_parameters": {
      "mean": 0.315,
      "std": 0.087,
      "threshold_sigma": 3.0,
      "upper_bound": 0.576,
      "lower_bound": 0.054
    },
    "predictions": [
      {
        "timestamp": 1733587200,
        "value": 0.412,
        "anomaly": true,
        "anomaly_score": 3.45
      }
    ]
  },
  "metadata": {
    "request_id": "req_f8e7d6c5b4a39281",
    "timestamp": "2024-12-07T19:30:00Z"
  }
}
```

---

## 7. API Administrativa

### 7.1 POST /api/v1/admin/reload/{series_id}

Força reload de um modelo específico no cache de inferência.

**Permissão requerida**: `admin:manage`

**Path Parameters:**
- `series_id` (string, required): Identificador da série

**Response (202 Accepted):**

```json
{
  "status": "success",
  "data": {
    "series_id": "sensor_001_radial",
    "status": "reload_scheduled",
    "message": "Model will be reloaded on next prediction request",
    "scheduled_at": "2024-12-07T19:35:00Z",
    "affected_pods": 8
  },
  "metadata": {
    "request_id": "req_f8e7d6c5b4a39281",
    "timestamp": "2024-12-07T19:35:00Z"
  }
}
```

---

### 7.2 POST /api/v1/admin/reload-all

Força rolling restart de todos os pods de inferência.

**Permissão requerida**: `admin:manage`

**Request Body:**

```json
{
  "strategy": "rolling",
  "batch_size": 5,
  "wait_seconds": 30,
  "reason": "Weekly cache refresh"
}
```

**Response (202 Accepted):**

```json
{
  "status": "success",
  "data": {
    "operation_id": "op_abc123def456",
    "deployment": "anomaly-detector-predictor",
    "namespace": "ml-production",
    "strategy": "rolling",
    "total_pods": 8,
    "batch_size": 5,
    "estimated_completion": "2024-12-07T19:45:00Z",
    "tracking_url": "/api/v1/admin/operations/op_abc123def456"
  },
  "metadata": {
    "request_id": "req_f8e7d6c5b4a39281",
    "timestamp": "2024-12-07T19:35:00Z"
  }
}
```

---

### 7.3 GET /api/v1/admin/cache/stats

Estatísticas do cache de modelos em todos os pods.

**Permissão requerida**: `admin:read`

**Response (200 OK):**

```json
{
  "status": "success",
  "data": {
    "pods": [
      {
        "pod_name": "predictor-pod-1",
        "node": "node-worker-3",
        "cache_stats": {
          "models_loaded": 47,
          "memory_usage_mb": 342.5,
          "cache_hits": 15423,
          "cache_misses": 234,
          "hit_rate": 0.985,
          "load_failures": 3
        },
        "uptime_seconds": 86400,
        "last_updated": "2024-12-07T19:36:00Z"
      },
      {
        "pod_name": "predictor-pod-2",
        "node": "node-worker-4",
        "cache_stats": {
          "models_loaded": 52,
          "memory_usage_mb": 378.2,
          "cache_hits": 17892,
          "cache_misses": 287,
          "hit_rate": 0.984,
          "load_failures": 2
        },
        "uptime_seconds": 72000,
        "last_updated": "2024-12-07T19:36:00Z"
      }
    ],
    "aggregate": {
      "total_pods": 8,
      "total_models_loaded": 312,
      "total_memory_usage_mb": 2456.3,
      "avg_memory_per_pod_mb": 307.0,
      "avg_hit_rate": 0.982,
      "total_cache_hits": 124587,
      "total_cache_misses": 2145
    }
  },
  "metadata": {
    "request_id": "req_f8e7d6c5b4a39281",
    "timestamp": "2024-12-07T19:36:00Z"
  }
}
```

---

### 7.4 DELETE /api/v1/admin/cache/{series_id}

Remove um modelo específico do cache em todos os pods.

**Permissão requerida**: `admin:manage`

**Response (200 OK):**

```json
{
  "status": "success",
  "data": {
    "series_id": "sensor_001_radial",
    "pods_affected": 8,
    "status": "cache_invalidated",
    "message": "Model removed from cache on all pods",
    "invalidated_at": "2024-12-07T19:37:00Z"
  },
  "metadata": {
    "request_id": "req_f8e7d6c5b4a39281",
    "timestamp": "2024-12-07T19:37:00Z"
  }
}
```

---

### 7.5 GET /api/v1/admin/operations/{operation_id}

Consulta status de operações administrativas assíncronas.

**Permissão requerida**: `admin:read`

**Response (200 OK):**

```json
{
  "status": "success",
  "data": {
    "operation_id": "op_abc123def456",
    "type": "rolling_restart",
    "status": "in_progress",
    "started_at": "2024-12-07T19:35:00Z",
    "progress": {
      "completed_pods": 5,
      "total_pods": 8,
      "percentage": 62.5
    },
    "estimated_completion": "2024-12-07T19:45:00Z"
  },
  "metadata": {
    "request_id": "req_f8e7d6c5b4a39281",
    "timestamp": "2024-12-07T19:40:00Z"
  }
}
```

---

## 8. API de Health Check e Monitoramento

### 8.1 GET /api/v1/health

Health check básico do serviço.

**Permissão requerida**: Nenhuma (público)

**Response (200 OK):**

```json
{
  "status": "healthy",
  "timestamp": "2024-12-07T19:37:00Z",
  "version": "2.1.0",
  "uptime_seconds": 86400,
  "service": "anomaly-detection-mlops"
}
```

**Response (503 Service Unavailable):**

```json
{
  "status": "unhealthy",
  "timestamp": "2024-12-07T19:37:00Z",
  "version": "2.1.0",
  "service": "anomaly-detection-mlops",
  "issues": [
    {
      "component": "mlflow",
      "status": "unreachable",
      "message": "Cannot connect to MLflow tracking server",
      "since": "2024-12-07T19:30:00Z"
    }
  ]
}
```

---

### 8.2 GET /api/v1/readiness

Kubernetes readiness probe - indica se pod está pronto para receber tráfego.

**Permissão requerida**: Nenhuma (público)

**Response (200 OK):**

```json
{
  "ready": true,
  "timestamp": "2024-12-07T19:37:00Z"
}
```

**Response (503 Service Unavailable):**

```json
{
  "ready": false,
  "timestamp": "2024-12-07T19:37:00Z",
  "reason": "models_not_loaded"
}
```

---

### 8.3 GET /api/v1/liveness

Kubernetes liveness probe - indica se pod está vivo.

**Permissão requerida**: Nenhuma (público)

**Response (200 OK):**

```json
{
  "alive": true,
  "timestamp": "2024-12-07T19:37:00Z"
}
```

---

### 8.4 GET /api/v1/health/detailed

Health check detalhado incluindo todas as dependências.

**Permissão requerida**: `admin:read`

**Response (200 OK):**

```json
{
  "status": "success",
  "data": {
    "overall_status": "healthy",
    "timestamp": "2024-12-07T19:37:00Z",
    "version": "2.1.0",
    "components": {
      "api_server": {
        "status": "healthy",
        "uptime_seconds": 86400,
        "memory_usage_mb": 512.3,
        "cpu_usage_percent": 23.5
      },
      "mlflow": {
        "status": "healthy",
        "endpoint": "http://mlflow-server.ml-infra.svc.cluster.local:5000",
        "response_time_ms": 45,
        "last_check": "2024-12-07T19:36:55Z"
      },
      "postgresql": {
        "status": "healthy",
        "connections_active": 12,
        "connections_max": 100,
        "response_time_ms": 8,
        "last_check": "2024-12-07T19:36:55Z"
      },
      "s3": {
        "status": "healthy",
        "endpoint": "s3.amazonaws.com",
        "response_time_ms": 120,
        "last_check": "2024-12-07T19:36:55Z"
      },
      "rabbitmq": {
        "status": "healthy",
        "queued_jobs": 23,
        "consumers": 10,
        "last_check": "2024-12-07T19:36:55Z"
      }
    },
    "dependencies_summary": {
      "total": 5,
      "healthy": 5,
      "degraded": 0,
      "unhealthy": 0
    }
  },
  "metadata": {
    "request_id": "req_f8e7d6c5b4a39281",
    "timestamp": "2024-12-07T19:37:00Z"
  }
}
```

---

### 8.5 GET /api/v1/metrics

Métricas do sistema em formato JSON (também disponível em /metrics para Prometheus).

**Permissão requerida**: `admin:read`

**Response (200 OK):**

```json
{
  "status": "success",
  "data": {
    "timestamp": "2024-12-07T19:38:00Z",
    "training": {
      "jobs_queued": 23,
      "jobs_processing": 10,
      "jobs_completed_last_hour": 147,
      "jobs_failed_last_hour": 3,
      "avg_training_duration_seconds": 38.5,
      "p50_training_duration_seconds": 35.2,
      "p95_training_duration_seconds": 72.3,
      "p99_training_duration_seconds": 94.7
    },
    "inference": {
      "predictions_last_minute": 8234,
      "predictions_last_hour": 493420,
      "avg_latency_ms": 2.34,
      "p50_latency_ms": 1.87,
      "p95_latency_ms": 5.67,
      "p99_latency_ms": 12.45,
      "fallback_rate": 0.002,
      "error_rate": 0.0001,
      "cache_hit_rate": 0.998
    },
    "models": {
      "total_series": 285000,
      "models_in_production": 278500,
      "models_in_staging": 6200,
      "models_without_training": 6500,
      "total_versions": 3420000,
      "models_loaded_in_cache": 312,
      "canary_deployments_active": 15
    },
    "system": {
      "active_pods": 8,
      "total_memory_usage_mb": 2456.3,
      "avg_cpu_usage_percent": 42.7,
      "avg_memory_per_pod_mb": 307.0
    }
  },
  "metadata": {
    "request_id": "req_f8e7d6c5b4a39281",
    "timestamp": "2024-12-07T19:38:00Z"
  }
}
```

---

## 9. Rate Limiting

### Limites por Endpoint

**Training API:**
- `POST /api/v1/training/{series_id}`: 1 req/5min por series_id, 100 req/hora globalmente
- Outros endpoints de treinamento: 1000 req/min

**Inference API:**
- `POST /api/v1/predict/{series_id}`: 1000 req/min por series_id
- `POST /api/v1/predict/{series_id}/batch`: 100 req/min por series_id
- Global: 10.000 req/s por API key

**Administrative API:**
- Todos os endpoints: 100 req/min

**Response 429 Too Many Requests:**

```json
{
  "status": "error",
  "error": {
    "code": "RATE_LIMIT_EXCEEDED",
    "message": "Too many requests",
    "retry_after_seconds": 60,
    "limit": "1000 requests per minute",
    "current_usage": 1050
  },
  "metadata": {
    "request_id": "req_f8e7d6c5b4a39281",
    "timestamp": "2024-12-07T19:40:00Z"
  }
}
```

---

## 10. Error Handling

### Response Codes

- `200 OK`: Requisição bem-sucedida (GET, DELETE com sucesso imediato)
- `202 Accepted`: Operação assíncrona aceita (POST training, canary promotion)
- `400 Bad Request`: Erro de validação de entrada
- `401 Unauthorized`: Token JWT inválido ou ausente
- `403 Forbidden`: Token válido mas sem permissões necessárias
- `404 Not Found`: Recurso não encontrado (model, series, job)
- `409 Conflict`: Conflito de estado (job já existe, transição de estágio inválida)
- `413 Payload Too Large`: Payload excede limites
- `422 Unprocessable Entity`: Validação de negócio falhou (série constante, dados insuficientes)
- `429 Too Many Requests`: Rate limit excedido
- `500 Internal Server Error`: Erro interno do servidor
- `503 Service Unavailable`: Serviço temporariamente indisponível

### Estrutura de Erro Padrão

```json
{
  "status": "error",
  "error": {
    "code": "ERROR_CODE",
    "message": "Human-readable error message",
    "details": [
      {
        "field": "field_name",
        "issue": "specific issue description",
        "suggestion": "how to fix it"
      }
    ]
  },
  "metadata": {
    "request_id": "req_f8e7d6c5b4a39281",
    "timestamp": "2024-12-07T19:40:00Z"
  }
}
```

### Error Codes

| Code | Description |
|------|-------------|
| `INVALID_INPUT` | Validação de entrada falhou |
| `MODEL_NOT_FOUND` | Modelo não encontrado para series_id |
| `INVALID_VERSION` | Versão de modelo não existe |
| `INSUFFICIENT_DATA` | Dados de treinamento insuficientes |
| `CONSTANT_SERIES` | Série temporal tem variância zero |
| `INVALID_TIMESTAMP` | Timestamp fora de ordem ou formato inválido |
| `TRAINING_IN_PROGRESS` | Job de treinamento já em progresso |
| `TRAINING_FAILED` | Treinamento falhou |
| `CANNOT_CANCEL` | Não é possível cancelar job no estado atual |
| `INVALID_STAGE_TRANSITION` | Transição de estágio inválida |
| `PAYLOAD_TOO_LARGE` | Payload excede tamanho máximo |
| `RATE_LIMIT_EXCEEDED` | Rate limit excedido |
| `UNAUTHORIZED` | Autenticação falhou |
| `FORBIDDEN` | Sem permissões necessárias |
| `INTERNAL_ERROR` | Erro interno do servidor |

---

## 11. Versionamento da API

APIs versionadas via path: `/api/v1/...`

**Versão atual:** `v1`

**Política de deprecação:**
- Versões antigas mantidas por no mínimo 6 meses após release da nova versão
- Aviso de deprecação em headers de response: `Deprecation: true`, `Sunset: 2025-06-07`
- Documentação de migração fornecida para mudanças breaking

---

## 12. Exemplos de Uso Completos

### Exemplo 1: Fluxo Completo de Treinamento e Predição

```bash
# 1. Treinar modelo
curl -X POST "https://api.company.com/api/v1/training/sensor_001_radial" \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{
    "training_data": {
      "timestamps": [1733500000, 1733500300, ...],
      "values": [0.315, 0.298, ...]
    },
    "config": {
      "window_hours": 168,
      "algorithm": "statistical",
      "hyperparameters": {"threshold_sigma": 3.0}
    }
  }'

# Response: {"status": "success", "data": {"job_id": "abc123", ...}}

# 2. Consultar status do treinamento
curl "https://api.company.com/api/v1/training/jobs/abc123" \
  -H "Authorization: Bearer <token>"

# 3. Promover modelo para produção
curl -X POST "https://api.company.com/api/v1/models/sensor_001_radial/versions/v5/promote" \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{"strategy": "direct", "archive_existing": true}'

# 4. Fazer predição
curl -X POST "https://api.company.com/api/v1/predict/sensor_001_radial" \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{"timestamp": 1733587200, "value": 0.315}'
```

### Exemplo 2: Canary Deployment

```bash
# 1. Iniciar canary deployment
curl -X POST "https://api.company.com/api/v1/models/sensor_001_radial/versions/v6/promote" \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{
    "strategy": "canary",
    "canary_config": {
      "initial_percentage": 5,
      "increment_percentage": 15,
      "increment_interval_hours": 2,
      "rollback_on_error_rate": 0.005
    }
  }'

# Response: {"status": "success", "data": {"promotion_id": "xyz789", ...}}

# 2. Monitorar progresso
curl "https://api.company.com/api/v1/models/sensor_001_radial/promotions/xyz789" \
  -H "Authorization: Bearer <token>"

# 3. Se necessário, fazer rollback
curl -X DELETE "https://api.company.com/api/v1/models/sensor_001_radial/promotions/xyz789" \
  -H "Authorization: Bearer <token>"
```

### Exemplo 3: Administração de Cache

```bash
# 1. Verificar estatísticas de cache
curl "https://api.company.com/api/v1/admin/cache/stats" \
  -H "Authorization: Bearer <token>"

# 2. Invalidar cache de um modelo específico
curl -X DELETE "https://api.company.com/api/v1/admin/cache/sensor_001_radial" \
  -H "Authorization: Bearer <token>"

# 3. Fazer rolling restart de todos os pods
curl -X POST "https://api.company.com/api/v1/admin/reload-all" \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{
    "strategy": "rolling",
    "batch_size": 5,
    "wait_seconds": 30
  }'
```