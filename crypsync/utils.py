import os

def normalize_path(path):
    if os.path.isabs(path):
        return path
    return os.path.join(os.path.expanduser("~"), path)
