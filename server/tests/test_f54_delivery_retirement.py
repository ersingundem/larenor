"""Native delivery must distinguish permanent retirement from active revision drift."""
import base64
import hashlib
import uuid

import pytest
from conftest import auth, ready


def _lease(server):
    app, client, _, clock = server
    actor = ready(server)
    scope = app.state.core.context
    root = f"/api/v1/local-notifications/{scope.coreId}/{scope.homeId}"
    subscription = client.post(root + "/subscriptions", headers=auth(actor), json={
        "schemaVersion": 1, "registrationId": uuid.uuid4().hex,
        "permission": "granted", "expiresAt": clock() + 3600,
    }).json()["subscription"]
    raw = bytes(range(32))
    credential = base64.urlsafe_b64encode(raw).decode().rstrip("=")
    lease = client.post(root + f"/subscriptions/{subscription['ref']['id']}/delivery-leases",
        headers=auth(actor), json={
            "schemaVersion": 1, "leaseId": uuid.uuid4().hex, "credential": credential,
            "credentialFingerprint": hashlib.sha256(raw).hexdigest(),
            "expectedSubscriptionRevision": subscription["revision"], "expiresAt": clock() + 1800,
        })
    assert lease.status_code == 201
    return actor, root, subscription, lease.json()["lease"], credential


@pytest.mark.parametrize("retirement", ["lease", "subscription", "permission", "expired", "logout"])
def test_current_delivery_credential_gets_permanent_retirement_without_any_events(server, retirement):
    app, client, _, clock = server
    actor, root, subscription, lease, credential = _lease(server)
    lease_path = root + f"/delivery-leases/{lease['ref']['id']}"
    if retirement == "lease":
        assert client.delete(lease_path, headers=auth(actor), params={"expectedRevision": 1}).status_code == 204
    elif retirement == "subscription":
        assert client.delete(root + f"/subscriptions/{subscription['ref']['id']}", headers=auth(actor),
                             params={"expectedRevision": 1}).status_code == 204
    elif retirement == "permission":
        assert client.put(root + f"/subscriptions/{subscription['ref']['id']}", headers=auth(actor), json={
            "schemaVersion": 1, "expectedRevision": 1, "permission": "denied", "expiresAt": clock() + 3600,
        }).status_code == 200
    elif retirement == "expired":
        clock.now += 1801
    else:
        with app.state.core.db.transaction() as connection:
            connection.execute("UPDATE session_families SET revoked_at=? WHERE id=?",
                               (clock(), actor["sessionFamilyId"]))
    result = client.get(lease_path + "/events", headers={"X-Larenor-Delivery-Credential": credential},
                        params={"expectedLeaseRevision": 1})
    assert result.status_code in {401, 410}
    assert "events" not in result.json()


def test_active_renewal_drift_remains_recoverable_and_wrong_credential_stays_rejected(server):
    _, client, _, clock = server
    actor, root, _, lease, credential = _lease(server)
    path = root + f"/delivery-leases/{lease['ref']['id']}"
    assert client.put(path, headers=auth(actor), json={
        "schemaVersion": 1, "expectedRevision": 1,
        "expectedSubscriptionRevision": 1, "expiresAt": clock() + 1600,
    }).status_code == 200
    drift = client.get(path + "/events", headers={"X-Larenor-Delivery-Credential": credential},
                       params={"expectedLeaseRevision": 1})
    assert drift.status_code == 409
    assert drift.json()["error"]["code"] == "notification_delivery_lease_changed"
    wrong = client.get(path + "/events", headers={"X-Larenor-Delivery-Credential": "A" * 43},
                       params={"expectedLeaseRevision": 1})
    assert wrong.status_code == 401
