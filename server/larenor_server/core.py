import fcntl
import hashlib
import hmac
import os
import re
import secrets
import sqlite3
import stat
import uuid

from .admin.service import AdminService
from .automation_trials.schema import migrate_automation_trials
from .automation_trials.service import AutomationTrialService
from .automation_drafts.schema import migrate_automation_drafts
from .automation_drafts.service import AutomationDraftService
from .ai_resources.schema import migrate_ai_resources
from .ai_resources.service import AiResourceService
from .ai_memory.schema import migrate_ai_memory
from .ai_memory.service import AiMemoryService
from .evidence_diagnostics.schema import migrate_evidence_diagnostics
from .evidence_diagnostics.service import EvidenceDiagnosticService
from .habit_anomalies.schema import migrate_habit_anomalies
from .habit_anomalies.service import HabitAnomalyService
from .rule_arbitration.schema import migrate_rule_arbitration
from .rule_arbitration.service import RuleArbitrationService
from .auth import AuthService
from .bounded_transfer.blob_schema import migrate as migrate_bounded_blobs
from .bounded_transfer.events import migrate as migrate_bounded_transfer_events
from .bounded_transfer.models import TransferLimits
from .bounded_transfer.product_store import CompositeBlobProvider, ProductBlobStore
from .bounded_transfer.schema import migrate as migrate_bounded_transfers
from .bounded_transfer.service import BlobProvider, BoundedTransferService
from .component_egress.service import ComponentEgress
from .component_egress.storage import migrate as migrate_component_egress
from .config import Settings
from .context import migrate_context
from .core_backups.service import CoreBackupContract
from .core_backups.drill_schema import migrate_core_recovery_drills
from .core_backups.immutable_schema import migrate_immutable_backup_target
from .power_recovery.schema import migrate_power_recovery
from .power_recovery.service import PowerRecoveryService
from .power_recovery.proxmox_executor import (
    ProxmoxPowerRecoveryExecutor,
    StoredProxmoxPowerResolver,
)
from .core_audit import CoreAuditService, migrate as migrate_core_audit
from .database import Database
from .errors import ApiError, StartupError
from .files import (
    checked_path,
    private_create,
    private_directory,
    private_read,
    sync_directory,
)
from .home_assistant.command_chain import migrate_command_history
from .home_assistant.migration import DirectHaMigration
from .home_assistant.migration_schema import migrate as migrate_direct_ha
from .home_assistant.rule_schema import migrate as migrate_automation_rules
from .home_assistant.rules import HomeAssistantRules
from .home_assistant.schema import migrate_home_assistant
from .home_assistant.service import HomeAssistantAdapter
from .home_people.schema import migrate_home_people
from .home_people.service import HomePeopleRegistry
from .home_resources.schema import migrate_home_resources
from .home_resources.service import HomeResourceRegistry
from .home_workflows.schema import migrate_home_workflows
from .home_workflows.service import HomeWorkflowService
from .inventory.schema import migrate_inventory
from .inventory.service import InventoryRegistry
from .cooking.schema import migrate_cooking_sessions
from .cooking.service import CookingSessionStore
from .personal_channels.schema import migrate_personal_channels
from .personal_channels.service import PersonalChannelService
from .live_tv.schema import migrate_live_tv
from .live_tv.service import LiveTvService
from .pantry_stock.schema import migrate_pantry_stock
from .pantry_stock.service import PantryStockService
from .keenetic_commands.core_worker import build_keenetic_worker_effect
from .keenetic_commands.journal import KeeneticCommandJournal
from .keenetic_commands.journal import state_tag as keenetic_state_tag
from .keenetic_commands.provider import KeeneticCommandStateProvider
from .keenetic_commands.schema import migrate as migrate_keenetic_commands
from .keenetic_commands.service import KeeneticCommandAuthority
from .keenetic_resources.schema import migrate as migrate_keenetic_resources
from .keenetic_resources.service import KeeneticResourceAdapter
from .local_notifications.schema import migrate_local_notifications
from .local_notifications.service import LocalNotificationService
from .mini_plugins.schema import migrate_mini_plugins
from .mini_plugins.service import MiniPluginService
from .mcp_gateway.schema import migrate_mcp_gateway
from .mcp_gateway.service import McpGatewayService
from .support_sessions.schema import migrate_support_sessions
from .support_sessions.service import SupportSessionService
from .media_preferences.schema import migrate_jellyfin_track_preferences
from .media_preferences.service import JellyfinTrackPreferenceService
from .media_language_preferences.schema import migrate_media_language_preferences
from .media_language_preferences.service import MediaLanguagePreferenceService
from .playback_quality.service import PlaybackQualityService
from .meal_plans.repository import MealPlanRepository
from .meal_plans.schema import migrate_meal_plans
from .mesh_center.core_provider import build_core_zigbee2mqtt_provider
from .mesh_center.runtime import build_mesh_center_gateway
from .mesh_center.thread_diagnostics_service import ThreadDiagnosticsService
from .personal_profiles.repository import PersonalProfileRepository
from .personal_profiles.schema import migrate_personal_profiles
from .plugins.arr_config_job_schema import migrate_arr_configurations
from .plugins.arr_config_jobs import ArrConfigurationManagement
from .plugins.component_update_confirmations import (
    ComponentUpdateConfirmationStore,
    migrate_component_update_confirmations,
)
from .plugins.component_update_jobs import (
    ComponentUpdateJobStore,
    migrate_component_update_jobs,
)
from .plugins.component_update_preferences import (
    ComponentUpdatePreferenceStore,
    migrate_component_update_preferences,
)
from .plugins.installation_ipc import InstallationWorkerClient
from .plugins.job_schema import migrate_plugin_jobs
from .plugins.jobs import JobManagement
from .plugins.media_archive_core import MediaArchiveHealthManagement
from .plugins.media_archive_provider import MediaArchiveWorkerProvider
from .plugins.media_archive_snapshot_schema import migrate_media_archive_snapshots
from .plugins.media_archive_weekly_trend_schema import (
    migrate_media_archive_weekly_trends,
)
from .media_archive_actions import (
    MediaArchiveActionService,
    migrate_media_archive_actions,
)
from .plugins.media_account_binding_schema import migrate_media_account_bindings
from .plugins.media_account_bindings import MediaAccountBindingManagement
from .plugins.media_flow import MediaFlowManagement, MediaFlowWorkerProvider
from .plugins.media_flow_schema import migrate_media_flow
from .plugins.media_playback import (
    MediaPlaybackManagement,
    MediaPlaybackWorkerProvider,
)
from .plugins.media_playback_schema import migrate_media_playback
from .plugins.media_rows import MediaRowsManagement
from .plugins.media_inspection_schema import migrate_media_inspections
from .plugins.media_inspections import MediaInspectionManagement
from .plugins.media_installation_schema import migrate_media_installations
from .plugins.media_installations import MediaInstallationManagement
from .plugins.media_preparations import MediaPreparationManagement
from .plugins.media_recovery_status import MediaRecoveryStatusManagement
from .plugins.media_schema import migrate_media_preparations
from .plugins.media_service_bootstrap_schema import migrate_media_service_bootstraps
from .plugins.media_service_bootstraps import MediaServiceBootstrapManagement
from .plugins.music_assistant_bootstrap_job_schema import (
    migrate_music_assistant_bootstraps,
)
from .plugins.music_assistant_bootstrap_jobs import (
    MusicAssistantBootstrapManagement,
)
from .plugins.music_assistant_core import MusicAssistantCoreManagement
from .plugins.music_assistant_core_schema import migrate_music_assistant_core
from .plugins.music_playback import MusicPlaybackManagement
from .plugins.music_playback_schema import migrate_music_playback
from .party_dj.schema import migrate_party_dj
from .party_dj.service import PartyDjService
from .plugins.music_provider_command_schema import migrate_music_provider_commands
from .plugins.music_provider_commands import MusicProviderCommandManagement
from .plugins.music_provider_setup_schema import migrate_music_provider_setups
from .plugins.music_provider_setups import MusicProviderSetupManagement
from .plugins.music_retained_status import MusicRetainedStatusManagement
from .plugins.preflight_ipc import PreflightWorkerClient
from .plugins.qbittorrent_config_job_schema import migrate_qbittorrent_configurations
from .plugins.qbittorrent_config_jobs import QbittorrentConfigurationManagement
from .plugins.schema import migrate_plugins
from .plugins.seerr_bootstrap_job_schema import migrate_seerr_bootstraps
from .plugins.seerr_bootstrap_jobs import SeerrBootstrapManagement
from .plugins.service import PluginManagement
from .proxmox.schema import migrate as migrate_proxmox_resources
from .proxmox.service import ProxmoxResourceAdapter
from .proxmox_commands.core_worker import EgressGatedProxmoxExecutor
from .proxmox_commands.schema import migrate as migrate_proxmox_power
from .proxmox_commands.service import ProxmoxPowerAuthority
from .proxmox_commands.worker_ipc import verified_power_worker_client
from .services.probe_runner import ServiceProbeRunner
from .services.schema import migrate_services
from .services.service import ServiceManagement
from .sound_events.repository import SoundEventRepository
from .tablet_fleet.schema import migrate_tablet_fleet
from .tablet_fleet.service import TabletFleetService
from .capability_evidence.service import CapabilityEvidenceService
from .capability_evidence.service import migrate as migrate_capability_evidence
from .kiosk_remote.schema import migrate_kiosk_remote
from .kiosk_remote.service import KioskRemoteService
from .workshop.schema import migrate_workshop
from .workshop.provider import WorkshopHttpProvider
from .workshop.service import WorkshopService
from .watch_parties.schema import migrate_watch_parties
from .watch_parties.service import WatchPartyService
from .offline_media.schema import migrate_offline_media
from .offline_media.service import OfflineMediaService
from .longform_sessions.schema import migrate_longform_sessions
from .longform_sessions.service import LongformSessionService
from .core_backups.service import CoreBackupContract
from .core_backups.restore import recover_empty_restore
from .mesh_center.runtime import build_mesh_center_gateway
from .room_comfort.schema import migrate_room_comfort
from .room_comfort.service import RoomComfortService
from .garden_irrigation.runtime import build_irrigation_gateway
from .garden_irrigation.home_assistant import HomeAssistantIrrigationProvider
from .garden_irrigation.source_schema import migrate_irrigation_source
from .energy_priorities.service import EnergyPriorityService
from .energy_priorities.fronius import (
    FroniusReserveControl,
    migrate_fronius_reserve_control,
)
from .ev_charging.runtime import EvChargeRuntime
from .ev_charging.schema import migrate_ev_charging
from .evcc import (
    EvccBinding,
    EvccBatteryBindingStore,
    EvccConnection,
    EvccCurrentControl,
    EvccEnergyWindowStore,
    EvccRuntimeResolver,
    migrate_evcc_current_control,
    migrate_evcc_battery_bindings,
    migrate_evcc_energy_windows,
)
from .epaper_snapshots.schema import migrate_epaper_snapshots
from .epaper_snapshots.management import EpaperManagement
from .room_presence.schema import migrate_room_presence
from .room_presence.repository import RoomPresenceRepository
from .home_documents.schema import migrate_home_documents
from .home_documents.repository import HomeDocumentRepository
from .resource_reservations.schema import migrate_resource_reservations
from .resource_reservations.integration import ResourceReservationService
from .family_board.service import FamilyBoardService
from .family_memories import FamilyMemoriesService, MemoryAlbumAuthority, MemoryAlbumStore
from .family_memories.bindings import MemorySourceBindings
from .camera_search import (
    CameraSearchFeedbackService,
    migrate_camera_search_feedback,
)
from .camera_search.frigate import FrigateCameraSearchRuntime
from .camera_profiles.runtime import build_camera_profile_gateway
from .camera_profiles.ha_provider import HomeAssistantCameraProvider
from .camera_profiles.source_store import migrate_camera_provider
from .power_budget.schema import migrate_power_budget
from .power_budget.runtime import build_power_budget_gateway
from .floor_plan.schema import migrate_floor_plan
from .floor_plan.runtime import FloorPlanRuntime
from .shared_expenses import SharedExpenseService, migrate_shared_expenses
from .fair_chores import FairChoreService, migrate_fair_chores
from .game_streaming.schema import migrate_game_streaming
from .game_streaming.service import GameStreamAuthorityService
from .legacy_remote.schema import migrate_legacy_remote
from .legacy_remote.runtime import build_legacy_remote_gateway
from .camera_visual_sensors.schema import migrate_camera_visual_sensors
from .camera_visual_sensors.service import CameraVisualSensorService
from .private_event_sharing import (
    PrivateEventShareService,
    PrivateEventShareStore,
    migrate_private_event_sharing,
)
from .vault import VaultService


class CoreServices:
    def __init__(
        self,
        settings: Settings,
        *,
        blob_provider: BlobProvider | None = None,
        transfer_limits: TransferLimits | None = None,
        proxmox_guest_provider=None,
        proxmox_power_executor=None,
        media_archive_binding_reader=None,
        media_archive_worker=None,
        media_archive_action_worker=None,
        mesh_center_provider=None,
        mesh_center_observer=None,
        irrigation_provider=None,
        energy_priority_provider=None,
        energy_priority_inverter_worker=None,
        energy_priority_inverter_capability=None,
        room_comfort_worker=None,
        workshop_provider=None,
        ev_charge_provider=None,
        ev_charge_charger=None,
        camera_profile_provider=None,
        live_tv_provider=None,
        live_tv_recorder=None,
        power_budget_provider=None,
        legacy_remote_provider=None,
        power_recovery_executor=None,
        family_memory_connection_provider=None,
        family_memory_authority_provider=None,
        family_memory_policy_provider=None,
        private_event_share_authority_resolver=None,
        private_event_share_consent_resolver=None,
        private_event_share_event_reader=None,
        private_event_share_redaction_worker=None,
        private_event_share_artifact_reader=None,
    ):
        self.settings = settings
        self._blob_provider = blob_provider
        self._transfer_limits = transfer_limits
        self._proxmox_guest_provider = proxmox_guest_provider
        self._proxmox_power_executor = proxmox_power_executor
        self._media_archive_binding_reader = media_archive_binding_reader
        self._media_archive_worker = media_archive_worker
        self._media_archive_action_worker = media_archive_action_worker
        self._mesh_center_provider = mesh_center_provider
        self._mesh_center_observer = mesh_center_observer
        self._irrigation_provider = irrigation_provider
        self._energy_priority_provider = energy_priority_provider
        self._energy_priority_inverter_worker = energy_priority_inverter_worker
        self._energy_priority_inverter_capability = energy_priority_inverter_capability
        self._room_comfort_worker = room_comfort_worker
        self._workshop_provider = workshop_provider
        self._ev_charge_provider = ev_charge_provider
        self._ev_charge_charger = ev_charge_charger
        self._camera_profile_provider = camera_profile_provider
        self._live_tv_provider = live_tv_provider
        self._live_tv_recorder = live_tv_recorder
        self._power_budget_provider = power_budget_provider
        self._legacy_remote_provider = legacy_remote_provider
        self._power_recovery_executor = power_recovery_executor
        self._family_memory_connection_provider = family_memory_connection_provider
        self._family_memory_authority_provider = family_memory_authority_provider
        self._family_memory_policy_provider = family_memory_policy_provider
        self._private_event_share_authority_resolver = (
            private_event_share_authority_resolver
        )
        self._private_event_share_consent_resolver = private_event_share_consent_resolver
        self._private_event_share_event_reader = private_event_share_event_reader
        self._private_event_share_redaction_worker = private_event_share_redaction_worker
        self._private_event_share_artifact_reader = private_event_share_artifact_reader
        self.bootstrap_created = False
        self.bootstrap_cleanup_pending = False
        try:
            self._initialize()
        except StartupError:
            raise
        except (OSError, ValueError, sqlite3.Error):
            raise StartupError("storage_initialization_failed") from None

    def _family_memory_authority(self, actor):
        """Resolve the current single-home membership generation.

        The digest is only a revision token. User IDs and their revisions stay
        inside the Core and are never exposed through it.
        """
        with self.db.connection() as connection:
            rows = connection.execute(
                "SELECT id,revision FROM users "
                "WHERE disabled=0 AND must_change_password=0 ORDER BY id LIMIT 33"
            ).fetchall()
        if len(rows) > 32 or not any(row["id"] == actor.id for row in rows):
            raise ApiError("memory_authority_changed", 409)
        member_ids = tuple(row["id"] for row in rows)
        payload = b"\0".join(
            row["id"].encode("ascii") + b":" + str(row["revision"]).encode("ascii")
            for row in rows
        )
        revision = int.from_bytes(
            hmac.new(
                self._family_memory_members_key,
                b"larenor-family-memory-members-revision-v1\0" + payload,
                hashlib.sha256,
            ).digest()[:8],
            "big",
        ) & (2**63 - 1)
        return (
            MemoryAlbumAuthority(
                self.context.coreId,
                self.context.homeId,
                actor.id,
                actor.family_id,
                revision or 1,
            ),
            member_ids,
        )

    @staticmethod
    def _private_event_share_provider_unavailable(*_args):
        raise ApiError("share_unavailable", 503)

    def _initialize(self) -> None:
        settings = self.settings
        private_directory(settings.data_dir)
        checked_path(settings.key_file)
        checked_path(settings.effective_bootstrap_file)
        checked_path(settings.database_file)
        if settings.key_file.is_relative_to(settings.data_dir):
            raise StartupError("vault_key_must_be_outside_data_directory")
        lock_path = settings.data_dir / ".initialize.lock"
        try:
            private_create(lock_path, b"")
        except FileExistsError:
            private_read(lock_path, 0)
        with lock_path.open("rb") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            recover_empty_restore(settings)
            existed = settings.database_file.exists()
            initialized_marker = settings.data_dir / ".initialized"
            if not existed and initialized_marker.exists():
                raise StartupError("initialized_database_missing")
            if not settings.key_file.exists():
                if existed:
                    raise StartupError("vault_key_missing")
                private_create(settings.key_file, secrets.token_bytes(32))
            key = private_read(settings.key_file, 32)
            if len(key) != 32:
                raise StartupError("vault_key_invalid")
            # An independently backed-up DB must never silently acquire a new key.
            check = hmac.new(
                key, b"larenor-vault-key-check-v1", hashlib.sha256
            ).hexdigest()
            if existed:
                info = settings.database_file.stat()
                if info.st_nlink == 2:
                    # Recover a crash between publishing the committed DB with
                    # link(2) and removing that one initialization alias.
                    aliases = []
                    for candidate in settings.data_dir.iterdir():
                        if not re.fullmatch(
                            r"\.initialize-[0-9a-f]{32}\.sqlite3", candidate.name
                        ):
                            continue
                        entry = candidate.lstat()
                        if (
                            stat.S_ISREG(entry.st_mode)
                            and entry.st_uid == os.geteuid()
                            and entry.st_ino == info.st_ino
                            and entry.st_dev == info.st_dev
                        ):
                            aliases.append(candidate)
                    if len(aliases) == 1:
                        aliases[0].unlink()
                        sync_directory(settings.data_dir)
                        info = settings.database_file.stat()
                if (
                    info.st_uid != os.geteuid()
                    or info.st_mode & 0o777 != 0o600
                    or info.st_nlink != 1
                ):
                    raise StartupError("storage_file_not_private")
                self.db = Database(settings.database_file)
            else:
                pending_file = (
                    settings.data_dir / f".initialize-{uuid.uuid4().hex}.sqlite3"
                )
                private_create(pending_file, b"")
                self.db = Database(pending_file)
                self.db.create_schema()
            self.auth = AuthService(self.db, settings, key)
            with self.db.transaction() as connection:
                version = connection.execute(
                    "SELECT value FROM metadata WHERE key='schema_version'"
                ).fetchone()
                stored_key = connection.execute(
                    "SELECT value FROM metadata WHERE key='key_check'"
                ).fetchone()
                users = connection.execute("SELECT * FROM users").fetchall()
                if version:
                    if (
                        version["value"] not in ("1", "2", "3")
                        or not stored_key
                        or not hmac.compare_digest(stored_key["value"], check)
                        or not users
                    ):
                        raise StartupError("existing_database_invalid_or_wrong_key")
                    if version["value"] == "1":
                        self.db.migrate_v1(connection)
                else:
                    if existed or users or stored_key:
                        raise StartupError("existing_database_invalid")
                    path = settings.effective_bootstrap_file
                    if path.exists():
                        bootstrap = private_read(path, 2048).decode("ascii")
                        prefix = "username: admin\npassword: "
                        if not bootstrap.startswith(prefix) or not bootstrap.endswith(
                            "\n"
                        ):
                            raise StartupError("bootstrap_file_invalid")
                        password = bootstrap[len(prefix) : -1]
                        if len(password) != 43 or any(
                            char
                            not in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"
                            for char in password
                        ):
                            raise StartupError("bootstrap_file_invalid")
                    else:
                        password = secrets.token_urlsafe(32)
                        private_create(
                            path,
                            f"username: admin\npassword: {password}\n".encode("ascii"),
                        )
                        self.bootstrap_created = True
                    connection.execute(
                        "INSERT INTO users(id,username,role,password_hash,must_change_password,created_at) VALUES(?,?,?,?,?,?)",
                        (
                            uuid.uuid4().hex,
                            "admin",
                            "admin",
                            self.auth.hash_password(password),
                            1,
                            settings.clock(),
                        ),
                    )
                    connection.executemany(
                        "INSERT INTO metadata VALUES(?,?)",
                        [("schema_version", "2"), ("key_check", check)],
                    )
                self.context = migrate_context(connection, key)
                migrate_home_resources(connection, self.context, key)
                migrate_bounded_transfers(connection)
                migrate_bounded_transfer_events(connection, key)
                migrate_bounded_blobs(connection)
                migrate_core_recovery_drills(connection)
                migrate_immutable_backup_target(connection)
                migrate_power_recovery(connection)
                migrate_home_people(connection, self.context, key)
                migrate_meal_plans(connection)
                migrate_personal_profiles(connection)
                migrate_inventory(connection, key, self.context)
                migrate_cooking_sessions(connection)
                migrate_personal_channels(connection)
                migrate_live_tv(connection)
                migrate_pantry_stock(connection, key, self.context)
                migrate_local_notifications(connection)
                migrate_jellyfin_track_preferences(connection)
                migrate_media_language_preferences(connection)
                migrate_tablet_fleet(connection)
                migrate_ai_resources(connection)
                migrate_ai_memory(connection)
                migrate_evidence_diagnostics(connection)
                migrate_habit_anomalies(connection)
                migrate_automation_trials(connection)
                migrate_automation_drafts(connection)
                migrate_mini_plugins(connection)
                migrate_mcp_gateway(connection)
                migrate_support_sessions(connection)
                migrate_rule_arbitration(connection, key, self.context)
                migrate_capability_evidence(connection)
                migrate_room_comfort(connection)
                migrate_ev_charging(connection)
                migrate_evcc_energy_windows(connection)
                migrate_evcc_current_control(connection)
                migrate_evcc_battery_bindings(connection)
                migrate_fronius_reserve_control(connection)
                migrate_epaper_snapshots(connection)
                migrate_room_presence(connection)
                migrate_home_documents(connection)
                migrate_resource_reservations(connection)
                MemoryAlbumStore.migrate(connection)
                MemorySourceBindings.migrate(connection)
                migrate_camera_provider(connection, key, self.context.coreId, self.context.homeId)
                migrate_power_budget(connection)
                migrate_floor_plan(connection)
                migrate_shared_expenses(connection)
                migrate_fair_chores(connection)
                migrate_camera_search_feedback(connection)
                migrate_kiosk_remote(connection)
                migrate_game_streaming(connection)
                migrate_camera_visual_sensors(connection)
                migrate_private_event_sharing(connection)
                migrate_services(connection)
                migrate_irrigation_source(connection)
                migrate_core_audit(connection, key, self.context)
                migrate_workshop(connection)
                migrate_component_egress(connection, self.context, key)
                migrate_home_assistant(connection, self.context, key)
                migrate_automation_rules(connection, self.context, key)
                migrate_home_workflows(connection)
                migrate_keenetic_resources(connection, self.context, key)
                migrate_command_history(connection, self.context, key)
                migrate_direct_ha(connection, key, self.context)
                migrate_proxmox_resources(connection, self.context, key)
                migrate_plugins(connection)
                migrate_component_update_preferences(connection)
                migrate_component_update_confirmations(connection)
                migrate_component_update_jobs(connection)
                migrate_plugin_jobs(connection)
                migrate_media_preparations(connection)
                migrate_media_inspections(connection)
                migrate_media_installations(connection)
                migrate_media_service_bootstraps(connection)
                migrate_media_account_bindings(connection)
                migrate_seerr_bootstraps(connection)
                migrate_qbittorrent_configurations(connection)
                migrate_arr_configurations(connection)
                migrate_music_assistant_core(connection)
                migrate_music_assistant_bootstraps(connection)
                migrate_music_provider_setups(connection)
                migrate_music_provider_commands(connection)
                migrate_music_playback(connection)
                migrate_party_dj(connection)
                migrate_media_archive_snapshots(connection)
                migrate_media_archive_weekly_trends(connection)
                migrate_media_archive_actions(connection)
                migrate_media_flow(connection)
                migrate_media_playback(connection)
                migrate_watch_parties(connection)
                migrate_offline_media(connection)
                migrate_longform_sessions(connection)
                migrate_proxmox_power(connection, key)
                migrate_keenetic_commands(
                    connection,
                    key,
                    self.context,
                    lambda scope, chain, sequence, head: keenetic_state_tag(
                        scope, chain, sequence, head, key
                    ),
                )
                migrate_legacy_remote(connection, key, self.context)
            if not existed:
                # Only publish the DB after its complete first transaction commits.
                # Never expose an empty DB that a restart might treat as a reset.
                with self.db.connection() as connection:
                    if (
                        connection.execute(
                            "PRAGMA wal_checkpoint(TRUNCATE)"
                        ).fetchone()[0]
                        != 0
                    ):
                        raise StartupError("initial_database_checkpoint_failed")
                os.link(pending_file, settings.database_file)
                pending_file.unlink()
                sync_directory(settings.data_dir)
                self.db = Database(settings.database_file)
                self.auth.db = self.db
            # This is a stable initialization sentinel, not the migrated DB version.
            if not initialized_marker.exists():
                private_create(initialized_marker, b"larenor-schema-1\n")
            else:
                if private_read(initialized_marker, 64) != b"larenor-schema-1\n":
                    raise StartupError("initialized_marker_invalid")
            self.vault = VaultService(self.db, self.auth, settings, key)
            self.home_resources = HomeResourceRegistry(
                self.db, self.auth, settings, key, self.context
            )
            self.home_resources.validate_storage()
            self.product_blobs = ProductBlobStore(
                self.db, settings, key, self.home_resources
            )
            self.product_blobs.validate_storage()
            self.bounded_transfers = BoundedTransferService(
                self.home_resources,
                settings,
                key,
                CompositeBlobProvider(self._blob_provider, self.product_blobs),
                self._transfer_limits,
            )
            self.home_people = HomePeopleRegistry(
                self.db, self.auth, settings, key, self.context
            )
            self.home_people.validate_storage()
            self.meal_plans = MealPlanRepository(
                self.db, self.auth, settings, key, self.context, self.home_people
            )
            self.meal_plans.validate_storage()
            self.personal_profiles = PersonalProfileRepository(
                self.db, self.auth, settings, key, self.context
            )
            self.personal_profiles.validate_storage()
            self.inventory = InventoryRegistry(
                self.db,
                self.auth,
                settings,
                key,
                self.context,
                self.home_resources,
                self.product_blobs,
            )
            self.inventory.validate_storage()
            self.pantry_stock = PantryStockService(
                self.db, self.auth, settings, key, self.context
            )
            self.cooking = CookingSessionStore(self.db, self.pantry_stock)
            self.pantry_stock.validate_storage()
            self.home_documents = HomeDocumentRepository(
                self.db, self.auth, settings, key, self.context,
                self.product_blobs, self.inventory)
            self.local_notifications = LocalNotificationService(
                self.db, self.auth, settings, key, self.context
            )
            self.local_notifications.validate_storage()
            self.jellyfin_track_preferences = JellyfinTrackPreferenceService(
                self.db, self.auth, settings, key, self.context
            )
            self.jellyfin_track_preferences.validate_storage()
            self.media_language_preferences = MediaLanguagePreferenceService(
                self.db, self.auth, settings, key, self.context
            )
            self.media_language_preferences.validate_storage()
            self.playback_quality = PlaybackQualityService(
                self.db, self.auth, settings, self.context
            )
            self.tablet_fleet = TabletFleetService(
                self.db, self.auth, settings, key, self.context
            )
            self.tablet_fleet.validate_storage()
            self.ai_resources = AiResourceService(
                self.db, self.auth, settings, key, self.context
            )
            self.ai_resources.validate_storage()
            self.ai_memory = AiMemoryService(
                self.db, self.auth, settings, key, self.context
            )
            self.ai_memory.validate_storage()
            self.evidence_diagnostics = EvidenceDiagnosticService(
                self.db, self.auth, settings, key, self.context
            )
            self.evidence_diagnostics.validate_storage()
            self.habit_anomalies = HabitAnomalyService(
                self.db, self.auth, settings, key, self.context
            )
            self.habit_anomalies.validate_storage()
            self.automation_trials = AutomationTrialService(
                self.db, self.auth, settings, key, self.context
            )
            self.automation_trials.validate_storage()
            self.rule_arbitration = RuleArbitrationService(
                self.db, self.auth, settings, key, self.context
            )
            self.rule_arbitration.validate_storage()
            self.capability_evidence = CapabilityEvidenceService(
                self.db, self.auth, settings, key, self.context
            )
            self.capability_evidence.validate_storage()
            self.ev_charging = EvChargeRuntime(
                self.db, self.auth, settings, key, self.context,
                self._ev_charge_provider, self._ev_charge_charger)
            self.kiosk_remote = KioskRemoteService(
                self.db, self.auth, settings, key, self.context)
            self.kiosk_remote.validate_storage()
            self.camera_visual_sensors = CameraVisualSensorService(
                self.db, self.auth, settings, key, self.context)
            self.camera_visual_sensors.validate_storage()
            self.private_event_share_store = PrivateEventShareStore(
                self.db,
                encryption_key=hmac.new(
                    key,
                    b"larenor-private-event-share-encryption-v1",
                    hashlib.sha256,
                ).digest(),
                audit_key=hmac.new(
                    key,
                    b"larenor-private-event-share-audit-v1",
                    hashlib.sha256,
                ).digest(),
                transformation_key=hmac.new(
                    key,
                    b"larenor-private-event-share-transformation-v1",
                    hashlib.sha256,
                ).digest(),
                clock=settings.clock,
            )
            unavailable = self._private_event_share_provider_unavailable
            self.private_event_sharing = PrivateEventShareService(
                self.private_event_share_store,
                authority_resolver=(
                    self._private_event_share_authority_resolver or unavailable
                ),
                consent_resolver=(
                    self._private_event_share_consent_resolver or unavailable
                ),
                event_reader=self._private_event_share_event_reader or unavailable,
                redaction_worker=(
                    self._private_event_share_redaction_worker or unavailable
                ),
                artifact_reader=(
                    self._private_event_share_artifact_reader or unavailable
                ),
            )
            self.sound_events = SoundEventRepository(
                settings.data_dir / "sound-events.db",
                key,
                self.db,
                self.auth,
                self.context,
                settings.clock,
            )
            mesh_center_provider = self._mesh_center_provider
            if mesh_center_provider is None and self._mesh_center_observer is not None:
                mesh_center_provider = build_core_zigbee2mqtt_provider(
                    db=self.db,
                    auth=self.auth,
                    context=self.context,
                    master_key=key,
                    observer=self._mesh_center_observer,
                )
            self.mesh_center = (
                None
                if mesh_center_provider is None
                else build_mesh_center_gateway(
                    mesh_center_provider,
                    master_key=key,
                    data_dir=settings.data_dir,
                    clock=settings.clock,
                )
            )
            self.thread_diagnostics = ThreadDiagnosticsService(
                self.db,
                self.auth,
                lambda: self.services,
                self.context,
                key,
                settings.data_dir,
            )
            self.room_comfort = RoomComfortService(
                self.db,
                self.auth,
                settings,
                key,
                self.context,
                worker=self._room_comfort_worker,
            )
            self.room_comfort.validate_storage()
            irrigation_provider = self._irrigation_provider
            if irrigation_provider is None:
                irrigation_provider = HomeAssistantIrrigationProvider(
                    self.db,
                    self.auth,
                    settings,
                    key,
                    self.context,
                    lambda connection, service_id, revision: (
                        self.services._home_assistant_connection(
                            connection, service_id, revision
                        )
                    ),
                    self.home_resources,
                )
            self.irrigation = build_irrigation_gateway(
                irrigation_provider, clock=settings.clock
            )
            self.epaper = EpaperManagement(
                self.db, self.auth, settings, key, self.context)
            self.epaper.validate_storage()
            self.room_presence = RoomPresenceRepository(
                self.db, self.auth, settings, key, self.context
            )
            self.room_presence.validate_storage()
            self.resource_reservations = ResourceReservationService(
                self.db, self.auth, settings, key, self.context)
            self.family_board = FamilyBoardService(
                self.db, self.auth, settings, key, self.context)
            self.camera_profiles = (
                None
                if self._camera_profile_provider is None
                else build_camera_profile_gateway(
                    self._camera_profile_provider,
                    master_key=key,
                    clock=settings.clock,
                )
            )
            self.power_budget = (
                None
                if self._power_budget_provider is None
                else build_power_budget_gateway(
                    self._power_budget_provider,
                    database=self.db,
                    master_key=key,
                    clock=settings.clock,
                )
            )
            self.shared_expenses = SharedExpenseService(
                self.db, self.auth, settings, self.context, key
            )
            self.fair_chores = FairChoreService(
                self.db, self.auth, settings, self.context, key
            )
            self.camera_search_feedback = CameraSearchFeedbackService(
                self.db,
                hmac.new(
                    key,
                    b"larenor-camera-search-feedback-v1",
                    hashlib.sha256,
                ).digest(),
                settings.clock,
            )
            self.camera_search_feedback.validate_storage()
            self.game_streaming = GameStreamAuthorityService(
                self.db, self.auth, settings, key, self.context)
            self.game_streaming.validate_storage()
            self.core_audit = CoreAuditService(
                self.db, self.auth, key, self.context
            )
            self.admin = AdminService(
                self.db, self.auth, settings, key, self.context
            )
            self.core_backups = CoreBackupContract(
                self.db,
                self.auth,
                settings,
                context=self.context,
                encryption_key=key,
            )
            self.services = ServiceManagement(
                self.db, self.auth, settings, key, self.context
            )
            self.services.validate_storage()
            self.evcc_energy_windows = EvccEnergyWindowStore(
                self.db,
                audit_key=hmac.new(
                    key,
                    b"larenor:evcc-energy-windows:v1:audit",
                    hashlib.sha256,
                ).digest(),
                clock=settings.clock,
                services=self.services,
            )
            self.evcc_energy_windows.validate_storage()
            self.evcc_current_control = None
            self.evcc_battery_bindings = None
            evcc_runtime = None
            if (
                self._ev_charge_provider is None
                or self._power_budget_provider is None
                or self._energy_priority_provider is None
            ):
                def evcc_account_revision(actor):
                    with self.db.connection() as connection:
                        row = connection.execute(
                            "SELECT u.revision,u.disabled,u.must_change_password,"
                            "f.revoked_at,f.expires_at FROM users u "
                            "JOIN session_families f ON f.user_id=u.id "
                            "WHERE u.id=? AND f.id=?",
                            (actor.id, actor.family_id),
                        ).fetchone()
                    now = settings.clock()
                    if (
                        row is None
                        or row["disabled"]
                        or row["must_change_password"]
                        or row["revoked_at"] is not None
                        or now >= row["expires_at"]
                    ):
                        raise ValueError("evcc_actor_changed")
                    return row["revision"]

                def evcc_binding():
                    evcc_service = self.services._configured_evcc_connection()
                    if evcc_service is None:
                        return None
                    service_id, service_revision = (
                        evcc_service.id,
                        evcc_service.revision,
                    )
                    return EvccBinding(
                        core_id=self.context.coreId,
                        home_id=self.context.homeId,
                        core_revision=self.context.schemaVersion,
                        home_revision=self.context.schemaVersion,
                        account_revision=evcc_account_revision,
                        connection=EvccConnection(
                            service_id=service_id,
                            revision=service_revision,
                            base_url=evcc_service.base_url,
                            api_key=evcc_service.credentials.get("apiKey"),
                        ),
                        validate_connection=lambda: self.services._evcc_connection(
                            service_id, service_revision
                        ),
                    )

                self.evcc_battery_bindings = EvccBatteryBindingStore(
                    self.db,
                    audit_key=hmac.new(
                        key,
                        b"larenor:evcc-battery-bindings:v1:audit",
                        hashlib.sha256,
                    ).digest(),
                    clock=settings.clock,
                    services=self.services,
                    binding_resolver=evcc_binding,
                )
                self.evcc_battery_bindings.validate_storage()
                self.evcc_current_control = EvccCurrentControl(
                    self.db,
                    audit_key=hmac.new(
                        key,
                        b"larenor:evcc-current-control:v1:audit",
                        hashlib.sha256,
                    ).digest(),
                    clock=settings.clock,
                    services=self.services,
                    binding_resolver=evcc_binding,
                    energy_windows=self.evcc_energy_windows,
                )
                self.evcc_current_control.validate_storage()
                evcc_runtime = EvccRuntimeResolver(
                    evcc_binding,
                    clock=settings.clock,
                    energy_windows=self.evcc_energy_windows,
                    battery_bindings=self.evcc_battery_bindings,
                    control_authority=self.evcc_current_control,
                )
            energy_priority_provider = self._energy_priority_provider
            if energy_priority_provider is None and evcc_runtime is not None:
                energy_priority_provider = evcc_runtime.energy_priorities
            self.fronius_reserve_control = FroniusReserveControl(
                self.db,
                audit_key=hmac.new(
                    key,
                    b"larenor:fronius-reserve-control:v1:audit",
                    hashlib.sha256,
                ).digest(),
                clock=settings.clock,
                services=self.services,
                connection_resolver=lambda connection, service_id, revision: (
                    self.services._home_assistant_connection(
                        connection, service_id, revision
                    )
                ),
            )
            self.fronius_reserve_control.validate_storage()
            self.energy_priorities = EnergyPriorityService(
                self.db,
                self.auth,
                settings,
                key,
                self.context,
                energy_priority_provider,
                self._energy_priority_inverter_worker,
                self._energy_priority_inverter_capability,
                self.fronius_reserve_control,
            )
            if self._ev_charge_provider is None and evcc_runtime is not None:
                self.ev_charging = EvChargeRuntime(
                    self.db,
                    self.auth,
                    settings,
                    key,
                    self.context,
                    evcc_runtime.ev_charging,
                    self.evcc_current_control,
                )
            if self._power_budget_provider is None and evcc_runtime is not None:
                self.power_budget = build_power_budget_gateway(
                    evcc_runtime.power_budget,
                    database=self.db,
                    master_key=key,
                    clock=settings.clock,
                )
            self._family_memory_members_key = hmac.new(
                key, b"larenor-family-memory-members-v1", hashlib.sha256
            ).digest()
            self.family_memory_albums = MemoryAlbumStore(
                self.db,
                encryption_key=hmac.new(
                    key, b"larenor-family-memory-encryption-v1", hashlib.sha256
                ).digest(),
                audit_key=hmac.new(
                    key, b"larenor-family-memory-audit-v1", hashlib.sha256
                ).digest(),
                clock=settings.clock,
            )
            self.family_memory_sources = MemorySourceBindings(
                self.db, self.auth, self.services, self.context, key,
                self._family_memory_authority)
            self.family_memory_sources.validate_storage()
            self.family_memories = FamilyMemoriesService(
                self.family_memory_albums,
                self.auth,
                self._family_memory_authority_provider
                or self._family_memory_authority,
                self._family_memory_connection_provider
                or self.family_memory_sources.connection,
                self._family_memory_policy_provider
                or self.family_memory_sources.policy,
            )
            workshop_provider = (
                self._workshop_provider
                or WorkshopHttpProvider(settings.clock)
            )
            self.workshop = WorkshopService(
                self.db, self.auth, settings, key, self.context, self.services,
                provider=workshop_provider)
            self.workshop.validate_storage()
            self.component_egress = ComponentEgress(self.services, key, self.context)
            self.services.component_egress = self.component_egress
            power_executor = self._proxmox_power_executor
            worker = None
            if settings.proxmox_power_worker_socket is not None:
                worker = verified_power_worker_client(
                    settings.proxmox_power_worker_socket,
                    settings.proxmox_power_worker_health,
                    settings.proxmox_power_worker_uid,
                )
            if power_executor is None and worker is not None:
                power_executor = EgressGatedProxmoxExecutor(
                    worker, self.component_egress
                )
            self.proxmox_power = ProxmoxPowerAuthority(
                self.home_resources,
                self.auth,
                settings,
                key,
                self._proxmox_guest_provider,
                power_executor,
            )
            self.proxmox_power.store.validate_storage()
            self.proxmox_power.store.recover_incomplete()
            self.home_assistant = HomeAssistantAdapter(
                self.db,
                self.auth,
                settings,
                key,
                self.home_resources,
                self.services,
                self.rule_arbitration,
            )
            self.home_assistant.validate_storage()
            self.camera_profile_sources = HomeAssistantCameraProvider(
                self.home_assistant, self.db, key, self.context, settings.clock)
            self.camera_search_runtime = FrigateCameraSearchRuntime(
                self.home_assistant, self.services, self.camera_profile_sources.store,
                self.context, key, settings.clock)
            if self._camera_profile_provider is None:
                self.camera_profiles = build_camera_profile_gateway(
                    self.camera_profile_sources, master_key=key, clock=settings.clock)
            self.home_workflows = HomeWorkflowService(
                self.db, self.auth, settings, key,
                self.home_resources, self.home_assistant, self.local_notifications,
            )
            self.home_workflows.validate_storage()
            self.home_workflows.recover_incomplete()
            self.floor_plan = FloorPlanRuntime(
                self.db,
                self.auth,
                self.home_resources,
                self.home_assistant,
                self.context,
                key,
                settings.clock,
            )
            self.home_assistant_rules = HomeAssistantRules(self.home_assistant)
            self.home_assistant_rules.validate_storage()
            self.automation_drafts = AutomationDraftService(
                self.home_assistant_rules, settings, key
            )
            self.automation_drafts.validate_storage()
            self.mini_plugins = MiniPluginService(
                self.home_resources, settings, key
            )
            self.mini_plugins.validate_storage()
            self.mcp_gateway = McpGatewayService(
                self.home_resources, settings, key
            )
            self.mcp_gateway.validate_storage()
            self.support_sessions = SupportSessionService(
                self.home_resources, self.component_egress, settings, key
            )
            self.support_sessions.validate_storage()
            self.keenetic_resources = KeeneticResourceAdapter(
                self.db, self.auth, settings, key, self.home_resources, self.services
            )
            self.keenetic_resources.validate_storage()
            self.direct_ha_migration = DirectHaMigration(self.home_assistant)
            self.direct_ha_migration.validate_storage()
            self.proxmox = ProxmoxResourceAdapter(
                self.db, self.auth, settings, key, self.home_resources, self.services
            )
            self.proxmox.validate_storage()
            self.proxmox_power.attach_binding_reader(self.proxmox)
            recovery_executor = self._power_recovery_executor
            if recovery_executor is None and worker is not None:
                recovery_executor = ProxmoxPowerRecoveryExecutor(
                    StoredProxmoxPowerResolver(
                        self.db,
                        self.auth,
                        self.home_resources,
                        self.services,
                        self.proxmox,
                        self.component_egress,
                        self._proxmox_guest_provider,
                    ),
                    worker,
                    settings,
                )
            self.power_recovery = PowerRecoveryService(
                self.db,
                self.auth,
                settings,
                key,
                executor=recovery_executor,
            )
            self.service_probe = ServiceProbeRunner(self.services)
            self.plugins = PluginManagement(self.db, self.auth, settings, key)
            self.plugins.validate_storage()
            self.component_update_preferences = ComponentUpdatePreferenceStore(
                self.db,
                self.auth,
                settings,
                key,
                self.context,
            )
            self.component_update_preferences.validate_storage()
            self.component_update_confirmations = ComponentUpdateConfirmationStore(
                self.db,
                self.auth,
                settings,
                key,
                self.context,
            )
            self.component_update_confirmations.validate_storage()
            self.component_update_jobs = ComponentUpdateJobStore(
                self.db,
                self.auth,
                settings,
                key,
                self.context,
            )
            self.component_update_jobs.validate_storage()
            backend = (
                None
                if settings.plugin_worker_socket is None
                else PreflightWorkerClient(
                    settings.plugin_worker_socket, owner_uid=settings.plugin_worker_uid
                )
            )
            self.plugin_jobs = JobManagement(
                self.db, self.auth, settings, key, self.plugins, backend
            )
            self.plugin_jobs.validate_storage()
            self.media_preparations = MediaPreparationManagement(
                self.db, self.auth, settings, key, self.plugins, self.context
            )
            self.media_preparations.validate_storage()
            self.media_inspections = MediaInspectionManagement(
                self.db, self.auth, settings, key, self.media_preparations, backend
            )
            self.media_inspections.validate_storage()
            # Mutating execution uses a separate, future worker channel. The
            # read-only preflight socket can never be promoted implicitly.
            installation_backend = (
                None
                if settings.installation_worker_socket is None
                else InstallationWorkerClient(
                    settings.installation_worker_socket,
                    owner_uid=settings.installation_worker_uid,
                )
            )
            self.media_installations = MediaInstallationManagement(
                self.db,
                self.auth,
                settings,
                key,
                self.media_preparations,
                self.media_inspections,
                installation_backend,
            )
            self.media_installations.validate_storage()
            self.media_service_bootstraps = MediaServiceBootstrapManagement(
                self.db,
                self.auth,
                settings,
                key,
                self.media_installations,
                installation_backend,
            )
            self.media_service_bootstraps.validate_storage()
            self.media_account_bindings = MediaAccountBindingManagement(
                self.db, self.auth, key, self.media_service_bootstraps
            )
            self.media_account_bindings.validate_storage()
            self.media_service_bootstraps.account_bindings = (
                self.media_account_bindings
            )
            self.qbittorrent_configurations = QbittorrentConfigurationManagement(
                self.db,
                self.auth,
                settings,
                key,
                self.media_installations,
                installation_backend,
            )
            self.qbittorrent_configurations.validate_storage()
            self.arr_configurations = ArrConfigurationManagement(
                self.db,
                self.auth,
                settings,
                key,
                self.media_installations,
                installation_backend,
                self.qbittorrent_configurations,
            )
            self.arr_configurations.validate_storage()
            self.seerr_bootstraps = SeerrBootstrapManagement(
                self.db,
                self.auth,
                settings,
                key,
                self.media_installations,
                self.media_service_bootstraps,
                self.arr_configurations,
            )
            self.seerr_bootstraps.backend = installation_backend
            self.seerr_bootstraps.validate_storage()
            self.music_assistant_core = MusicAssistantCoreManagement(
                self.db,
                self.auth,
                settings,
                key,
                self.media_installations,
                self.services,
            )
            self.music_assistant_core.validate_storage()
            self.music_assistant_bootstraps = MusicAssistantBootstrapManagement(
                self.db,
                self.auth,
                settings,
                key,
                self.media_installations,
                self.music_assistant_core,
                installation_backend,
            )
            self.music_assistant_bootstraps.validate_storage()
            self.music_provider_setups = MusicProviderSetupManagement(
                self.db,
                self.auth,
                settings,
                key,
                self.media_installations,
                self.music_assistant_core,
                installation_backend,
            )
            self.music_provider_setups.validate_storage()
            self.music_provider_commands = MusicProviderCommandManagement(
                self.db, settings, self.music_provider_setups
            )
            self.music_retained_status = MusicRetainedStatusManagement(
                self.db,
                self.media_installations,
                self.music_assistant_core,
                self.music_provider_setups,
            )
            self.media_recovery_status = MediaRecoveryStatusManagement(
                self.db,
                self.media_installations,
                self.media_service_bootstraps,
                self.qbittorrent_configurations,
                self.arr_configurations,
                self.seerr_bootstraps,
                self.music_assistant_bootstraps,
                self.context,
            )
            self.music_playback = MusicPlaybackManagement(
                self.db,
                self.auth,
                settings,
                key,
                self.music_assistant_core,
                self.music_provider_setups,
                installation_backend,
            )
            self.music_playback.validate_storage()
            self.party_dj = PartyDjService(
                self.db, self.auth, settings, key, self.context,
                self.music_playback,
            )
            self.party_dj.validate_storage()
            archive_binding_reader = self._media_archive_binding_reader
            archive_worker = self._media_archive_worker
            archive_provider = None
            if archive_binding_reader is None and archive_worker is not None:
                archive_provider = MediaArchiveWorkerProvider(
                    self.db,
                    settings,
                    self.media_installations,
                    self.media_service_bootstraps,
                    self.qbittorrent_configurations,
                    self.arr_configurations,
                    archive_worker,
                )
                archive_provider.validate_storage()
                archive_binding_reader = archive_provider
                archive_worker = archive_provider
            self.media_archive_provider = archive_provider
            self.media_archive_health = MediaArchiveHealthManagement(
                self.db,
                self.auth,
                settings,
                self.media_installations,
                archive_binding_reader,
                archive_worker,
            )
            self.media_archive_actions = MediaArchiveActionService(
                self.db,
                self.auth,
                settings,
                key,
                self.context,
                self.media_archive_health,
            )
            if self._media_archive_action_worker is not None:
                self.media_archive_actions.bind_worker(
                    self._media_archive_action_worker
                )
            self.media_archive_actions.validate_storage()
            self.media_playback = MediaPlaybackManagement(
                self.db,
                self.auth,
                settings,
                self.media_archive_health,
                (MediaPlaybackWorkerProvider(
                    installation_backend, self.media_service_bootstraps)
                 if callable(getattr(
                     installation_backend, 'read_media_playback', None))
                 and callable(getattr(
                     installation_backend, 'execute_media_playback', None))
                 else None),
                context=self.context,
            )
            self.media_playback.validate_storage()
            self.personal_channels = PersonalChannelService(
                self.db,
                self.auth,
                settings,
                key,
                self.context,
                self.media_playback,
            )
            self.personal_channels.validate_storage()
            self.live_tv = LiveTvService(
                self.db, self.auth, settings, self.context,
                self._live_tv_provider, self._live_tv_recorder,
            )
            self.live_tv.validate_storage()
            self.watch_parties = WatchPartyService(
                self.db, self.auth, settings, key, self.context,
                self.media_playback,
            )
            self.watch_parties.validate_storage()
            self.offline_media = OfflineMediaService(
                self.db, self.auth, settings, key, self.context,
                self.media_playback,
            )
            self.offline_media.validate_storage()
            self.longform_sessions = LongformSessionService(
                self.db, self.auth, settings, key, self.context,
                self.music_playback,
            )
            self.longform_sessions.validate_storage()
            self.media_rows = MediaRowsManagement(
                self.auth,
                settings,
                self.media_account_bindings,
                self.media_service_bootstraps,
                (installation_backend
                 if callable(getattr(
                     installation_backend, 'read_media_rows', None))
                 else None),
                self.media_archive_health,
            )
            media_flow_provider = (
                MediaFlowWorkerProvider(installation_backend)
                if callable(getattr(installation_backend, "read_media_flow", None))
                else None
            )
            self.media_flow = MediaFlowManagement(
                self.db, self.auth, settings, key, media_flow_provider
            )
            self.keenetic_command_journal = KeeneticCommandJournal(
                self.db, self.auth, settings, key, self.context
            )
            self.keenetic_command_journal.validate_storage()

            def keenetic_actor_revision(actor):
                with self.db.connection() as connection:
                    self.auth.assert_current(connection, actor)
                    row = connection.execute(
                        "SELECT revision FROM users WHERE id=?", (actor.id,)
                    ).fetchone()
                    if row is None:
                        raise ValueError("missing_actor")
                    return row["revision"]

            def keenetic_authorize(actor, target, action):
                self.home_resources.authorize(
                    actor,
                    target.coreId,
                    target.homeId,
                    target.resourceId,
                    action,
                    expected_revision=target.resourceRevision,
                    expected_acl_revision=target.aclRevision,
                    expected_user_revision=keenetic_actor_revision(actor),
                )

            keenetic_effect = build_keenetic_worker_effect(
                settings, self.services, self.component_egress
            )
            self.keenetic_command_provider = KeeneticCommandStateProvider(
                self.keenetic_resources,
                authorize=keenetic_authorize,
                actor_revision=keenetic_actor_revision,
                egress=self.component_egress,
            )
            self.keenetic_commands = KeeneticCommandAuthority(
                authorize=keenetic_authorize,
                observe=self.keenetic_command_provider,
                effect=keenetic_effect,
                actor_revision=keenetic_actor_revision,
                journal=self.keenetic_command_journal,
                wall_clock=settings.clock,
            )
            self.legacy_remote_gateway = build_legacy_remote_gateway(
                self.db,
                settings,
                key,
                self.context,
                self._legacy_remote_provider,
            )
            self.clear_inactive_bootstrap()

    def clear_inactive_bootstrap(self) -> None:
        path = self.settings.effective_bootstrap_file
        if not path.exists():
            return
        with self.db.connection() as connection:
            admin = connection.execute(
                "SELECT must_change_password FROM users WHERE username='admin'"
            ).fetchone()
        if admin and not admin["must_change_password"]:
            private_read(path, 2048)
            path.unlink()
            sync_directory(path.parent)
