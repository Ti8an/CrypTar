#!/usr/bin/env python3
import argparse
from crypsync.config import load_config
from crypsync.encrypt import archive_and_encrypt
from crypsync.cloud.yandex import YandexDisk
from crypsync.utils import normalize_path

def main():
    parser = argparse.ArgumentParser(description="CrypSync - шифрование и резервное копирование")
    parser.add_argument("folder", nargs="?", help="Папка для шифрования")
    args = parser.parse_args()

    try:
        config = load_config()
    except FileNotFoundError as e:
        print(f"❌ {e}")
        return

    folder_to_encrypt = args.folder
    if not folder_to_encrypt:
        print("❌ Не указана папка для шифрования!")
        print("Используйте:")
        print("   crypSync /полный/путь/к/папке")
        print("или")
        print("   crypSync относительный_путь_в_домашней_папке")
        return

    folder_to_encrypt = normalize_path(folder_to_encrypt)
    folder_to_store = config.get("folder_to_store", os.path.expanduser("~/crypSync_backups"))

    encrypted_file = archive_and_encrypt(folder_to_encrypt, folder_to_store)

    cloud_service = YandexDisk()
    cloud_service.upload(encrypted_file, "backups")

    print(f"✅ Backup готов: {encrypted_file}")

if __name__ == "__main__":
    main()
