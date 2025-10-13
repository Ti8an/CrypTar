from abc import ABC, abstractmethod

class CloudStorage(ABC):
    @abstractmethod
    def upload(self, local_file: str, remote_path: str):
        pass