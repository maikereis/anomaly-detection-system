"""
Locust tests for Ray Serve Anomaly Detection API
"""

import random
import time
from locust import HttpUser, task, constant_pacing


def now_ts() -> int:
    return int(time.time())


def normal_value(mu=25.0, sigma=5.0) -> float:
    return random.gauss(mu, sigma)


class AnomalyDetectionUser(HttpUser):
    """
    Simulates realistic mixed workload:
    - 70% single predictions (p95 < 50ms SLO)
    - 25% batch predictions (p95 < 500ms SLO)
    - 5% health checks
    """
    
    host = "http://localhost:8000"

    wait_time = constant_pacing(1.0)
    
    def on_start(self):
        self.series_ids = [f"sensor_{i:03d}" for i in range(1, 21)]

    @task(70)
    def predict_single(self):
        """Single prediction - 70% of traffic"""
        series_id = random.choice(self.series_ids)
        payload = {
            "timestamp": now_ts(),
            "value": normal_value(),
        }

        with self.client.post(
            f"/predict/{series_id}",
            json=payload,
            name="POST /predict/:id (single)",
            catch_response=True,
        ) as resp:
            if resp.status_code == 200:
                if resp.elapsed.total_seconds() > 0.050:
                    resp.success()
                else:
                    resp.success()
            else:
                resp.failure(f"HTTP {resp.status_code}")

    @task(25)
    def predict_batch(self):
        """Batch prediction - 25% of traffic"""
        series_id = random.choice(self.series_ids)
        batch_size = random.choice([25, 50, 100])
        
        base_ts = now_ts()
        data = [
            {
                "timestamp": base_ts + i,
                "value": normal_value(),
            }
            for i in range(batch_size)
        ]

        with self.client.post(
            f"/predict/{series_id}/batch",
            json={"data": data},
            name=f"POST /predict/:id/batch (n={batch_size})",
            catch_response=True,
        ) as resp:
            if resp.status_code == 200:
                latency_ms = resp.elapsed.total_seconds() * 1000
                if latency_ms > batch_size * 2:
                    resp.failure(f"Batch inefficient: {latency_ms:.0f}ms for {batch_size} points")
                else:
                    resp.success()
            else:
                resp.failure(f"HTTP {resp.status_code}")

    @task(5)
    def health_check(self):
        """Health check - 5% of traffic"""
        with self.client.get(
            "/health",
            name="GET /health",
            catch_response=True
        ) as resp:
            if resp.status_code == 200:
                data = resp.json()
                if data.get("status") == "healthy":
                    resp.success()
                else:
                    resp.failure(f"Unhealthy: {data}")
            else:
                resp.failure(f"HTTP {resp.status_code}")

class StressTestUser(HttpUser):
    """
    High-frequency load for stress testing.
    Run separately: locust -f locustfile.py StressTestUser --users 500
    """
    
    host = "http://localhost:8000"
    wait_time = constant_pacing(0.1)  # 10 RPS per user
    
    def on_start(self):
        self.series_ids = [f"sensor_{i:03d}" for i in range(1, 6)]

    @task(80)
    def predict_single(self):
        series_id = random.choice(self.series_ids)
        payload = {
            "timestamp": now_ts(),
            "value": normal_value(),
        }
        self.client.post(
            f"/predict/{series_id}",
            json=payload,
            name="POST /predict/:id (stress)",
        )

    @task(20)
    def predict_batch(self):
        series_id = random.choice(self.series_ids)
        batch_size = random.randint(50, 200)
        
        base_ts = now_ts()
        data = [
            {
                "timestamp": base_ts + i,
                "value": normal_value(),
            }
            for i in range(batch_size)
        ]
        
        self.client.post(
            f"/predict/{series_id}/batch",
            json={"data": data},
            name="POST /predict/:id/batch (stress)",
        )

class AnomalyInjectionUser(HttpUser):
    """
    Tests anomaly detection accuracy.
    Run separately to avoid polluting latency metrics.
    """
    
    host = "http://localhost:8000"
    wait_time = constant_pacing(2.0)  # 0.5 RPS per user
    
    def on_start(self):
        self.series_ids = [f"sensor_{i:03d}" for i in range(1, 11)]

    @task
    def inject_mixed(self):
        """20% anomalous, 80% normal"""
        series_id = random.choice(self.series_ids)
        
        if random.random() < 0.2:
            value = random.gauss(100.0, 10.0)  # Anomaly
        else:
            value = normal_value()  # Normal

        payload = {
            "timestamp": now_ts(),
            "value": value,
        }
        
        with self.client.post(
            f"/predict/{series_id}",
            json=payload,
            name="POST /predict/:id (anomaly-test)",
            catch_response=True,
        ) as resp:
            if resp.status_code == 200:
                _ = resp.json()
                resp.success()
            else:
                resp.failure(f"HTTP {resp.status_code}")