"""HTTP contract/auth tests with a synthetic read-only worker; no host access."""

import pytest

from conftest import auth, login
from test_admin import TEMPORARY, activate, create as create_user
from test_plugin_jobs import jobs, submission


BASE = "/api/v1/admin/plugins/jobs"


@pytest.fixture
def api(server, jobs):
    app, client, _, _ = server
    app.state.core.plugin_jobs = jobs[0]
    app.openapi_schema = None
    return client


def test_exact_api_contract_capabilities_creation_events_and_cancellation(server, jobs, api):
    manager, backend, actor, pair = jobs
    headers = auth(pair)
    assert api.get(BASE + "/capabilities", headers=headers).json() == {"preflightConfigured": True, "installAvailable": False}
    body = submission(server, pair).model_dump()
    response = api.post(BASE, headers=headers, json=body)
    assert response.status_code == 202, response.text
    job = response.json()["job"]
    assert job["operation"] == "preflight" and "plan" not in job
    assert api.post(BASE, headers=headers, json=body).json() == response.json()
    assert api.get(BASE, headers=headers).json() == {"jobs": [job], "nextBefore": None}
    assert api.get(BASE + "/" + job["id"], headers=headers).json() == {"job": job}
    events = api.get(BASE + "/" + job["id"] + "/events", headers=headers).json()
    assert events == {"events": [{"sequence": 1, "code": "job_queued", "jobRevision": 1,
                                  "createdAt": "2026-09-05T12:00:00.000Z"}], "nextAfter": None}
    cancelled = api.post(BASE + "/" + job["id"] + "/cancel", headers=headers, json={"expectedRevision": 1})
    assert cancelled.status_code == 200 and cancelled.json()["job"]["state"] == "cancelled"
    assert backend.calls == []
    schema = api.get("/api/v1/openapi.json", headers=headers).json()
    assert schema["paths"][BASE]["post"]["security"] == [{"DeviceAccessToken": []}]
    assert schema["components"]["schemas"]["CreateJobRequest"]["properties"]["operation"]["const"] == "preflight"


def test_anonymous_members_and_initial_accounts_cannot_access_jobs(server, jobs, api):
    _, _, _, pair = jobs
    create_user(api, pair, "viewer", "member")
    member = activate(api, "viewer")
    create_user(api, pair, "newadmin", "admin")
    initial = login(api, "newadmin", TEMPORARY).json()
    for headers, expected in (({}, 401), (auth(member), 403), (auth(initial), 403)):
        for method, path, body in (("get", BASE, None), ("get", BASE + "/capabilities", None),
                                   ("post", BASE, submission(server, pair).model_dump())):
            response = getattr(api, method)(path, headers=headers, **({"json": body} if body else {}))
            assert response.status_code == expected, response.text


def test_any_current_admin_can_inspect_and_cancel_but_not_rebind_preview(server, jobs, api):
    _, _, _, pair = jobs
    create_user(api, pair, "operator", "admin")
    other = activate(api, "operator")
    body = submission(server, pair).model_dump()
    assert api.post(BASE, headers=auth(other), json=body).status_code == 404
    job = api.post(BASE, headers=auth(pair), json=body).json()["job"]
    assert api.get(BASE + "/" + job["id"], headers=auth(other)).json() == {"job": job}
    assert api.post(BASE + "/" + job["id"] + "/cancel", headers=auth(other), json={"expectedRevision": 1}).json()["job"]["state"] == "cancelled"


@pytest.mark.parametrize("change", [{"operation": "install"}, {"command": "synthetic-secret"},
                                    {"requestId": "not-an-id"}, {"expectedRevision": True},
                                    {"expectedRevision": "1"}, {"planHash": "xyz"}])
def test_unsupported_requests_are_static_errors(server, jobs, api, change):
    body = submission(server, jobs[3]).model_dump() | change
    response = api.post(BASE, headers=auth(jobs[3]), json=body)
    assert response.status_code == 400 and response.json()["error"]["code"] == "invalid_request"
    assert "synthetic-secret" not in response.text


@pytest.mark.parametrize("suffix", ["?before=0", "?limit=101", "?limit=true", "/invalid", "/" + "a" * 32 + "/events?after=-1"])
def test_bad_paging_and_identifiers_fail_without_input_echo(server, jobs, api, suffix):
    response = api.get(BASE + suffix, headers=auth(jobs[3]))
    assert response.status_code == 400
