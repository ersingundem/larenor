from conftest import auth

from larenor_server.mesh_center.thread_diagnostics_service import (
    ThreadDatasetSummary,
    ThreadDiagnosticsBinding,
    ThreadDiagnosticsConfiguration,
    ThreadDiagnosticsSnapshot,
    ThreadRouterSummary,
    ThreadServiceOption,
)
from tests.test_f55_mesh_center_api import configured


SERVICE = "9" * 32


class _ThreadDiagnostics:
    def __init__(self, core_id, home_id):
        self.core_id = core_id
        self.home_id = home_id
        self.calls = []
        self.binding = None

    def configuration(self, actor):
        self.calls.append(("configuration", actor.id))
        return ThreadDiagnosticsConfiguration(
            schemaVersion=1,
            coreId=self.core_id,
            homeId=self.home_id,
            binding=self.binding,
            services=[ThreadServiceOption(
                schemaVersion=1,
                serviceId=SERVICE,
                serviceRevision=4,
                name="Home Assistant",
            )],
        )

    def configure(self, actor, body):
        self.calls.append(("configure", body.serviceId))
        self.binding = ThreadDiagnosticsBinding(
            schemaVersion=1,
            revision=1,
            coreId=self.core_id,
            homeId=self.home_id,
            serviceId=SERVICE,
            serviceRevision=4,
        )
        return self.binding

    def observe(self, actor, core_id, home_id):
        self.calls.append(("observe", core_id, home_id))
        return ThreadDiagnosticsSnapshot(
            schemaVersion=1,
            coreId=core_id,
            homeId=home_id,
            bindingRevision=1,
            serviceId=SERVICE,
            serviceRevision=4,
            capturedAtMs=1000,
            readOnly=True,
            datasets=[ThreadDatasetSummary(
                schemaVersion=1,
                datasetId="a" * 32,
                networkName="Home Thread",
                channel=15,
                preferred=True,
                source="otbr",
            )],
            routers=[ThreadRouterSummary(
                schemaVersion=1,
                routerId="b" * 32,
                networkName="Home Thread",
                brand="homeassistant",
                modelName="OTBR",
                threadVersion="1.3.0",
                vendorName="Home Assistant",
                unconfigured=False,
            )],
        )


def test_admin_configures_verified_service_then_reads_redacted_thread_state(server):
    client, pair, root, authority, _, _, _ = configured(server)
    service = _ThreadDiagnostics(authority.coreId, authority.homeId)
    client.app.state.core.thread_diagnostics = service
    headers = auth(pair)

    configuration = client.get(
        root + "/thread-diagnostics/configuration", headers=headers
    )
    assert configuration.status_code == 200
    assert configuration.json()["configuration"]["services"] == [{
        "schemaVersion": 1,
        "serviceId": SERVICE,
        "serviceRevision": 4,
        "name": "Home Assistant",
    }]

    configured_response = client.put(
        root + "/thread-diagnostics/configuration",
        headers=headers,
        json={
            "schemaVersion": 1,
            "expectedRevision": None,
            "serviceId": SERVICE,
            "expectedServiceRevision": 4,
        },
    )
    assert configured_response.status_code == 200
    assert configured_response.json()["binding"]["revision"] == 1

    observed = client.get(root + "/thread-diagnostics", headers=headers)
    assert observed.status_code == 200
    body = observed.json()["diagnostics"]
    assert body["readOnly"] is True
    assert body["datasets"][0]["networkName"] == "Home Thread"
    assert body["routers"][0]["modelName"] == "OTBR"
    assert "tlv" not in observed.text.lower()
    assert "token" not in observed.text.lower()
    assert [value[0] for value in service.calls] == [
        "configuration", "configuration", "configure", "observe"
    ]
