"""Fresh managed Seerr binding and private endpoint proof."""

import copy
import json
import socket

import pytest

from larenor_server.plugins.managed_container import (
    JellyfinBindingBuilder,
    ManagedImageProof,
    ManagedNetworkProof,
    ManagedVolumeProof,
    VerifiedJellyfinResources,
    managed_container_matches,
)
from larenor_server.plugins.seerr_endpoint import (
    SeerrEndpointError,
    open_seerr_endpoint,
    prove_seerr_endpoint,
)
from test_managed_container_binding import snapshot, source


def build(container_journal_id="4" * 32):
    catalog, stack, policy = source()

    def provider(resources, volumes, component):
        image = next(
            item
            for item in resources.resources
            if item.kind == "ensure_image" and item.serviceId == "seerr"
        )
        network = resources.resources[-1]
        selected = tuple(
            item for item in volumes.resources if item.serviceId == "seerr"
        )
        return VerifiedJellyfinResources(
            resources.stackPlanHash,
            resources.planHash,
            volumes.planHash,
            resources.workerPolicyDigest,
            ManagedImageProof(
                image.resourceId,
                3,
                image.image.configDigest,
                json.dumps(
                    {"Env": ["PATH=/usr/bin"], "Volumes": {"/app/config": {}}},
                    sort_keys=True,
                    separators=(",", ":"),
                ).encode(),
            ),
            tuple(
                ManagedVolumeProof(
                    item.resourceId,
                    item.operationId,
                    4,
                    "e" * 32,
                    "f" * 32,
                    item.name,
                    item.target,
                    True,
                )
                for item in selected
            ),
            ManagedNetworkProof(
                network.resourceId,
                network.operationId,
                3,
                "1" * 32,
                "2" * 32,
                network.name,
                "3" * 64,
            ),
        )

    binding = JellyfinBindingBuilder(
        catalog, policy, container_journal_id, provider, service_id="seerr"
    )(stack)
    observed = snapshot(binding)
    observed["State"] = {
        "Status": "running",
        "Running": True,
        "Paused": False,
        "Restarting": False,
        "Dead": False,
    }
    next(iter(observed["NetworkSettings"]["Networks"].values())).update(
        IPAddress="172.28.0.5", IPPrefixLen=16, Gateway="172.28.0.1"
    )
    return stack, binding, observed


def test_seerr_builder_mounts_only_owned_appdata_without_public_port():
    _stack, binding, observed = build()
    body = json.loads(binding.specification)
    assert {item.target for item in binding.mounts} == {"/app/config"}
    assert "PortBindings" not in body["HostConfig"]
    assert set(json.loads(binding.image_configuration)["Volumes"]) == {"/app/config"}
    assert managed_container_matches(observed, binding)


def test_exact_running_container_yields_fixed_private_endpoint():
    stack, binding, observed = build()
    proof = prove_seerr_endpoint(observed, binding, stack, "5" * 64)
    assert (proof.port, proof.address) == (5055, "172.28.0.5")
    assert "172.28" not in repr(proof)


@pytest.mark.parametrize(
    "damage",
    [
        "id",
        "stopped",
        "public",
        "network",
        "extra",
    ],
)
def test_drift_never_opens_socket(damage, monkeypatch):
    stack, binding, observed = build()
    if damage == "id":
        observed["Id"] = "6" * 64
    elif damage == "stopped":
        observed["State"].update(Status="exited", Running=False)
    elif damage == "public":
        next(iter(observed["NetworkSettings"]["Networks"].values()))["IPAddress"] = (
            "8.8.8.8"
        )
    elif damage == "network":
        next(iter(observed["NetworkSettings"]["Networks"].values()))["NetworkID"] = (
            "9" * 64
        )
    else:
        observed["NetworkSettings"]["Networks"]["foreign"] = copy.deepcopy(
            next(iter(observed["NetworkSettings"]["Networks"].values()))
        )
    monkeypatch.setattr(
        socket, "socket", lambda *_: (_ for _ in ()).throw(AssertionError())
    )
    with pytest.raises(SeerrEndpointError, match="^seerr_endpoint_untrusted$"):
        open_seerr_endpoint(observed, binding, stack, "5" * 64)


class Connection:
    def __init__(self, fail=False):
        self.fail = fail
        self.calls = []
        self.closed = False

    def settimeout(self, value):
        self.calls.append(("timeout", value))

    def connect(self, value):
        self.calls.append(("connect", value))
        if self.fail:
            raise OSError()

    def close(self):
        self.closed = True


def test_opens_one_numeric_target_without_dns_or_retry(monkeypatch):
    stack, binding, observed = build()
    connection = Connection()
    monkeypatch.setattr(
        socket, "getaddrinfo", lambda *_: (_ for _ in ()).throw(AssertionError())
    )
    monkeypatch.setattr(socket, "socket", lambda *_: connection)
    opened = open_seerr_endpoint(observed, binding, stack, "5" * 64)
    assert opened.connection is connection
    assert connection.calls[-1] == ("connect", ("172.28.0.5", 5055))


def test_failure_closes_once(monkeypatch):
    stack, binding, observed = build()
    connection = Connection(True)
    monkeypatch.setattr(socket, "socket", lambda *_: connection)
    with pytest.raises(SeerrEndpointError, match="^seerr_endpoint_unavailable$"):
        open_seerr_endpoint(observed, binding, stack, "5" * 64)
    assert connection.closed
    assert len([item for item in connection.calls if item[0] == "connect"]) == 1
