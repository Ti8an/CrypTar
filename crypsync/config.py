import json
import os

CONFIG_FILE = os.path.expanduser("~/.crypSync_config.json")

def load_config():
    if not os.path.exists(CONFIG_FILE):
        raise FileNotFoundError(f"Конфигурационный файл не найден: {CONFIG_FILE}")
    with open(CONFIG_FILE) as f:
        return json.load(f)

def save_config(data: dict):
    with open(CONFIG_FILE, "w") as f:
        json.dump(data, f, indent=4)
    os.chmod(CONFIG_FILE, 0o600)  # безопасные права
