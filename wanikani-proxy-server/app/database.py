import sqlite3
import os
from cryptography.fernet import Fernet
import base64
import hashlib
from pathlib import Path

# Database path
DB_PATH = Path(__file__).parent.parent / "wanikani_proxy.db"

# Encryption key (derived from a fixed salt - in production use proper key management)
SALT = b"wanikani_proxy_salt"
KEY = hashlib.sha256(SALT).digest()[:32]
FERNET_KEY = base64.urlsafe_b64encode(KEY)
cipher = Fernet(FERNET_KEY)

def get_db_connection():
    """Get database connection"""
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn

def init_db():
    """Initialize database with required tables"""
    conn = get_db_connection()
    cursor = conn.cursor()
    
    # Config table
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS config (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        )
    """)
    
    # User info table
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS user_info (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            level INTEGER DEFAULT 1,
            level_percentage INTEGER DEFAULT 0,
            started_at TEXT DEFAULT CURRENT_TIMESTAMP,
            username TEXT DEFAULT 'Local User'
        )
    """)
    
    # Initialize user info if not exists
    cursor.execute("INSERT OR IGNORE INTO user_info (id) VALUES (1)")
    
    # Assignments table
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS assignments (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            subject_id INTEGER NOT NULL,
            subject_type TEXT NOT NULL,
            level INTEGER NOT NULL,
            srs_stage INTEGER DEFAULT 0,
            available_at TEXT,
            started_at TEXT,
            passed_at TEXT,
            created_at TEXT DEFAULT CURRENT_TIMESTAMP
        )
    """)
    
    # Review statistics table
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS review_statistics (
            subject_id INTEGER PRIMARY KEY,
            subject_type TEXT NOT NULL,
            meaning_correct INTEGER DEFAULT 0,
            meaning_incorrect INTEGER DEFAULT 0,
            meaning_current_streak INTEGER DEFAULT 0,
            meaning_max_streak INTEGER DEFAULT 0,
            reading_correct INTEGER DEFAULT 0,
            reading_incorrect INTEGER DEFAULT 0,
            reading_current_streak INTEGER DEFAULT 0,
            reading_max_streak INTEGER DEFAULT 0,
            created_at TEXT DEFAULT CURRENT_TIMESTAMP
        )
    """)
    
    # Subject progress table
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS subject_progress (
            subject_id INTEGER PRIMARY KEY,
            subject_type TEXT NOT NULL,
            level INTEGER NOT NULL,
            srs_stage_name TEXT DEFAULT 'initiate',
            srs_stage INTEGER DEFAULT 0,
            unlocked_at TEXT,
            started_at TEXT,
            passed_at TEXT,
            burned_at TEXT,
            resurrected_at TEXT
        )
    """)
    
    conn.commit()
    conn.close()

def get_config(key: str) -> str | None:
    """Get configuration value"""
    conn = get_db_connection()
    cursor = conn.cursor()
    cursor.execute("SELECT value FROM config WHERE key = ?", (key,))
    row = cursor.fetchone()
    conn.close()
    
    if row:
        try:
            # Decrypt the value
            return cipher.decrypt(row["value"].encode()).decode()
        except:
            return None
    return None

def save_config(key: str, value: str):
    """Save configuration value (encrypted)"""
    conn = get_db_connection()
    cursor = conn.cursor()
    
    # Encrypt the value
    encrypted_value = cipher.encrypt(value.encode()).decode()
    
    cursor.execute("""
        INSERT OR REPLACE INTO config (key, value) 
        VALUES (?, ?)
    """, (key, encrypted_value))
    
    conn.commit()
    conn.close()

def get_user_info() -> dict:
    """Get user information"""
    conn = get_db_connection()
    cursor = conn.cursor()
    cursor.execute("SELECT * FROM user_info WHERE id = 1")
    row = cursor.fetchone()
    conn.close()
    
    if row:
        return dict(row)
    return {
        "level": 1,
        "level_percentage": 0,
        "started_at": None,
        "username": "Local User"
    }

def update_user_info(**kwargs):
    """Update user information"""
    conn = get_db_connection()
    cursor = conn.cursor()
    
    set_clause = ", ".join([f"{k} = ?" for k in kwargs.keys()])
    values = list(kwargs.values())
    
    cursor.execute(f"""
        UPDATE user_info 
        SET {set_clause}
        WHERE id = 1
    """, values)
    
    conn.commit()
    conn.close()
