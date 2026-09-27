import http.client
import json
import ssl
from urllib.parse import quote, urlsplit

from pydantic import ValidationError

from ..errors import ApiError
from .immutable_models import AppendOnlyRemoteReceipt


MAX_RECEIPT_BYTES = 32 * 1024


class RestAppendOnlyTransport:
    """Exact HTTPS append operation; this type intentionally has no delete method."""

    def __init__(self, *, timeout=30, context=None, connection_factory=None):
        self.timeout = timeout
        self.context = context or ssl.create_default_context()
        self._factory = connection_factory or http.client.HTTPSConnection

    def append(
        self,
        *,
        endpoint,
        target_id,
        object_id,
        payload,
        sha256,
        protected_until,
        write_token,
    ) -> AppendOnlyRemoteReceipt:
        parsed = urlsplit(endpoint)
        connection = self._factory(
            parsed.hostname,
            parsed.port or 443,
            timeout=self.timeout,
            context=self.context,
        )
        path = (
            "/v1/append/"
            + quote(target_id, safe="")
            + "/objects/"
            + quote(object_id, safe="")
        )
        headers = {
            "Authorization": "Bearer " + write_token,
            "Content-Type": "application/vnd.larenor.core-backup",
            "Content-Length": str(len(payload)),
            "X-Larenor-SHA256": sha256,
            "X-Larenor-Protected-Until": str(protected_until),
            "Accept": "application/json",
        }
        try:
            connection.request("POST", path, body=payload, headers=headers)
            response = connection.getresponse()
            raw = response.read(MAX_RECEIPT_BYTES + 1)
            if (
                response.status not in (200, 201)
                or len(raw) > MAX_RECEIPT_BYTES
                or response.getheader("Content-Type", "").split(";", 1)[0]
                != "application/json"
            ):
                raise ApiError("immutable_target_rejected", 503)
            receipt = AppendOnlyRemoteReceipt.model_validate(json.loads(raw))
            if (
                receipt.targetId != target_id
                or receipt.objectId != object_id
                or receipt.byteLength != len(payload)
                or receipt.sha256 != sha256
                or receipt.protectedUntil != protected_until
            ):
                raise ApiError("immutable_target_receipt_mismatch", 503)
            return receipt
        except ApiError:
            raise
        except (
            http.client.HTTPException,
            json.JSONDecodeError,
            OSError,
            TimeoutError,
            TypeError,
            UnicodeError,
            ValidationError,
            ValueError,
        ):
            raise ApiError("immutable_target_unavailable", 503) from None
        finally:
            connection.close()

