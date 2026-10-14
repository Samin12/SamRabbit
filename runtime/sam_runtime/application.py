from __future__ import annotations

from collections.abc import Callable
from pathlib import Path
from .api.events import RuntimeEventStream
from .api.http_server import RuntimeHttpServer
from .config import RuntimeConfig
from .core.release_supervisor import ReleaseSupervisor
from .core.runtime_environment import agent_runtime_status, standard_library_status
from .security.pairing import PairingAuthority
from .security.credentials import ConnectionCredentialEnvelopes, ProviderCredentials
from .providers.controller import ProviderController
from .mcp import LocalMcpServer, McpLifecycle
from .storage.database import RuntimeDatabase
from .storage.agent_audiences import AgentAudienceRepository
from .storage.lifecycle_repository import LifecycleRepository
from .storage.provider_settings import ProviderSettingsRepository
from .storage.profile_settings import UserProfileRepository
from .storage.sessions import SessionTranscriptRepository
from .storage.memory import MemoryRepository
from .storage.skills import SkillCatalogRepository
from .agents import AgentAudience, AgentAudienceRouter, AgentsSdkTextRunner, MemoryReviewRunner
from .agents.context_builder import PrimaryContextBuilder
from .memory.evidence import VoiceToolEvidenceRecorder
from .memory.pipeline import MemoryPipeline
from .memory.service import MemoryService
from .memory.session_context import SessionContextBuilder
from .memory.tools import MemoryLookupTool, MemoryToolPackage
from .providers.openai import OpenAISubscription
from .storage.provider_catalog import ProviderCatalogRepository
from .core.logging import runtime_logger
from .tools import (DEVICE_STATUS_TOOL_SET, MEMORY_TOOL_SET, ToolCatalog,
                    register_device_status, register_memory_tools)
from .skills import SkillActivation, AgentInstructionDocuments
from .skills.lifecycle import SkillLifecycle
from .api.skill_routes import SkillRoutes
from .api.mail_routes import MailRoutes
from .api.calendar_routes import CalendarRoutes
from .api.mcp_routes import McpRoutes
from .api.tool_routes import ToolRoutes
from .api.plugin_routes import PluginRoutes
from .plugins.archives import PluginArchiveInspector
from .plugins.lifecycle import PluginLifecycle
from .plugins.card_lifecycle import PluginCardLifecycle
from .storage.plugins import PluginCatalogRepository
from .storage.plugin_components import PluginComponentRepository
from .imports import ImportRecovery
from .api.creation_routes import CreationRoutes
from .creations import CreationArchiveInspector, CreationDescriptorInspector, CreationLifecycle
from .storage.creations import CreationCatalogRepository
from .domains.mail.connector import ImapSmtpConnector
from .domains.mail.repository import MailRepository
from .domains.mail.scheduler import MailSyncScheduler
from .domains.mail.service import MailService
from .domains.mail.tools import MAIL_TOOL_SET, register_mail_tools
from .domains.calendar.repository import CalendarRepository
from .domains.calendar.scheduler import CalendarSyncScheduler
from .domains.calendar.service import CalendarService
from .domains.calendar.google_bridge import GoogleCalendarBridge
from .connectors.calendar import CaldavCalendarProviderClient, IcsCalendarProviderClient
from .tools.calendar import CALENDAR_TOOL_SET, CalendarToolPackage
from .domains.tasks import TaskRepository, TaskService
from .tools.tasks import TASKS_TOOL_SET, TasksToolPackage
from .api.task_routes import TaskRoutes
from .storage.connection_credentials import ConnectionCredentialRepository
from .storage.mcp_connections import McpConnectionRepository
from .connections.records import ConnectionRepository
from .providers.openai.web_search import OpenAIWebSearch
from .tools.web_search import WEB_SEARCH_TOOL_SET, register_web_search
from .tools.delegation import GOAL_TOOL_SET, register_goal_tools
from .tools.genui import register_genui_tools
from .realtime import VoiceModeService, register_voice_mode_tool
from .api.connection_routes import ConnectionRoutes
from .plugins.bundled_install import BundledPluginInstaller
from .storage.agent_runs import AgentRunRepository
from .storage.background_agent_settings import BackgroundAgentSettingsRepository
from .api.background_agent_routes import BackgroundAgentRoutes
from .background_agent.composition import BackgroundRunFactory
from .background_agent.mcp_gateway import BackgroundMcpGateway
from .background_agent.service import BackgroundAgentService
from .background_agent.completion_dispatch import CompletionDispatcher
from .storage.agent_deliveries import AgentRunDeliveryRepository
from .background_agent.workspace import RunWorkspaceRegistry
from .storage.workspace import WorkspaceRepository
from .workspace.service import DurableWorkspace
from .workspace.tools import WORKSPACE_TOOL_SET, register_workspace_tools
from .storage.announcements import AnnouncementRepository
from .api.announcement_routes import AnnouncementRoutes
from .domains.t3 import T3Repository, T3Service, T3SyncWorker
from .domains.t3.tools import T3_TOOL_SET, register_t3_tools
from .domains.t3.voice import T3VoiceContext
from .domains.t3.placement import OrchestrationSetting, ProjectPlacement
from .api.t3_routes import T3Routes
from .domains.mac import MAC_TOOL_SET, GoogleAccountSetting, MacControlClient, MacVoiceContext, register_mac_tools
from .api.mac_routes import MacRoutes
from .domains.generated_ui import (GENERATED_UI_TOOL_SET, ArtifactWatcher, GeneratedUiClient,
                                   GeneratedUiVoiceContext, register_generated_ui_tools)
from .api.generated_ui_routes import GeneratedUiRoutes
from .domains.heptabase_journal import JOURNAL_TOOL_SET, HeptabaseJournalService, register_journal_tools
from .api.heptabase_routes import HeptabaseRoutes
from .domains.conversation_sync import ConversationSyncObserver, ConversationSyncService
from .api.conversation_sync_routes import ConversationSyncRoutes
from .domains.capture import CaptureBridgeClient, CaptureService
from .api.capture_routes import CaptureRoutes
from .domains.briefing import (BRIEFING_TOOL_SET, BriefingBridgeClient, BriefingService, BriefingVoiceContext,
                               register_briefing_tools)
from .api.briefing_routes import BriefingRoutes


class RuntimeApplication:
    def __init__(
        self,
        config: RuntimeConfig,
        credential_bridge: object,
        restart_request: object | None = None,
    ) -> None:
        self._config = config
        self._database = RuntimeDatabase(config.database_path)
        self._audience_router = AgentAudienceRouter(AgentAudienceRepository(self._database))
        self._lifecycle = LifecycleRepository(self._database)
        self._events = RuntimeEventStream()
        self._pairing = PairingAuthority()
        self._releases = ReleaseSupervisor(config.releases_path)
        credentials = ProviderCredentials(credential_bridge)
        connection_envelopes = ConnectionCredentialEnvelopes(credential_bridge)
        provider_settings = ProviderSettingsRepository(self._database)
        self._profile = UserProfileRepository(self._database)
        self._subscription = OpenAISubscription(credentials)
        self._catalog = ProviderCatalogRepository(self._database)
        self._sessions = SessionTranscriptRepository(self._database)
        self._memories = MemoryRepository(self._database)
        self._skills = SkillCatalogRepository(self._database)
        import_recovery = ImportRecovery(self._database)
        self._plugins = PluginCatalogRepository(self._database)
        self._plugin_components = PluginComponentRepository(self._database)
        self._skill_activation = SkillActivation(
            self._skills,
            self._audience_router,
            self._plugins,
            self._plugin_components,
        )
        self._skill_lifecycle = SkillLifecycle(
            catalog=self._skills,
            audiences=self._audience_router,
            skills_root=config.skills_path,
            rollback_root=config.skill_rollback_path,
            recovery=import_recovery,
        )
        self._session_context_builder = SessionContextBuilder(
            sessions=self._sessions,
            memories=self._memories,
        )
        self._memory_lookup_tool = MemoryLookupTool(
            memories=self._memories,
            credentials=credentials,
            safety_source=config.local_api_token,
            settings=provider_settings,
            subscription=self._subscription,
        )
        self._voice_modes = VoiceModeService()
        self._tools = ToolCatalog(audience_router=self._audience_router)
        self._tools.set_invocation_authorizer(self._voice_modes.allows)
        self._tools.set_invocation_observer(VoiceToolEvidenceRecorder(self._sessions))
        register_device_status(self._tools, self.health)
        register_memory_tools(self._tools, MemoryToolPackage(
            lookup=self._memory_lookup_tool,
            memories=self._memories,
            sessions=self._sessions,
        ))
        self._tools.register(self._skill_activation.tool_definition())
        self._mail_repository = MailRepository(self._database)
        self._mail_service = MailService(
            self._mail_repository,
            ConnectionCredentialRepository(self._database),
            connection_envelopes,
            ImapSmtpConnector(),
        )
        self._mail_scheduler = MailSyncScheduler(self._mail_repository, self._mail_service)
        self._mail_routes = MailRoutes(self._mail_repository, self._mail_service)
        self._calendar_repository = CalendarRepository(self._database)
        self._calendar_service = CalendarService(
            self._calendar_repository,
            ConnectionCredentialRepository(self._database),
            connection_envelopes,
            IcsCalendarProviderClient(),
            CaldavCalendarProviderClient(),
        )
        self._calendar_scheduler = CalendarSyncScheduler(self._calendar_repository, self._calendar_service)
        self._calendar_routes = CalendarRoutes(self._calendar_repository, self._calendar_service)
        CalendarToolPackage(self._calendar_service).register(self._tools)
        self._task_repository = TaskRepository(self._database)
        self._task_service = TaskService(self._task_repository)
        self._task_routes = TaskRoutes(self._task_repository)
        TasksToolPackage(self._task_service).register(self._tools)
        self._connections = ConnectionRepository(self._database)
        self._connection_routes = ConnectionRoutes(self._connections)
        self._heptabase_journal = HeptabaseJournalService(
            database=self._database,
            credentials=ConnectionCredentialRepository(self._database),
            envelopes=connection_envelopes,
            sessions=self._sessions,
            connections=self._connections,
        )
        self._heptabase_routes = HeptabaseRoutes(self._heptabase_journal)
        # Google Calendar changes from Voice: the same Mac bridge (Composio on the Mac) writes behind the iCal feed.
        self._calendar_service.use_google_bridge(GoogleCalendarBridge(self._heptabase_journal.bridge_store),
                                                 timezone_name=lambda: self._heptabase_journal.settings().timezone)
        # Conversation sync to the Mac app: same bridge pairing as the journal and Mac control.
        self._conversation_sync = ConversationSyncService(self._database, self._heptabase_journal.bridge_store)
        self._tools.add_invocation_observer(ConversationSyncObserver(self._conversation_sync))
        self._conversation_sync_routes = ConversationSyncRoutes(self._conversation_sync)
        register_journal_tools(self._tools, self._heptabase_journal)
        register_mail_tools(self._tools, self._mail_repository, self._mail_service)
        register_web_search(self._tools, OpenAIWebSearch(credentials, provider_settings, self._subscription))
        self._announcements = AnnouncementRepository(
            self._database,
            on_publish=lambda item: self._events.publish(item.kind, item.view()),
        )
        self._announcement_routes = AnnouncementRoutes(self._announcements)
        self._t3 = T3Service(T3Repository(self._database), connection_envelopes, announcements=self._announcements)
        self._t3_sync = T3SyncWorker(self._t3)
        self._t3_placement = ProjectPlacement(self._t3, OrchestrationSetting(self._database))
        self._t3_routes = T3Routes(self._t3, self._t3_placement)
        register_t3_tools(self._tools, self._t3, self._t3_placement)
        # Mac control from Voice: the journal's Mac bridge (same URL and sealed token) plus T3 for mac_task.
        self._mac = MacControlClient(self._heptabase_journal.bridge_store)
        # Google links opened in Chrome go to the user's Google account (setting, else the calendar's account).
        self._google_account = GoogleAccountSetting(self._database)
        self._mac_routes = MacRoutes(self._mac, google_account=self._google_account)
        mac_tools = register_mac_tools(self._tools, self._mac, t3=self._t3, placement=self._t3_placement,
                                       owner_name=lambda: self._profile.profile().display_name,
                                       google_account=self._google_account.email)
        mac_tools.set_screenshot_conversation(self._conversation_sync.screenshot_conversation)
        # Generated UIs from Voice: the same Mac bridge makes the visual; announcements bring it to the app.
        self._generated_ui = GeneratedUiClient(self._heptabase_journal.bridge_store)
        self._generated_ui_watcher = ArtifactWatcher(self._generated_ui, self._announcements, self._database)
        self._generated_ui_routes = GeneratedUiRoutes(self._generated_ui)
        register_generated_ui_tools(self._tools, self._generated_ui, self._generated_ui_watcher,
                                    conversation_lookup=self._conversation_sync.conversation_for)
        # Voice notes (side button): the R1's transcript goes to the same Mac bridge, which routes it.
        self._capture = CaptureService(CaptureBridgeClient(self._heptabase_journal.bridge_store), self._database,
                                       self._announcements)
        self._capture_routes = CaptureRoutes(self._capture)
        # Morning briefing: built on the Mac from email/calendar/agents, cached here for the Cards board and Voice.
        self._briefing = BriefingService(BriefingBridgeClient(self._heptabase_journal.bridge_store), self._database,
                                         self._announcements,
                                         timezone_name=lambda: self._heptabase_journal.settings().timezone,
                                         open_on_mac=lambda url: self._mac.open(url=url))
        self._briefing_routes = BriefingRoutes(self._briefing)
        register_briefing_tools(self._tools, self._briefing)
        self._background_agent_runs = AgentRunRepository(self._database)
        self._background_agent_settings = BackgroundAgentSettingsRepository(self._database)
        self._run_workspaces = RunWorkspaceRegistry(config.background_runs_path)
        self._workspace = DurableWorkspace(
            config.user_workspace_path,
            WorkspaceRepository(self._database),
        )
        self._instruction_documents = AgentInstructionDocuments(
            voice_path=config.voice_instructions_path,
            background_path=config.background_instructions_path,
            background_workspace=self._workspace,
        )
        self._skill_routes = SkillRoutes(self._instruction_documents)
        register_workspace_tools(self._tools, self._workspace, self._run_workspaces)
        self._primary_contexts = PrimaryContextBuilder(
            tools=self._tools, skills=self._skill_activation,
            memory=self._session_context_builder,
            background_instructions=self._instruction_documents.background_context,
        )
        self._agent_deliveries = AgentRunDeliveryRepository(self._database)
        self._background_agent_routes = BackgroundAgentRoutes(
            settings=self._background_agent_settings,
            runs=self._background_agent_runs,
            catalog=self._tools,
            deliveries=self._agent_deliveries,
        )
        self._background_agent_gateway = BackgroundMcpGateway(
            health=self.health,
            catalog=self._tools,
            allowed_names=lambda: self._background_agent_settings.get().allowed_tool_names,
            runs=self._background_agent_runs,
        )
        self._background_agent_routes.attach_gateway(self._background_agent_gateway)
        self._background_agent_factory = BackgroundRunFactory(
            credentials=credentials,
            provider_settings=provider_settings,
            background_settings=self._background_agent_settings,
            subscription=self._subscription,
            runs=self._background_agent_runs,
            gateway=self._background_agent_gateway,
            local_api_url=f"http://{config.local_api_host}:{config.local_api_port}",
            local_api_token=config.local_api_token,
            workspaces=self._run_workspaces,
            contexts=self._primary_contexts,
        )
        self._background_agent = BackgroundAgentService(
            settings=self._background_agent_settings,
            runs=self._background_agent_runs,
            loop_factory=self._background_agent_factory.prepare,
            completion_dispatcher=CompletionDispatcher(
                deliveries=self._agent_deliveries,
                voice_session_active=lambda session_id: self._providers.is_active_realtime_session(session_id),
            ),
            shutdown=self._background_agent_factory.close,
        )
        register_goal_tools(self._tools, self._background_agent, self._voice_modes)
        register_voice_mode_tool(self._tools, self._voice_modes)
        register_genui_tools(self._tools)
        self._outbound_mcp = McpLifecycle(
            McpConnectionRepository(self._database),
            self._connections,
            self._audience_router,
            self._tools,
            ConnectionCredentialRepository(self._database),
            connection_envelopes,
        )
        self._mcp_routes = McpRoutes(self._outbound_mcp)
        self._tool_routes = ToolRoutes(self._tools)
        self._card_catalog = CreationCatalogRepository(self._database)
        self._plugin_cards = PluginCardLifecycle(self._card_catalog, self._plugin_components)
        self._plugin_lifecycle = PluginLifecycle(
            self._plugins,
            self._audience_router,
            config.plugins_path,
            config.plugin_rollback_path,
            self._plugin_components,
            self._skills,
            self._outbound_mcp,
            import_recovery,
            self._plugin_cards,
        )
        self._plugin_routes = PluginRoutes(
            self._plugin_lifecycle,
            PluginArchiveInspector(config.plugin_quarantine_path),
        )
        self._bundled_plugins = BundledPluginInstaller(
            self._plugin_lifecycle,
            self._plugins,
            PluginArchiveInspector(config.plugin_quarantine_path),
        )
        self._creation_lifecycle = CreationLifecycle(
            self._card_catalog,
            self._audience_router,
            config.creations_path,
            config.creation_rollback_path,
            import_recovery,
        )
        self._creation_routes = CreationRoutes(
            self._creation_lifecycle,
            CreationArchiveInspector(config.creation_quarantine_path),
            CreationDescriptorInspector(config.creation_quarantine_path),
        )
        self._providers = ProviderController(
            credentials=credentials,
            settings=provider_settings,
            events=self._events,
            safety_source=config.local_api_token,
            subscription=self._subscription,
            profile=self._profile,
            catalog=self._catalog,
            sessions=self._sessions,
            session_context=self._session_context_builder,
            voice_tools=lambda: self._tools.realtime_definitions(
                exclude_names=frozenset({"goal_start"}),
            ),
            goal_intake_tools=lambda: self._tools.realtime_definitions(
                include_names=frozenset({"voice_mode_switch", "goal_start"}),
            ),
            voice_skill_instructions=self._instruction_documents.voice_instructions,
            voice_modes=self._voice_modes,
            t3_voice_context=_joined(T3VoiceContext(self._t3).render, MacVoiceContext(self._mac).render,
                                     GeneratedUiVoiceContext(self._generated_ui).render,
                                     BriefingVoiceContext(self._briefing).render),
        )
        self._text_runner = AgentsSdkTextRunner(
            credentials=credentials,
            settings=provider_settings,
            events=self._events,
            local_api_token=config.local_api_token,
            subscription=self._subscription,
        )
        self._memory_reviewer = MemoryReviewRunner(
            credentials=credentials,
            settings=provider_settings,
            events=self._events,
            local_api_token=config.local_api_token,
            subscription=self._subscription,
        )
        self._memory_pipeline = MemoryPipeline(
            sessions=self._sessions,
            memories=self._memories,
            reviewer=self._memory_reviewer,
            credentials=credentials,
            safety_source=config.local_api_token,
            events=self._events,
            settings=provider_settings,
            subscription=self._subscription,
        )
        self._memory = MemoryService(
            sessions=self._sessions,
            memories=self._memories,
            pipeline=self._memory_pipeline,
            credentials=credentials,
            safety_source=config.local_api_token,
            settings=provider_settings,
            subscription=self._subscription,
        )
        self._mcp = LocalMcpServer(self.health, catalog=self._tools)
        self._restart_request = restart_request
        self._environment = standard_library_status()
        self._agent_environment = agent_runtime_status()
        self._server: RuntimeHttpServer | None = None
        self._log = runtime_logger()

    def start(self) -> None:
        self._log.info("runtime.start.begin")
        self._releases.prepare()
        self._database.migrate()
        from .background_agent.rules import install_background_rules
        install_background_rules(
            self._workspace,
            self._config.user_workspace_path / "documents" / "RULES.md",
        )
        if self._audience_router.binding_for(CALENDAR_TOOL_SET) is None:
            self._audience_router.set_audience(
                CALENDAR_TOOL_SET,
                AgentAudience.BOTH,
                changed_by="runtime-bootstrap",
                reason="built-in Calendar is available to Voice and Text",
            )
        if self._audience_router.binding_for(TASKS_TOOL_SET) is None:
            self._audience_router.set_audience(
                TASKS_TOOL_SET, AgentAudience.BOTH, changed_by="runtime-bootstrap",
                reason="enable built-in Tasks for Voice and Background Agent",
            )
        if self._audience_router.binding_for(DEVICE_STATUS_TOOL_SET) is None:
            self._audience_router.set_audience(
                DEVICE_STATUS_TOOL_SET,
                AgentAudience.BOTH,
                changed_by="runtime-bootstrap",
                reason="preserve accepted device-status availability",
            )
        if self._audience_router.binding_for(MEMORY_TOOL_SET) is None:
            self._audience_router.set_audience(
                MEMORY_TOOL_SET,
                AgentAudience.BOTH,
                changed_by="runtime-bootstrap",
                reason="enable built-in memory for Voice and Background Agent",
            )
        if self._audience_router.binding_for(MAIL_TOOL_SET) is None:
            self._audience_router.set_audience(
                MAIL_TOOL_SET,
                AgentAudience.BOTH,
                changed_by="runtime-bootstrap",
                reason="enable built-in Mail for Voice and Background Agent",
            )
        if self._audience_router.binding_for(WEB_SEARCH_TOOL_SET) is None:
            self._audience_router.set_audience(
                WEB_SEARCH_TOOL_SET,
                AgentAudience.BOTH,
                changed_by="runtime-bootstrap",
                reason="enable built-in web search for Voice and Background Agent",
            )
        if self._audience_router.binding_for(GOAL_TOOL_SET) is None:
            self._audience_router.set_audience(
                GOAL_TOOL_SET,
                AgentAudience.VOICE,
                changed_by="runtime-bootstrap",
                reason="enable the built-in Voice goal delegation capability",
            )
        if self._audience_router.binding_for(WORKSPACE_TOOL_SET) is None:
            self._audience_router.set_audience(
                WORKSPACE_TOOL_SET,
                AgentAudience.BOTH,
                changed_by="runtime-bootstrap",
                reason="enable read-only workspace access for Voice and bounded workspace access for Background Agent",
            )
        if self._audience_router.binding_for(T3_TOOL_SET) is None:
            self._audience_router.set_audience(
                T3_TOOL_SET,
                AgentAudience.VOICE,
                changed_by="runtime-bootstrap",
                reason="enable built-in T3 Code orchestration for Voice",
            )
        if self._audience_router.binding_for(MAC_TOOL_SET) is None:
            self._audience_router.set_audience(
                MAC_TOOL_SET,
                AgentAudience.VOICE,
                changed_by="runtime-bootstrap",
                reason="enable control of the user's Mac for Voice (shown only when the Mac bridge is configured)",
            )
        if self._audience_router.binding_for(GENERATED_UI_TOOL_SET) is None:
            self._audience_router.set_audience(
                GENERATED_UI_TOOL_SET,
                AgentAudience.VOICE,
                changed_by="runtime-bootstrap",
                reason="enable generated visuals for Voice (shown only when the Mac bridge is configured)",
            )
        if self._audience_router.binding_for(BRIEFING_TOOL_SET) is None:
            self._audience_router.set_audience(
                BRIEFING_TOOL_SET,
                AgentAudience.VOICE,
                changed_by="runtime-bootstrap",
                reason="enable the morning brief for Voice (read only when asked; shown only when the Mac bridge is configured)",
            )
        if self._audience_router.binding_for(JOURNAL_TOOL_SET) is None:
            self._audience_router.set_audience(
                JOURNAL_TOOL_SET,
                AgentAudience.VOICE,
                changed_by="runtime-bootstrap",
                reason="enable the built-in Heptabase journal for Voice (shown only when connected)",
            )
        self._catalog.bootstrap_defaults()
        self._skill_lifecycle.recover()
        self._instruction_documents.recover()
        self._plugin_lifecycle.recover()
        self._creation_lifecycle.recover()
        self._background_agent.recover_interrupted()
        self._bundled_plugins.install_once(
            Path(__file__).resolve().parent / "plugins" / "bundled" / "resono-mail"
        )
        self._outbound_mcp.restore()
        record = self._lifecycle.record_start()
        self._log.info(
            "runtime.database_ready",
            extra={"release": str(record.value), "migration": self._config.database_path},
        )
        self._server = RuntimeHttpServer(
            host=self._config.local_api_host,
            port=self._config.local_api_port,
            token=self._config.local_api_token,
            health=self.health,
            lifecycle=self._lifecycle,
            events=self._events,
            pairing=self._pairing,
            providers=self._providers,
            text_runner=self._text_runner,
            subscription=self._subscription,
            mcp=self._mcp,
            profile=self._profile,
            sessions=self._sessions,
            memory=self._memory,
            restart_request=self._request_restart,
            skills=self._skill_routes,
            mail=self._mail_routes,
            calendar=self._calendar_routes,
            tasks=self._task_routes,
            outbound_mcp=self._mcp_routes,
            tools=self._tool_routes,
            plugins=self._plugin_routes,
            creations=self._creation_routes,
            connections=self._connection_routes,
            background_agent=self._background_agent_routes,
            t3=self._t3_routes,
            announcements=self._announcement_routes,
            heptabase=self._heptabase_routes,
            mac=self._mac_routes,
            conversation_sync=self._conversation_sync_routes,
            generated_ui=self._generated_ui_routes,
            capture=self._capture_routes,
            briefing=self._briefing_routes,
        )
        self._server.start()
        self._background_agent.start()
        self._mail_scheduler.start()
        self._calendar_scheduler.start()
        self._t3_sync.start()
        self._heptabase_journal.start()
        self._conversation_sync.start()
        self._generated_ui_watcher.start()
        self._capture.start()
        self._briefing.start()
        self._events.publish(
            "runtime.ready",
            {"status": "ready", "startCount": int(record.value)},
        )
        self._log.info("runtime.ready", extra={"start_count": int(record.value)})

    def stop(self) -> None:
        self._events.publish("runtime.stopping", {"status": "stopping"})
        self._background_agent.stop()
        self._mail_scheduler.stop()
        self._calendar_scheduler.stop()
        self._t3_sync.stop()
        self._heptabase_journal.stop()
        self._conversation_sync.stop()
        self._generated_ui_watcher.stop()
        self._capture.stop()
        self._briefing.stop()
        if self._server is not None:
            self._server.stop()
            self._server = None

    def health(self) -> dict[str, object]:
        database = self._database.health()
        status = (
            "ready"
            if database["status"] == "ready" and self._agent_environment["status"] == "ready"
            else "not_ready"
        )
        return {
            "contractVersion": 1,
            "status": status,
            "service": "sam-runtime",
            "database": database,
            "release": self._releases.active().release_id,
            "python": self._environment,
            "agents": self._agent_environment,
        }

    def _request_restart(self) -> None:
        self._events.publish("runtime.restart_requested", {"status": "restarting"})
        callback = self._restart_request
        if callback is not None:
            callback.run()


def _joined(*renders: Callable[[], str]) -> Callable[[], str]:
    """One instructions block from several voice addenda (each may be empty or fail on its own)."""
    def render() -> str:
        parts = []
        for part in renders:
            try:
                value = part()
            except Exception:
                value = ""
            if value:
                parts.append(value)
        return "\n\n".join(parts)
    return render
