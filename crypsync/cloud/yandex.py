from .base import CloudStorage
import subprocess

class YandexDisk(CloudStorage):
    def upload(self, local_file: str, remote_path: str):
        print(f"Загружаем {local_file} на Яндекс.Диск:{remote_path}...")
        subprocess.run(["rclone", "copy", local_file, f"yandex:{remote_path}"], check=True)