"""Actual TCP/WS shape of Frigate's trained state classification API."""

from pathlib import Path
from urllib.parse import urlsplit

from .f41_frigate_fixture import FrigateFixture


class VisualFrigateFixture(FrigateFixture):
    def __init__(self):
        super().__init__()
        self.frame = (Path(__file__).parent / 'assets/f44_frame.webp').read_bytes()
        self.attempts = []
        self.has_trained = True
        self.model_cameras = {'front': {'crop': [0.1, 0.1, 0.9, 0.9]}}
        self.training_date = '2026-09-05T11:55:00'
        self.on_frame = None
        self.on_attempt_list = None
        handler = self.server.RequestHandlerClass
        original = handler.do_GET
        owner = self

        def get(request):
            path = urlsplit(request.path).path
            if path not in {'/api/config', '/api/classification/door/dataset', '/api/classification/door/train'} and not path.startswith('/clips/'):
                return original(request)
            try:
                owner.calls.append(('GET', path))
                assert request.headers['Authorization'] == 'Bearer ' + owner.token
                if path == '/api/config':
                    request.reply({'cameras': {'front': {}, 'back': {}},
                        'semantic_search': {'enabled': True}, 'classification': {'custom': {'door': {
                            'enabled': True, 'name': 'door', 'object_config': None,
                            'threshold': 0.8, 'state_config': {'motion': True, 'interval': 1,
                                'cameras': owner.model_cameras}}}}})
                elif path.endswith('/dataset'):
                    request.reply({'categories': {'open': ['example1.webp'], 'closed': ['example2.webp']},
                        'training_metadata': {'has_trained': owner.has_trained,
                            'last_training_date': owner.training_date, 'last_training_image_count': 2,
                            'current_image_count': 2, 'new_images_count': 0, 'dataset_changed': False}})
                elif path.endswith('/train'):
                    if owner.on_attempt_list is not None:
                        owner.on_attempt_list()
                    request.reply(owner.attempts)
                else:
                    assert path.removeprefix('/clips/door/train/') in owner.attempts
                    if owner.on_frame:
                        callback, owner.on_frame = owner.on_frame, None
                        callback()
                    request.reply(owner.frame, 'application/octet-stream')
            except Exception as error:
                owner.errors.append(type(error).__name__)
                request.reply({}, status=503)
        handler.do_GET = get

    def attempt(self, seconds, state='open', confidence='0.96'):
        name = f'none-none-{seconds:.3f}-{state}-{confidence}.webp'
        self.attempts.append(name)
        return name
