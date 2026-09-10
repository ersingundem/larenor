from ..errors import ApiError


def read_telemetry(_connection, _guard):
    """Packaged replacement seam. This pilot intentionally has no network client."""
    raise ApiError("keenetic_upstream_unsupported", 502)
