# service.py
import bentoml
import numpy as np
from bentoml.io import JSON, NumpyNdarray

# Load the model handle (lazy — BentoML loads on first request)
truck_delay_runner = bentoml.xgboost.get("truck_delay_xgb:latest").to_runner()

# Create the service — name it; BentoML uses this for the OpenAPI title + image name
svc = bentoml.Service(
    name="truck_delay_service",
    runners=[truck_delay_runner],
)


@svc.api(input=NumpyNdarray(dtype="float32", shape=(-1, 36)), output=JSON())
async def predict(features: np.ndarray) -> dict:
    """Return delay predictions for a batch of trips.

    Input
    -----
    features : np.ndarray shape (n_trips, 36)
        Feature matrix in the same order Lab C used during training.

    Output
    ------
    {
      "predictions": [0, 1, 0, ...],          # 0 = on-time, 1 = delayed
      "probabilities": [0.23, 0.67, 0.12, ...] # delay probability per trip
    }
    """
    probs = await truck_delay_runner.predict_proba.async_run(features)
    preds = (probs[:, 1] >= 0.5).astype(int)
    return {
        "predictions":   preds.tolist(),
        "probabilities": probs[:, 1].round(4).tolist(),
    }


@svc.api(input=JSON(), output=JSON())
async def predict_single(payload: dict) -> dict:
    """Single-trip prediction, accepts the feature dict directly.

    Input JSON example:
      {"truck_age": 12, "distance": 450, "route_avg_precip": 5.2, ...}
    """
    # Convert payload dict to feature matrix in training order
    feature_order = payload.get("_feature_order") or list(payload.keys())
    if "_feature_order" in payload:
        del payload["_feature_order"]
    x = np.array([[payload[k] for k in feature_order]], dtype="float32")

    probs = await truck_delay_runner.predict_proba.async_run(x)
    return {
        "delay_pred": int(probs[0, 1] >= 0.5),
        "delay_prob": float(probs[0, 1].round(4)),
    }