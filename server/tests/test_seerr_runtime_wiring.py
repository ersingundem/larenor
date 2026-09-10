"""The retained installation runtime owns the Seerr executor."""

from larenor_server.plugins import installation_runtime as runtime


def test_runtime_routes_seerr_bootstrap_through_owned_executor(monkeypatch):
    calls = []

    class Executor:
        def execute(self, *args, **kwargs):
            calls.append((args, kwargs))
            return "verified-seerr"

    monkeypatch.setattr(runtime, "JellyfinBootstrapExecutor", lambda *_: object())
    monkeypatch.setattr(runtime, "QbittorrentBootstrapExecutor", lambda *_: object())
    monkeypatch.setattr(runtime, "ArrBootstrapExecutor", lambda *_: object())
    monkeypatch.setattr(runtime, "SeerrBootstrapExecutor", lambda *_: Executor())

    class Operations:
        def apply(self, *_args):
            raise AssertionError()

        def reconcile(self, *_args):
            raise AssertionError()

    backend = runtime._RuntimeBackend(
        Operations(), lambda *_: object(), object(), object()
    )
    def gate():
        return True

    assert (
        backend.bootstrap_seerr("job", "plan", "private", deadline=123.0, gate=gate)
        == "verified-seerr"
    )
    assert calls == [(("job", "plan", "private"), {"deadline": 123.0, "gate": gate})]
