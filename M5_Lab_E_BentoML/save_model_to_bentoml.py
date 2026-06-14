# save_model_to_bentoml.py
import bentoml
import joblib

# Load your M3 XGBoost model. If you don't have it, see the fallback below.
model = joblib.load("xgb-truck-model.pkl")

# Save into BentoML's local store
saved = bentoml.xgboost.save_model(
    "truck_delay_xgb",        # model name in the store
    model,
    signatures={
        "predict": {"batchable": True, "batch_dim": 0},
        "predict_proba": {"batchable": True, "batch_dim": 0},
    },
    metadata={
        "source_lab": "M3 Lab C",
        "n_features": 36,
        "f1_baseline": 0.679,
    },
)

print(f"Saved: {saved}")
# Expected: Model(tag="truck_delay_xgb:abc123def...", ...)