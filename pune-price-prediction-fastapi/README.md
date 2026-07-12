# Pune Property Price Prediction

An end-to-end machine learning project that predicts residential property prices in Pune (in ₹ Lakhs) and returns a 95% confidence interval. The project ships a trained ensemble model behind a **FastAPI** inference service and a lightweight **HTML/CSS/JS frontend**.



## Features

- **FastAPI inference service** with three endpoints: `/health`, `/model/info`, `/predict`
- **Voting ensemble regressor** trained on Pune housing data with engineered location and amenity features
- **95% confidence interval** returned with every prediction
- **Static frontend** (no build step) that consumes the API
- **Pydantic v2 schemas** for typed request/response validation
- **Test script** to smoke-test all endpoints



## Project Structure

```
Pune Price Prediction Project/
├── src/
│   ├── app.py              # FastAPI application (entrypoint)
│   ├── inference.py        # predict_price() and get_model_info()
│   ├── schemas.py          # Pydantic request/response models
│   └── test_api.py         # Smoke tests for the running API
├── frontend/
│   ├── index.html          # Input form
│   ├── results.html        # Prediction results page
│   ├── script.js           # Calls the FastAPI backend
│   └── style.css
├── model/
│   ├── property_price_prediction_voting.sav   # Trained voting regressor
│   ├── all_feature_names.pkl
│   ├── feature_cols.pkl
│   ├── count_vectorizer.pkl                   # NLP vectorizer for description
│   ├── sub_area_price_map.pkl                 # Target-encoded sub-area prices
│   ├── amenities_score_price_map.pkl
│   └── interval_est.pkl                       # Confidence-interval margin
├── model_features.csv
├── model_target.npy
├── requirements.txt
└── README.md
```



## Prerequisites

- **Python 3.12.10**
- VS Code (recommended)
- A modern browser for the frontend



## Setup

Open a terminal in the **project root** (the folder that contains `src/`).

### 1. Create a virtual environment

🪟 **Windows PowerShell**
```powershell
py -3.12 -m venv .venv
.venv\Scripts\Activate.ps1
```

🪟 **Windows Cmd**
```cmd
py -3.12 -m venv .venv
.venv\Scripts\activate
```

🍎 **macOS** / 🐧 **Linux**
```bash
python3.12 -m venv .venv
source .venv/bin/activate
```

### 2. Install dependencies

```bash
pip install --upgrade pip
pip install -r requirements.txt
```

### 3. (One-time) Download NLTK data

The `inference.py` module uses NLTK for description preprocessing. If you hit a `LookupError` for `stopwords` / `punkt`, run:

```bash
python -c "import nltk; nltk.download('stopwords'); nltk.download('punkt')"
```



## Running the API

From the **project root** (not from inside `src/`):

```bash
uvicorn src.app:app --reload --host 127.0.0.1 --port 8000
```

Then open:

| URL | Purpose |
|-----|---------|
| http://127.0.0.1:8000/docs | Interactive Swagger UI |
| http://127.0.0.1:8000/health | Health check |
| http://127.0.0.1:8000/model/info | Loaded model metadata |
| http://127.0.0.1:8000/redoc | ReDoc API reference |

> ⚠️ Run uvicorn from the **project root**, not from `src/`. The imports use `from src.schemas ...`, which requires `src` to be discoverable as a package.



## Running the Frontend

The frontend is a static page with no build step.

1. Make sure the API is running on `http://127.0.0.1:8000` (the FastAPI app already enables CORS for all origins).
2. Open `frontend/index.html` directly in your browser, **or** serve it locally:

```bash
cd frontend
python -m http.server 5500
```

Then visit http://127.0.0.1:5500/index.html.



## API Reference

### `GET /health`
```json
{ "status": "API is healthy and running." }
```

### `GET /model/info`
```json
{
  "model_type": "VotingRegressor",
  "vectorizer_vocab_size": 1234,
  "interval_margin": 12.5
}
```

### `POST /predict`

**Request body** (`PropertyInput`):

| Field | Type | Description |
|-------|------|-------------|
| `property_type` | int | Number of bedrooms (e.g., 1, 2, 3) |
| `area` | float | Area in square feet |
| `sub_area` | str | Pune sub-area (e.g., `"kothrud"`, `"baner"`) |
| `description` | str (optional) | Free-text property description |
| `clubhouse`, `school`, `hospital`, `mall`, `park`, `pool`, `gym` | int (0/1) | Amenity flags |

**Example request**
```json
{
  "property_type": 3,
  "area": 2000,
  "sub_area": "baner",
  "description": "Premium 3 BHK flat with swimming pool, gym and club house",
  "clubhouse": 1, "school": 1, "hospital": 1,
  "mall": 1, "park": 1, "pool": 1, "gym": 1
}
```

**Example response** (`PriceResponse`)
```json
{
  "predicted_price": 185.42,
  "lower_bound": 172.91,
  "upper_bound": 197.93,
  "features_used": 1247
}
```

All prices are in **₹ Lakhs**.



**Example cURL Request:**
```bash
curl -X POST "[http://127.0.0.1:8000/predict](http://127.0.0.1:8000/predict)" \
     -H "Content-Type: application/json" \
     -d '{
           "property_type": 2,
           "area": 1200,
           "sub_area": "kothrud",
           "description": "Spacious 2 BHK apartment with modular kitchen",
           "clubhouse": 1, "school": 1, "hospital": 0,
           "mall": 0, "park": 1, "pool": 0, "gym": 1
         }'
```



## Smoke Testing

With the API running, in a second terminal (with the venv active):

```bash
python -m src.test_api
```

This hits `/health`, `/model/info`, and `/predict` with two sample Pune properties (Kothrud 2BHK, Baner 3BHK) and prints the responses.



## Tech Stack

- **API**: FastAPI, Uvicorn, Pydantic v2
- **ML**: scikit-learn (VotingRegressor), NumPy, joblib
- **NLP**: NLTK (stopwords, tokenization), `CountVectorizer`
- **Frontend**: Plain HTML / CSS / JavaScript (`fetch` against the FastAPI backend)



## Common Issues

| Symptom | Fix |
|---------|-----|
| `ModuleNotFoundError: No module named 'src'` | Run `uvicorn` from the **project root**, not from inside `src/`. |
| `LookupError: Resource stopwords not found` | Run the NLTK download command in the Setup section. |
| Frontend prediction fails with a CORS error | Make sure the API is running on port `8000` and accessed from the same machine. CORS is open by default in `app.py`. |
| Port `8000` already in use | Run uvicorn with a different port, e.g. `--port 8001`, and update `BASE_URL` in `frontend/script.js` and `src/test_api.py` accordingly. |


## ⚠️ Troubleshooting

* **`ModuleNotFoundError: No module named 'src'`**
  * **Cause:** You are running Uvicorn from *inside* the `src` directory.
  * **Fix:** Run `cd ..` to go back to the root project folder, then run `uvicorn src.app:app --reload`.
* **`LookupError: Resource 'punkt_tab' not found`**
  * **Cause:** NLTK recently updated its dependencies and requires `punkt_tab`.
  * **Fix:** Ensure `nltk.download('punkt_tab')` is included in your `src/inference.py` startup logic.
* **Scikit-Learn Feature Names Warning**
  * **Cause:** The model was trained on a Pandas DataFrame (with column names), but the prediction input is an unnamed NumPy array.
  * **Fix:** This is handled internally in `inference.py` by converting the inference array back to a Pandas DataFrame using the saved `all_feature_names.pkl` artifact before calling `.predict()`.


## Author

**Marcos Oliveira** — [LinkedIn](https://www.linkedin.com/in/mfilho1/) | [GitHub](https://github.com/MAOFILHO)
