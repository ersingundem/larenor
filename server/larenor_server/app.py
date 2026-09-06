from typing import Annotated, Iterable
import asyncio
from contextlib import asynccontextmanager
import logging

from fastapi import APIRouter, Depends, FastAPI, Request, Response
from fastapi.exceptions import RequestValidationError
from starlette.exceptions import HTTPException
from starlette.responses import JSONResponse

from .admin.api import router as admin_router
from .auth import Principal
from .boundary import SafeBoundaryMiddleware
from .config import Settings
from .context import ContextResponse
from .core import CoreServices
from .dependencies import get_core, require_admin, require_ready_user, require_user
from .errors import ApiError, StartupError, error_body
from .legal import SourceInformation, SourceResponse, server_version
from .models import (ErrorResponse, HealthResponse, LoginRequest, LogoutRequest,
                     PasswordRequest, RefreshRequest, SessionPair, UserResponse,
                     VaultRequest, VaultResponse)
from .services.api import router as services_router
from .home_resources.api import router as home_resources_router
from .home_people.api import router as home_people_router
from .services.probe_api import router as service_probe_router
from .plugins.api import router as plugins_router
from .plugins.job_api import router as plugin_jobs_router
from .plugins.media_api import router as media_preparations_router
from .plugins.media_inspection_api import router as media_inspections_router


Core = Annotated[CoreServices, Depends(get_core)]
User = Annotated[Principal, Depends(require_user)]
ReadyUser = Annotated[Principal, Depends(require_ready_user)]
Admin = Annotated[Principal, Depends(require_admin)]


def create_app(settings: Settings, *, routers: Iterable[APIRouter] = (),
               source: SourceInformation | None = None) -> FastAPI:
    source = source or SourceInformation.from_environment()
    @asynccontextmanager
    async def lifespan(application):
        manager = application.state.core.plugin_jobs
        stop = asyncio.Event()

        async def dispatch(manager, failure_code):
            while not stop.is_set():
                try:
                    await asyncio.to_thread(manager.tick)
                except Exception:
                    # Persisted jobs remain recoverable. Never log payloads,
                    # storage exceptions or host paths from the worker.
                    logging.getLogger("larenor").error(failure_code)
                try:
                    await asyncio.wait_for(stop.wait(), timeout=1)
                except TimeoutError:
                    pass

        task = asyncio.create_task(dispatch(manager, "preflight_dispatch_unavailable")) if manager.backend is not None else None
        media = application.state.core.media_inspections
        media_task = asyncio.create_task(dispatch(media, "media_inspection_dispatch_unavailable")) if media.backend is not None else None
        application.state.media_inspection_dispatcher = media_task
        application.state.plugin_job_dispatcher = task
        try:
            yield
        finally:
            stop.set()
            if task is not None:
                # Worker IPC has one bounded deadline. Do not cancel its DB
                # receipt write or release a dispatch lock before it unwinds.
                await task
            if media_task is not None:
                await media_task

    app = FastAPI(title="Larenor Server", version=server_version(), docs_url=None,
                  redoc_url=None, openapi_url=None,
                  lifespan=lifespan,
                  license_info={"name": "GNU Affero General Public License v3.0 only",
                                "identifier": "AGPL-3.0-only"})
    app.state.core = CoreServices(settings)
    app.state.plugin_job_dispatcher = None
    app.state.media_inspection_dispatcher = None
    app.add_middleware(SafeBoundaryMiddleware)

    @app.exception_handler(ApiError)
    async def api_error(_request, error):
        return JSONResponse(error_body(error.code), status_code=error.status)

    @app.exception_handler(RequestValidationError)
    async def validation_error(_request, _error):
        return JSONResponse(error_body("invalid_request"), status_code=400)

    @app.exception_handler(HTTPException)
    async def http_error(_request, error):
        code = {404: "not_found", 405: "method_not_allowed"}.get(error.status_code, "invalid_request")
        return JSONResponse(error_body(code), status_code=error.status_code)

    router = APIRouter(prefix="/api/v1", responses={
        400: {"model": ErrorResponse, "description": "Invalid request or password policy"},
        401: {"model": ErrorResponse, "description": "Invalid credentials or expired/revoked session"},
        403: {"model": ErrorResponse, "description": "password_change_required or insufficient role"},
        408: {"model": ErrorResponse, "description": "Request body timeout"},
        409: {"model": ErrorResponse, "description": "Vault revision_conflict"},
        413: {"model": ErrorResponse, "description": "Bounded request size exceeded"},
        429: {"model": ErrorResponse, "description": "Authentication rate/concurrency limit"},
        503: {"model": ErrorResponse, "description": "Storage or service temporarily unavailable"},
    })

    @router.get("/health", tags=["Health"], response_model=HealthResponse)
    def health():
        return {"service": "larenor-server", "apiVersion": 1}

    @router.get("/source", tags=["Source and license"], response_model=SourceResponse)
    def source_information():
        return source.response()

    @router.get("/context", tags=["Core context"], response_model=ContextResponse)
    def context(_principal: ReadyUser, core: Core):
        return core.context

    @router.post("/auth/login", tags=["Authentication"], response_model=SessionPair)
    def login(body: LoginRequest, request: Request, core: Core):
        peer = request.client.host if request.client else "unknown"
        return core.auth.login(body.username, body.password, body.deviceName, peer)

    @router.post("/auth/refresh", tags=["Authentication"], response_model=SessionPair)
    def refresh(body: RefreshRequest, request: Request, core: Core):
        peer = request.client.host if request.client else "unknown"
        return core.auth.refresh(body.refreshToken, peer)

    @router.post("/auth/logout", status_code=204, tags=["Authentication"])
    def logout(principal: User, core: Core, body: LogoutRequest | None = None):
        core.auth.logout(principal, body.refreshToken if body else None)
        return Response(status_code=204)

    @router.get("/auth/me", tags=["Authentication"], response_model=UserResponse)
    def me(principal: User):
        return {"user": principal.public_user()}

    @router.post("/auth/password", tags=["Authentication"], response_model=SessionPair)
    def password(body: PasswordRequest, principal: User, core: Core):
        pair = core.auth.change_password(principal, body.currentPassword, body.newPassword)
        try:
            core.clear_inactive_bootstrap()
        except (OSError, StartupError):
            # The old bootstrap password is already invalid. Retry cleanup on
            # restart; never turn a committed password change into a lost pair.
            core.bootstrap_cleanup_pending = True
        return pair

    @router.get("/vault", tags=["Configuration vault"], response_model=VaultResponse)
    def get_vault(principal: ReadyUser, core: Core):
        return core.vault.get(principal)

    @router.put("/vault", tags=["Configuration vault"], response_model=VaultResponse)
    def put_vault(body: VaultRequest, principal: ReadyUser, core: Core):
        return core.vault.put(principal, body.expectedRevision, body.document)

    @router.get("/openapi.json", include_in_schema=False)
    def protected_openapi(_principal: Admin):
        return app.openapi()

    app.include_router(router)
    app.include_router(admin_router, prefix="/api/v1")
    app.include_router(services_router, prefix="/api/v1")
    app.include_router(home_resources_router, prefix="/api/v1")
    app.include_router(home_people_router, prefix="/api/v1")
    app.include_router(service_probe_router, prefix="/api/v1")
    app.include_router(plugins_router, prefix="/api/v1")
    app.include_router(plugin_jobs_router, prefix="/api/v1")
    app.include_router(media_preparations_router, prefix="/api/v1")
    app.include_router(media_inspections_router, prefix="/api/v1")
    for extension in routers:
        # Only routers supplied by trusted, packaged server code are supported.
        app.include_router(extension, prefix="/api/v1")
    return app
