import os
import subprocess


def archive_and_encrypt(folder_path, output_folder):
    folder_path = os.path.abspath(folder_path)
    os.makedirs(output_folder, exist_ok=True)

    archive_name = os.path.join(output_folder, "backup.tar.gz")
    encrypted_name = archive_name + ".gpg"

    print(f"Архивируем {folder_path} в {archive_name}...")
    subprocess.run(["tar", "-czf", archive_name, folder_path], check=True)

    print(f"Шифруем {archive_name} в {encrypted_name}...")
    subprocess.run([
        "gpg", "--batch", "--yes", "--symmetric",
        "--cipher-algo", "AES256", "-o", encrypted_name, archive_name
    ], check=True)

    return encrypted_name
