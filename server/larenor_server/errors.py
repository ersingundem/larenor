"""Only static errors cross the HTTP boundary; never interpolate input."""


class ApiError(Exception):
    def __init__(self, code: str, status: int = 400):
        self.code = code
        self.status = status
        super().__init__(code)


class StartupError(Exception):
    """A fixed code describing a local initialization failure."""


MESSAGES = {
    "ha_migration_changed": "The selected migration source or target changed. Review it again.",
    "ha_migration_preview_invalid": "The migration preview is no longer available. Review it again.",
    "ha_migration_limit_reached": "The Home Assistant migration limit has been reached.",
    "ha_binding_changed": "The selected Home Assistant binding changed. Review it again.",
    "ha_command_conflict": "This request conflicts with a saved Home Assistant command.",
    "ha_preview_invalid": "The binding preview is no longer available. Review it again.",
    "ha_upstream_unauthorized": "Home Assistant did not authorize this observation.",
    "ha_upstream_unavailable": "The selected Home Assistant observation is unavailable.",
    "ha_projection_unsupported": "The selected Home Assistant state is unsupported.",
    "ha_limit_reached": "The Home Assistant observation limit has been reached.",
    "invalid_request": "The request is invalid.",
    "payload_too_large": "The request is too large.",
    "request_timeout": "The request timed out.",
    "invalid_credentials": "The credentials are invalid.",
    "invalid_session": "Sign in again.",
    "password_change_required": "Change the initial password to continue.",
    "password_unchanged": "Choose a different password.",
    "forbidden": "This account cannot perform that action.",
    "revision_conflict": "The saved record has changed. Read it again.",
    "vault_unavailable": "The saved configuration is unavailable.",
    "rate_limited": "Too many requests. Try again later.",
    "server_unavailable": "The service is temporarily unavailable.",
    "not_found": "The requested resource was not found.",
    "method_not_allowed": "The request method is not supported.",
    "release_conflict": "This release conflicts with an immutable published version.",
    "release_upload_expired": "Start a new release upload.",
    "release_upload_incomplete": "The APK upload is incomplete.",
    "release_verification_failed": "The APK could not be verified.",
    "release_verifier_unavailable": "The APK verifier is unavailable.",
    "release_capacity": "Release storage is at capacity.",
    "invalid_publish_credential": "The release publishing credential is invalid.",
    "last_active_admin": "At least one active administrator is required.",
    "user_limit_reached": "The user limit has been reached.",
    "username_unavailable": "This username is unavailable.",
    "self_password_reset_forbidden": "Use your account password change action.",
    "service_credentials_required": "Replace or clear credentials when changing the service address.",
    "service_limit_reached": "The service connection limit has been reached.",
    "service_unavailable": "The saved service connection is unavailable.",
    "plugin_catalog_changed": "The plugin catalog or preview authority changed. Create a new preview.",
    "plugin_preview_expired": "Create a new configuration preview.",
    "plugin_preview_limit_reached": "The configuration preview limit has been reached.",
    "plugin_storage_unavailable": "The saved plugin configuration is unavailable.",
    "plugin_worker_unavailable": "The requirements worker is not configured.",
    "plugin_job_limit_reached": "The requirements job limit has been reached.",
    "plugin_job_conflict": "This request conflicts with a previously accepted job.",
    "plugin_job_storage_unavailable": "The saved requirements jobs are unavailable.",
    "media_preparation_conflict": "This request conflicts with a saved media preparation.",
    "media_catalog_changed": "The media catalog changed. Review the preparation again.",
    "media_context_changed": "The Core or home changed. Review the preparation again.",
    "media_preparation_limit_reached": "The media preparation limit has been reached.",
    "media_preparation_storage_unavailable": "The saved media preparations are unavailable.",
    "media_inspection_conflict": "This request conflicts with a saved media inspection.",
    "media_inspection_limit_reached": "The media inspection limit has been reached.",
    "media_preparation_changed": "The media preparation changed. Review it again.",
    "media_inspection_storage_unavailable": "The saved media inspections are unavailable.",
    "media_inspection_changed": "The media inspection changed. Run it again.",
    "media_installation_conflict": "This request conflicts with a saved media installation execution.",
    "media_installation_limit_reached": "The media installation execution limit has been reached.",
    "media_installation_storage_unavailable": "The saved media installation executions are unavailable.",
    "media_installation_changed": "The media installation changed. Read it again.",
    "media_bootstrap_conflict": "This request conflicts with a saved media service bootstrap.",
    "media_bootstrap_limit_reached": "The media service bootstrap limit has been reached.",
    "media_bootstrap_storage_unavailable": "The saved media service bootstraps are unavailable.",
}


def error_body(code: str) -> dict:
    if code not in MESSAGES:
        code = "server_unavailable"
    return {"error": {"code": code, "message": MESSAGES[code]}}
