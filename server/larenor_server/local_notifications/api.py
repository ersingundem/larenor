from typing import Annotated

from fastapi import APIRouter, Depends, Header, Query, Request, Response

from ..auth import Principal
from ..core import CoreServices
from ..dependencies import get_core, require_admin, require_ready_user
from ..errors import ApiError
from ..home_resources.models import Identity, Revision
from ..models import ErrorResponse
from .models import (
    AcknowledgeNotifications,
    AcknowledgementResponse,
    CreateNotification,
    DeliveryLeaseResponse,
    DeliveryNotificationPage,
    NotificationPage,
    NotificationResponse,
    RegisterDeliveryLease,
    RegisterSubscription,
    RenewDeliveryLease,
    SubscriptionResponse,
    UpdateSubscription,
)


Core = Annotated[CoreServices, Depends(get_core)]
Ready = Annotated[Principal, Depends(require_ready_user)]
Admin = Annotated[Principal, Depends(require_admin)]
Expected = Annotated[int, Query(ge=1, le=2**63 - 1)]
Cursor = Annotated[int, Query(ge=0, le=2**63 - 1)]
Limit = Annotated[int, Query(ge=1, le=100)]
DeliveryLimit = Annotated[int, Query(ge=1, le=50)]
Fingerprint = Annotated[
    str, Query(min_length=64, max_length=64, pattern=r"^[0-9a-f]{64}$")
]
DeliveryCredential = Annotated[
    str | None, Header(alias="X-Larenor-Delivery-Credential")
]
router = APIRouter(tags=["Local notifications"], responses={
    status: {"model": ErrorResponse} for status in (400, 401, 403, 404, 409, 410, 413, 429, 503)})
ROOT = "/local-notifications/{core_id}/{home_id}"


@router.post(ROOT + "/subscriptions", status_code=201, response_model=SubscriptionResponse)
def register(core_id: Identity, home_id: Identity, body: RegisterSubscription,
             actor: Ready, core: Core):
    return core.local_notifications.register(actor, core_id, home_id, body)


@router.put(ROOT + "/subscriptions/{subscription_id}", response_model=SubscriptionResponse)
def update(core_id: Identity, home_id: Identity, subscription_id: Identity,
           body: UpdateSubscription, actor: Ready, core: Core):
    return core.local_notifications.update(actor, core_id, home_id, subscription_id, body)


@router.delete(ROOT + "/subscriptions/{subscription_id}", status_code=204)
def revoke(core_id: Identity, home_id: Identity, subscription_id: Identity,
           expectedRevision: Expected, actor: Ready, core: Core):
    core.local_notifications.revoke(actor, core_id, home_id, subscription_id, expectedRevision)
    return Response(status_code=204)


@router.post(ROOT + "/subscriptions/{subscription_id}/delivery-leases", status_code=201,
             response_model=DeliveryLeaseResponse)
def register_delivery_lease(core_id: Identity, home_id: Identity,
                            subscription_id: Identity, body: RegisterDeliveryLease,
                            actor: Ready, core: Core):
    return core.local_notifications.register_delivery_lease(
        actor, core_id, home_id, subscription_id, body
    )


@router.get(ROOT + "/delivery-leases/{lease_id}", response_model=DeliveryLeaseResponse)
def get_delivery_lease(core_id: Identity, home_id: Identity, lease_id: Identity,
                       credentialFingerprint: Fingerprint, actor: Ready, core: Core):
    return core.local_notifications.get_delivery_lease(
        actor, core_id, home_id, lease_id, credentialFingerprint
    )


@router.put(ROOT + "/delivery-leases/{lease_id}", response_model=DeliveryLeaseResponse)
def renew_delivery_lease(core_id: Identity, home_id: Identity, lease_id: Identity,
                         body: RenewDeliveryLease, actor: Ready, core: Core):
    return core.local_notifications.renew_delivery_lease(
        actor, core_id, home_id, lease_id, body
    )


@router.delete(ROOT + "/delivery-leases/{lease_id}", status_code=204)
def revoke_delivery_lease(core_id: Identity, home_id: Identity, lease_id: Identity,
                          expectedRevision: Expected, actor: Ready, core: Core):
    core.local_notifications.revoke_delivery_lease(
        actor, core_id, home_id, lease_id, expectedRevision
    )
    return Response(status_code=204)


@router.post(ROOT + "/events", status_code=201, response_model=NotificationResponse)
def enqueue(core_id: Identity, home_id: Identity, body: CreateNotification,
            actor: Admin, core: Core):
    return core.local_notifications.enqueue(actor, core_id, home_id, body)


@router.get(ROOT + "/subscriptions/{subscription_id}/events", response_model=NotificationPage)
def events(core_id: Identity, home_id: Identity, subscription_id: Identity,
           expectedRevision: Expected, actor: Ready, core: Core,
           after: Cursor = 0, limit: Limit = 50):
    return core.local_notifications.pull(actor, core_id, home_id, subscription_id,
                                         expectedRevision, after=after, limit=limit)


@router.get(ROOT + "/delivery-leases/{lease_id}/events",
            response_model=DeliveryNotificationPage)
def delivery_events(core_id: Identity, home_id: Identity, lease_id: str,
                    expectedLeaseRevision: Expected, request: Request, core: Core,
                    credential: DeliveryCredential = None,
                    after: Cursor = 0, limit: DeliveryLimit = 50):
    if (len(request.headers.getlist("x-larenor-delivery-credential")) != 1
            or request.headers.getlist("authorization")):
        raise ApiError("invalid_notification_delivery_credential", 401)
    return core.local_notifications.pull_delivery(
        core_id, home_id, lease_id, credential, expectedLeaseRevision,
        after=after, limit=limit,
    )


@router.post(ROOT + "/subscriptions/{subscription_id}/acknowledgements",
             response_model=AcknowledgementResponse)
def acknowledge(core_id: Identity, home_id: Identity, subscription_id: Identity,
                body: AcknowledgeNotifications, actor: Ready, core: Core):
    return core.local_notifications.acknowledge(actor, core_id, home_id, subscription_id, body)
