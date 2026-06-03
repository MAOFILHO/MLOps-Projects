import pandas as pd
import numpy as np

def load_data(filepath):
    """Load raw customer data from CSV."""
    df = pd.read_csv(filepath)
    print(f"Loaded {len(df)} records with {len(df.columns)} columns")
    return df

def clean_data(df):
    """Handle missing values and remove duplicates."""
    initial_rows = len(df)
    df = df.drop_duplicates()
    df['total_orders'] = df['total_orders'].fillna(0)
    df['avg_delivery_rating'] = df['avg_delivery_rating'].fillna(
        df['avg_delivery_rating'].median()
    )
    print(f"Cleaned: {initial_rows} -> {len(df)} rows")
    return df

def engineer_features(df):
    """Create features for churn prediction."""
    df['orders_per_month'] = df['total_orders'] / df['months_active']
    df['is_high_value'] = (df['total_spend'] > 5000).astype(int)
    # Ensure this is on one line or properly escaped
    df['complaint_rate'] = df['total_complaints'] / df['total_orders'].clip(lower=1)
    print(f"Engineered 3 new features. Total columns: {len(df.columns)}")
    return df

if __name__ == '__main__':
    print('Preprocessing module loaded successfully.')
