#!/usr/bin/env python3
"""
Teste simples do Ray Serve
"""
import requests
import json

RAY_SERVE_URL = "http://localhost:8000"  # Port-forward: kubectl port-forward svc/ray-serve 8000:8000

def test_prediction():
    """Testa predição com modelo existente"""
    print("=" * 60)
    print("TEST 1: Prediction with existing model")
    print("=" * 60)
    
    payload = {
        "timestamp": "2024-12-09T12:00:00Z",
        "value": 0.315
    }
    
    response = requests.post(
        f"{RAY_SERVE_URL}/predict/sensor_001_radial",
        json=payload
    )
    
    print(f"Status: {response.status_code}")
    result = response.json()
    print(f"Response: {json.dumps(result, indent=2)}")
    
    if response.status_code == 200:
        print(f"✅ Model source: {result.get('model_source')}")
        print(f"✅ Anomaly: {result.get('anomaly')}")
    
    assert response.status_code == 200, "Prediction failed"

def test_fallback():
    """Testa fallback com modelo inexistente"""
    print("\n" + "=" * 60)
    print("TEST 2: Fallback for non-existent model")
    print("=" * 60)
    
    payload = {
        "timestamp": "2024-12-09T12:00:00Z",
        "value": 0.315
    }
    
    response = requests.post(
        f"{RAY_SERVE_URL}/predict/sensor_999_nonexistent",
        json=payload
    )
    
    print(f"Status: {response.status_code}")
    result = response.json()
    print(f"Response: {json.dumps(result, indent=2)}")
    
    if response.status_code == 200:
        assert result.get('model_source') == 'fallback', "Should use fallback"
        assert result.get('model_version') == 'fallback', "Version should be fallback"
        print("✅ Fallback working correctly")

def test_with_version():
    """Testa com versão específica"""
    print("\n" + "=" * 60)
    print("TEST 3: Prediction with specific version")
    print("=" * 60)
    
    payload = {
        "timestamp": "2024-12-09T12:00:00Z",
        "value": 0.315
    }
    
    response = requests.post(
        f"{RAY_SERVE_URL}/predict/sensor_001_radial?version=Staging",
        json=payload
    )
    
    print(f"Status: {response.status_code}")
    result = response.json()
    print(f"Response: {json.dumps(result, indent=2)}")
    
    if response.status_code == 200:
        print(f"✅ Model version: {result.get('model_version')}")

def test_invalid_request():
    """Testa request inválido"""
    print("\n" + "=" * 60)
    print("TEST 4: Invalid request (missing fields)")
    print("=" * 60)
    
    payload = {
        "value": 0.315
        # Missing timestamp
    }
    
    response = requests.post(
        f"{RAY_SERVE_URL}/predict/sensor_001_radial",
        json=payload
    )
    
    print(f"Status: {response.status_code}")
    print(f"Response: {json.dumps(response.json(), indent=2)}")
    
    assert response.status_code == 400, "Should return 400 for invalid request"
    print("✅ Validation working correctly")

if __name__ == "__main__":
    try:
        test_prediction()
        test_fallback()
        test_with_version()
        test_invalid_request()
        
        print("\n" + "=" * 60)
        print("✅ ALL TESTS PASSED!")
        print("=" * 60)
    except Exception as e:
        print(f"\n❌ TEST FAILED: {e}")
        raise