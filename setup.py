from setuptools import setup, find_packages

setup(
    name="CrypSync",
    version="0.1",
    packages=find_packages(),
    install_requires=[
        "rich>=13.3.0",
        "questionary>=1.10.0"
    ],
    entry_points={
        'console_scripts': [
            'crypSync = crypsync.main:main',  # CLI команда
        ],
    },
    python_requires='>=3.7',
    description="CrypSync - шифрование и резервное копирование папок",
)
