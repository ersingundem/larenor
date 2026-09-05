from typing import Annotated

from fastapi import APIRouter, Depends, Request, Response
from fastapi.responses import JSONResponse, StreamingResponse
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from starlette.concurrency import run_in_threadpool

from ..auth import Principal
from ..dependencies import require_ready_user
from ..errors import ApiError
from ..models import ErrorResponse
from .contracts import PendingRelease, PublishedRelease, ReleaseManifest, UploadedRelease
from .models import version_number
from .store import ReleaseService

publish_bearer = HTTPBearer(auto_error=False, scheme_name="ReleasePublishToken")
ReadyUser = Annotated[Principal, Depends(require_ready_user)]


def build_release_router(service: ReleaseService) -> APIRouter:
    router = APIRouter(prefix="/client/releases", tags=["Client releases"], responses={
        status: {"model": ErrorResponse, "description": description}
        for status, description in {
            400: "Invalid metadata or request", 401: "Invalid session or publishing credential",
            403: "Initial password change required", 408: "Upload timed out",
            409: "Immutable version conflict, expired upload or storage quota",
            413: "APK exceeds the declared or maximum size", 422: "APK signature or metadata verification failed",
            503: "Storage or packaged APK verifier unavailable",
        }.items()
    })

    def publisher(credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(publish_bearer)]):
        token = credentials.credentials if credentials is not None and credentials.scheme.lower() == "bearer" else None
        service.authorize_publish(token)

    @router.get("/latest", response_model=ReleaseManifest,
                responses={204: {"description": "No Client release published"}})
    def latest(_principal: ReadyUser, platform: str = "android", channel: str = "stable"):
        if platform != "android" or channel != "stable":
            raise ApiError("invalid_request")
        release = service.latest()
        return Response(status_code=204) if release is None else release

    @router.get("/{version_code}/apk", response_class=StreamingResponse, responses={
        200: {"description": "Verified signed Android package", "content": {
            "application/vnd.android.package-archive": {"schema": {"type": "string", "format": "binary"}}
        }}
    })
    def apk(version_code: int, _principal: ReadyUser):
        manifest, stream = service.open_apk(version_number(version_code))

        async def chunks():
            try:
                while chunk := await run_in_threadpool(stream.read, 65536):
                    yield chunk
            finally:
                stream.close()

        return StreamingResponse(chunks(), media_type="application/vnd.android.package-archive", headers={
            "Content-Length": str(manifest["sizeBytes"]),
            "Content-Disposition": f'attachment; filename="Larenor-Client-{version_code}.apk"',
        })

    @router.put("/{version_code}", dependencies=[Depends(publisher)],
                response_model=PendingRelease | PublishedRelease, responses={
                    201: {"model": PendingRelease, "description": "Reserved upload"}
                }, openapi_extra={"requestBody": {"required": True, "content": {
                    "application/json": {"schema": ReleaseManifest.model_json_schema()}
                }}})
    async def initialize(version_code: int, request: Request):
        try:
            raw = await request.json()
        except ValueError:
            raise ApiError("invalid_request") from None
        status, body = await run_in_threadpool(service.initialize, version_number(version_code), raw)
        return JSONResponse(body, status_code=status)

    @router.put("/{version_code}/uploads/{upload_id}/apk", dependencies=[Depends(publisher)],
                response_model=UploadedRelease, openapi_extra={"requestBody": {
                    "required": True, "description": "Raw APK bytes; redirects and compressed bodies are rejected",
                    "content": {"application/octet-stream": {"schema": {"type": "string", "format": "binary"}}}
                }})
    async def upload(version_code: int, upload_id: str, request: Request):
        return await service.receive_upload(version_number(version_code), upload_id, request)

    @router.post("/{version_code}/uploads/{upload_id}/finalize", dependencies=[Depends(publisher)],
                 response_model=ReleaseManifest)
    async def finalize(version_code: int, upload_id: str):
        return await run_in_threadpool(service.finalize, version_number(version_code), upload_id)

    return router
