"""Only static errors cross the HTTP boundary; never interpolate input."""


class ApiError(Exception):
    def __init__(self, code: str, status: int = 400):
        self.code = code
        self.status = status
        super().__init__(code)


class StartupError(Exception):
    """A fixed code describing a local initialization failure."""


MESSAGES = {
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
}


def error_body(code: str) -> dict:
    if code not in MESSAGES:
        code = "server_unavailable"
    return {"error": {"code": code, "message": MESSAGES[code]}}
