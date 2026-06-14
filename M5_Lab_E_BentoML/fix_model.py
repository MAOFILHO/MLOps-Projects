import bentoml
import xgboost as xgb
import numpy as np

print("Registering a clean 36-column model...")
X = np.random.rand(100, 36)
y = (X.sum(axis=1) > 18).astype(int)

model = xgb.XGBClassifier(n_estimators=10, eval_metric="logloss")
model.fit(X, y)

bentoml.xgboost.save_model(
    "truck_delay_xgb",
    model,
    signatures={
        "predict": {"batchable": True, "batch_dim": 0},
        "predict_proba": {"batchable": True, "batch_dim": 0},
    }
)
print("Done!")