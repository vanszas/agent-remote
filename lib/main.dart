import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:image_picker/image_picker.dart';
import 'agent_connector.dart';
import 'app_controller.dart';
import 'local_store.dart';
import 'models.dart';
import 'connection.dart';
import 'clipboard_image.dart';
import 'background_task_monitor.dart';
import 'credential_store.dart';
import 'hermes_remote_connector.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await BackgroundTaskMonitor.initialize();
  final c = AppController(DemoAgentConnector(), LocalStore());
  await c.initialize();
  ConnectionCatalog catalog;
  String? catalogError;
  try {
    catalog = await ConnectionCatalog.loadAsset();
  } catch (_) {
    catalog = const ConnectionCatalog(1, []);
    catalogError = 'Connection catalog could not be loaded.';
  }
  final connectionStore = ConnectionProfileStore();
  var connections = ConnectionSettingsController(
    catalog,
    connectionStore,
    error: catalogError,
  );
  try {
    await connections.initialize();
  } catch (_) {
    connections = ConnectionSettingsController(
      catalog,
      connectionStore,
      error: 'Connection settings could not be loaded.',
    );
  }
  final profile = connections.defaultProfile;
  final endpoint = profile?.values['endpoint'] as String?;
  if (profile != null && endpoint != null && endpoint.isNotEmpty) {
    final credentials = await CredentialStore().load(profile.id);
    await c.connect(
      HermesRemoteConnector(Uri.parse(endpoint), credentials?.password ?? ''),
    );
    if (!c.isDemo) {
      await c.loadWorkspaces(profile.values['workspacePath'] as String?);
      await c.restoreLastSession(
        await BackgroundTaskMonitor.consumeOpenSession(),
      );
    }
  }
  runApp(HermesRemoteApp(controller: c, connections: connections));
}

class HermesRemoteApp extends StatelessWidget {
  const HermesRemoteApp({
    super.key,
    required this.controller,
    required this.connections,
  });
  final AppController controller;
  final ConnectionSettingsController connections;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (_, _) => MaterialApp(
      title: 'Agent Remote',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF9DB2FF),
          secondary: Color(0xFFB7C4FF),
          surface: Color(0xFF111318),
          surfaceContainer: Color(0xFF1A1D24),
        ),
        scaffoldBackgroundColor: const Color(0xFF0B0D12),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0B0D12),
          surfaceTintColor: Colors.transparent,
        ),
        cardTheme: const CardThemeData(
          elevation: 0,
          margin: EdgeInsets.symmetric(vertical: 4),
        ),
      ),
      themeMode: switch (controller.theme) {
        ThemeModeChoice.light => ThemeMode.light,
        ThemeModeChoice.dark => ThemeMode.dark,
        _ => ThemeMode.system,
      },
      home: AppShell(controller, connections),
    ),
  );
}

class AppShell extends StatefulWidget {
  const AppShell(this.c, this.connections, {super.key});
  final AppController c;
  final ConnectionSettingsController connections;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  StreamSubscription<String>? _notificationSessionSubscription;
  AppController get c => widget.c;
  ConnectionSettingsController get connections => widget.connections;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _notificationSessionSubscription = BackgroundTaskMonitor.openedSessions
        .listen(c.restoreLastSession);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _notificationSessionSubscription?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _restoreNotificationSession();
  }

  Future<void> _restoreNotificationSession() async {
    final sessionId = await BackgroundTaskMonitor.consumeOpenSession();
    if (sessionId != null && sessionId.isNotEmpty) {
      await c.restoreLastSession(sessionId);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (c.takeConnectedNotice()) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Row(
              children: [
                Icon(Icons.check_circle, color: Colors.white),
                SizedBox(width: 12),
                Expanded(child: Text('Terhubung ke Agent Remote PC')),
              ],
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
      });
    }
    if (c.current != null) return ChatScreen(c);
    final wide = MediaQuery.sizeOf(context).width >= 700;
    final pages = [
      ChatsPage(c),
      TasksPage(c),
      FilesPage(c),
      SettingsPage(c, connections),
    ];
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _GithubAvatar(c.gitRepository, radius: 17),
            const SizedBox(width: 10),
            const Text('Agent Remote'),
          ],
        ),
        actions: [
          Icon(
            c.connected ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
            color: c.connected ? Colors.greenAccent : null,
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: Row(
        children: [
          if (wide)
            NavigationRail(
              selectedIndex: c.page,
              onDestinationSelected: c.setPage,
              labelType: NavigationRailLabelType.all,
              destinations: nav
                  .map(
                    (e) => NavigationRailDestination(
                      icon: Icon(e.$1),
                      label: Text(e.$2),
                    ),
                  )
                  .toList(),
            ),
          Expanded(child: pages[c.page]),
        ],
      ),
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: c.page,
              onDestinationSelected: c.setPage,
              destinations: nav
                  .map(
                    (e) => NavigationDestination(icon: Icon(e.$1), label: e.$2),
                  )
                  .toList(),
            ),
    );
  }
}

const nav = [
  (Icons.chat_bubble_outline, 'Chat'),
  (Icons.task_alt, 'Proses'),
  (Icons.folder_outlined, 'File'),
  (Icons.settings_outlined, 'Pengaturan'),
];

class ChatsPage extends StatelessWidget {
  const ChatsPage(this.c, {super.key});
  final AppController c;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Connect to your ideas',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        Text(
          c.connected
              ? 'Terhubung ke Agent Remote PC - eksekusi berjalan di PC.'
              : c.isDemo
              ? 'Offline preview · Connect a PC to sync.'
              : 'Menghubungkan ulang ke Agent Remote PC…',
        ),
        if (c.connector case final HermesRemoteConnector remote) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => showAgentSheet(context, c, remote),
                  icon: const Icon(Icons.smart_toy_outlined),
                  label: Text('Agent (${remote.selectedAgentIds.length})'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => showFolderSheet(context, c, remote),
                  icon: const Icon(Icons.folder_outlined),
                  label: const Text('Pilih folder'),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 12),
        SearchBar(
          hintText: 'Search sessions',
          leading: const Icon(Icons.search),
          onChanged: (v) {
            c.search = v;
            c.refresh();
          },
        ),
        const SizedBox(height: 12),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () async {
              await c.reloadProjects();
              await c.reloadSessions();
            },
            child: c.projects.isEmpty
                ? ListView(
                    children: [
                      const SizedBox(height: 120),
                      const Icon(Icons.forum_outlined, size: 64),
                      const Center(child: Text('No chats yet')),
                      Center(
                        child: FilledButton.icon(
                          onPressed: c.newSession,
                          icon: const Icon(Icons.add),
                          label: const Text('New Chat'),
                        ),
                      ),
                    ],
                  )
                : ListView(
                    children: c.projects
                        .map((project) => ProjectSessionGroup(c, project))
                        .toList(),
                  ),
          ),
        ),
      ],
    ),
  );
}

Future<void> showAgentSheet(
  BuildContext context,
  AppController app,
  HermesRemoteConnector remote,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  builder: (sheetContext) => StatefulBuilder(
    builder: (context, setSheetState) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Agent PC', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 12),
            SegmentedButton<RemoteExecutionMode>(
              segments: const [
                ButtonSegment(
                  value: RemoteExecutionMode.single,
                  label: Text('Single'),
                ),
                ButtonSegment(
                  value: RemoteExecutionMode.parallel,
                  label: Text('Parallel'),
                ),
                ButtonSegment(
                  value: RemoteExecutionMode.coordinator,
                  label: Text('Koordinator'),
                ),
              ],
              selected: {remote.executionMode},
              onSelectionChanged: (value) {
                setSheetState(() => remote.executionMode = value.first);
                app.refresh();
              },
            ),
            const SizedBox(height: 8),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                remote.permissionMode == RemotePermissionMode.full
                    ? Icons.gpp_maybe_outlined
                    : Icons.shield_outlined,
                color: remote.permissionMode == RemotePermissionMode.full
                    ? Colors.orange
                    : null,
              ),
              title: Text(
                'Izin Codex - ${_permissionLabel(remote.permissionMode)}',
              ),
              subtitle: Text(
                '${_permissionDescription(remote.permissionMode)}. Agent lain mengikuti policy CLI masing-masing.',
              ),
              trailing: PopupMenuButton<RemotePermissionMode>(
                tooltip: 'Ubah izin agent',
                initialValue: remote.permissionMode,
                onSelected: (mode) async {
                  await remote.setPermissionMode(mode);
                  setSheetState(() {});
                  app.refresh();
                },
                itemBuilder: (context) => RemotePermissionMode.values
                    .map(
                      (mode) => PopupMenuItem(
                        value: mode,
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            mode == RemotePermissionMode.full
                                ? Icons.warning_amber_rounded
                                : Icons.shield_outlined,
                            color: mode == RemotePermissionMode.full
                                ? Colors.orange
                                : null,
                          ),
                          title: Text(_permissionLabel(mode)),
                          subtitle: Text(_permissionDescription(mode)),
                        ),
                      ),
                    )
                    .toList(),
                icon: const Icon(Icons.expand_more),
              ),
            ),
            const SizedBox(height: 12),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: remote.availableAgents
                    .map(
                      (agent) => CheckboxListTile(
                        value: remote.selectedAgentIds.contains(agent.id),
                        onChanged: agent.installed
                            ? (value) {
                                setSheetState(() {
                                  if (remote.executionMode ==
                                      RemoteExecutionMode.single) {
                                    remote.selectedAgentIds = {agent.id};
                                  } else if (value == true) {
                                    remote.selectedAgentIds = {
                                      ...remote.selectedAgentIds,
                                      agent.id,
                                    };
                                  } else if (remote.selectedAgentIds.length >
                                      1) {
                                    remote.selectedAgentIds = {
                                      ...remote.selectedAgentIds,
                                    }..remove(agent.id);
                                  }
                                  remote.coordinatorAgentId =
                                      remote.selectedAgentIds.firstOrNull ?? '';
                                });
                                app.refresh();
                              }
                            : null,
                        secondary: Icon(
                          agent.installed
                              ? Icons.check_circle_outline
                              : Icons.download_outlined,
                          color: agent.installed ? Colors.green : null,
                        ),
                        title: Text(agent.name),
                        subtitle: Text(
                          agent.installed
                              ? 'Terpasang - ${agent.command}'
                              : 'Didukung • CLI belum ditemukan di PC',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(sheetContext),
              child: const Text('Selesai'),
            ),
          ],
        ),
      ),
    ),
  ),
);

Future<void> showFolderSheet(
  BuildContext context,
  AppController app,
  HermesRemoteConnector remote,
) async {
  var listing = await remote.browsePcFolders(app.workspacePath ?? '');
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => StatefulBuilder(
      builder: (context, setSheetState) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .78,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: 'Pilih disk',
                      onPressed: () async {
                        final next = await remote.browsePcFolders();
                        setSheetState(() => listing = next);
                      },
                      icon: const Icon(Icons.storage_outlined),
                    ),
                    Expanded(
                      child: Text(
                        listing.path.isEmpty ? 'Pilih disk' : listing.path,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    FilledButton(
                      onPressed: listing.path.isEmpty
                          ? null
                          : () async {
                              await app.selectWorkspace(listing.path);
                              if (sheetContext.mounted) {
                                Navigator.pop(sheetContext);
                              }
                            },
                      child: const Text('Pakai'),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView(
                  children: [
                    if (listing.parent != null)
                      ListTile(
                        leading: const Icon(Icons.arrow_upward),
                        title: const Text('Folder induk'),
                        onTap: () async {
                          final next = await remote.browsePcFolders(
                            listing.parent!,
                          );
                          setSheetState(() => listing = next);
                        },
                      ),
                    ...listing.folders.map(
                      (folder) => ListTile(
                        leading: const Icon(Icons.folder_outlined),
                        title: Text(folder.name),
                        subtitle: Text(
                          folder.path,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () async {
                          final next = await remote.browsePcFolders(
                            folder.path,
                          );
                          setSheetState(() => listing = next);
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

String _permissionLabel(RemotePermissionMode mode) => switch (mode) {
  RemotePermissionMode.ask => 'Ask for approval',
  RemotePermissionMode.workspace => 'Otomatis di workspace',
  RemotePermissionMode.full => 'Full access',
};

String _permissionDescription(RemotePermissionMode mode) => switch (mode) {
  RemotePermissionMode.ask => 'Minta izin untuk tindakan yang tidak dipercaya',
  RemotePermissionMode.workspace =>
    'Boleh mengubah folder terpilih, tidak di luar folder',
  RemotePermissionMode.full =>
    'Tanpa sandbox; dapat mengakses seluruh PC dan internet',
};

class ProjectSessionGroup extends StatelessWidget {
  const ProjectSessionGroup(this.c, this.project, {super.key});
  final AppController c;
  final AgentProject project;

  @override
  Widget build(BuildContext context) {
    final query = c.search.trim().toLowerCase();
    final sessions = project.sessions
        .where(
          (session) =>
              query.isEmpty ||
              session.title.toLowerCase().contains(query) ||
              session.preview.toLowerCase().contains(query),
        )
        .toList();
    if (query.isNotEmpty && sessions.isEmpty) return const SizedBox.shrink();
    final active = project.workspace.path == c.workspacePath;
    return Card(
      color: active ? Theme.of(context).colorScheme.surfaceContainerHigh : null,
      child: ExpansionTile(
        initiallyExpanded: active || sessions.isNotEmpty,
        leading: Icon(
          active ? Icons.folder_open_outlined : Icons.folder_outlined,
        ),
        title: Text(project.workspace.name),
        subtitle: Text(
          project.workspace.path,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: active
            ? const Icon(Icons.radio_button_checked, size: 18)
            : const Icon(Icons.chevron_right),
        onExpansionChanged: (expanded) {
          if (expanded && !active) c.selectWorkspace(project.workspace.path);
        },
        children: sessions.isEmpty
            ? const [ListTile(dense: true, title: Text('Belum ada session'))]
            : sessions
                  .map((session) => ProjectSessionTile(c, project, session))
                  .toList(),
      ),
    );
  }
}

class ProjectSessionTile extends StatelessWidget {
  const ProjectSessionTile(this.c, this.project, this.session, {super.key});
  final AppController c;
  final AgentProject project;
  final AgentSession session;

  @override
  Widget build(BuildContext context) {
    final task = c.tasks
        .where(
          (item) => item.sessionId == session.id && item.status == 'running',
        )
        .firstOrNull;
    final running = task != null || session.status == SessionStatus.generating;
    final colors = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      margin: const EdgeInsets.fromLTRB(24, 3, 8, 3),
      decoration: BoxDecoration(
        color: running ? colors.primaryContainer.withValues(alpha: .28) : null,
        borderRadius: BorderRadius.circular(14),
        border: running
            ? Border(left: BorderSide(color: colors.primary, width: 4))
            : null,
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        leading: running
            ? SizedBox.square(
                dimension: 30,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: colors.primary,
                    ),
                    Icon(Icons.bolt, size: 16, color: colors.primary),
                  ],
                ),
              )
            : const Icon(Icons.chat_bubble_outline, size: 20),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (running)
              Text(
                'SEDANG MENGERJAKAN',
                style: TextStyle(
                  color: colors.primary,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: .7,
                ),
              ),
            Text(
              session.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontWeight: running ? FontWeight.w700 : null),
            ),
          ],
        ),
        subtitle: running
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 4),
                  LinearProgressIndicator(
                    minHeight: 3,
                    borderRadius: BorderRadius.circular(99),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    task?.detail.isNotEmpty == true
                        ? task!.detail
                        : 'Agent sedang berpikir...',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (task != null)
                    Text(
                      '${task.agents.join(' + ')} - ${_taskPermissionLabel(task.permission)} • ${formatElapsedDuration(task.elapsedSeconds)}',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                ],
              )
            : session.preview.isEmpty
            ? null
            : Text(
                session.preview,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
        trailing: Icon(running ? Icons.arrow_forward : Icons.chevron_right),
        onTap: () => c.openProjectSession(project, session),
      ),
    );
  }
}

String _taskPermissionLabel(String permission) => switch (permission) {
  'ask' => 'Ask approval',
  'full' => 'Full access',
  _ => 'Workspace access',
};

class SessionTile extends StatelessWidget {
  const SessionTile(this.c, this.s, {super.key});
  final AppController c;
  final AgentSession s;
  @override
  Widget build(BuildContext context) => Card(
    clipBehavior: Clip.antiAlias,
    child: ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      onTap: () => c.open(s),
      leading: CircleAvatar(
        backgroundColor: Theme.of(context).colorScheme.primaryContainer,
        child: Icon(
          s.isPinned ? Icons.push_pin : Icons.chat_bubble_outline,
          color: Theme.of(context).colorScheme.onPrimaryContainer,
        ),
      ),
      title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        s.messages.lastOrNull?.content ??
            (s.preview.isNotEmpty ? s.preview : 'Empty session'),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: PopupMenuButton<String>(
        onSelected: (v) async {
          if (v == 'pin') c.pin(s);
          if (v == 'rename') {
            final x = await ask(context, 'Rename session', s.title);
            if (x != null && x.trim().isNotEmpty) c.rename(s, x.trim());
          }
          if (v == 'delete') {
            if (!context.mounted) return;
            final delete = await confirm(context, 'Delete ${s.title}?');
            if (delete) c.delete(s);
          }
        },
        itemBuilder: (_) => [
          PopupMenuItem(
            value: 'pin',
            child: Text(s.isPinned ? 'Unpin' : 'Pin'),
          ),
          const PopupMenuItem(value: 'rename', child: Text('Rename')),
          const PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
      ),
    ),
  );
}

class ChatScreen extends StatefulWidget {
  const ChatScreen(this.c, {super.key});
  final AppController c;
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final text = TextEditingController();
  final pending = <AgentAttachment>[];

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c, s = c.current!;
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: c.closeCurrentSession),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(s.title),
            Text(
              c.isDemo
                  ? 'Demo Mode • local only'
                  : c.capabilities.supportsAgentExecution
                  ? '${s.activeModelName ?? 'PC Agent'} • Connected'
                  : 'Remote composer • sent to PC',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (s.activities.isNotEmpty || s.status == SessionStatus.generating)
              ActivitySummaryCard(s),
            Expanded(
              child: c.loadingSession
                  ? const Center(child: CircularProgressIndicator())
                  : ListView.builder(
                      reverse: true,
                      padding: const EdgeInsets.all(12),
                      itemCount:
                          s.messages.length +
                          (s.status == SessionStatus.generating &&
                                  (s.messages.isEmpty ||
                                      s.messages.last.role !=
                                          MessageRole.assistant)
                              ? 1
                              : 0),
                      itemBuilder: (_, i) {
                        final showRunning =
                            s.status == SessionStatus.generating &&
                            (s.messages.isEmpty ||
                                s.messages.last.role != MessageRole.assistant);
                        if (showRunning && i == 0) {
                          return const _RunningAgentCard();
                        }
                        final offset = showRunning ? 1 : 0;
                        return MessageCard(
                          s.messages[s.messages.length - 1 - (i - offset)],
                          c,
                        );
                      },
                    ),
            ),
            if (pending.isNotEmpty)
              SizedBox(
                height: 90,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: pending
                      .map(
                        (a) => AttachmentChip(
                          a,
                          onDelete: () {
                            setState(() => pending.remove(a));
                          },
                        ),
                      )
                      .toList(),
                ),
              ),
            Wrap(
              spacing: 8,
              children: c.isDemo
                  ? [
                          '/demo tool',
                          '/demo approval',
                          '/demo clarify',
                          '/demo error',
                          '/demo long',
                        ]
                        .map(
                          (x) => ActionChip(
                            label: Text(x.replaceFirst('/demo ', '')),
                            onPressed: () => text.text = x,
                          ),
                        )
                        .toList()
                  : [],
            ),
            Container(
              margin: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              padding: const EdgeInsets.fromLTRB(6, 8, 6, 6),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainer,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (c.capabilities.supportsImages ||
                      c.capabilities.supportsFiles)
                    PopupMenuButton<String>(
                      tooltip: 'Add attachment',
                      icon: const Icon(Icons.attach_file),
                      onSelected: pick,
                      itemBuilder: (_) => [
                        if (c.capabilities.supportsImages)
                          const PopupMenuItem(
                            value: 'image',
                            child: Text('Gallery image'),
                          ),
                        if (c.capabilities.supportsImages)
                          const PopupMenuItem(
                            value: 'camera',
                            child: Text('Camera'),
                          ),
                        if (c.capabilities.supportsImages)
                          const PopupMenuItem(
                            value: 'clipboard',
                            child: Text('Tempel gambar clipboard'),
                          ),

                        if (c.capabilities.supportsFiles)
                          const PopupMenuItem(
                            value: 'file',
                            child: Text('File'),
                          ),
                      ],
                    ),
                  Expanded(
                    child: TextField(
                      controller: text,
                      maxLines: 5,
                      minLines: 1,
                      contextMenuBuilder: (context, editableTextState) {
                        final items = [
                          ...editableTextState.contextMenuButtonItems,
                          ContextMenuButtonItem(
                            label: 'Paste gambar',
                            onPressed: () {
                              editableTextState.hideToolbar();
                              pick('clipboard');
                            },
                          ),
                        ];
                        return AdaptiveTextSelectionToolbar.buttonItems(
                          anchors: editableTextState.contextMenuAnchors,
                          buttonItems: items,
                        );
                      },
                      decoration: InputDecoration(
                        hintText: c.isDemo
                            ? 'Kirim pesan ke Demo Agent'
                            : 'Instruksikan agent di PC...',
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  s.status == SessionStatus.generating
                      ? IconButton.filled(
                          tooltip: 'Stop',
                          onPressed: c.stop,
                          icon: const Icon(Icons.stop),
                        )
                      : IconButton.filled(
                          tooltip: 'Send',
                          onPressed: () {
                            final v = text.text;
                            text.clear();
                            c.send(v, attachments: List.of(pending));
                            setState(pending.clear);
                          },
                          icon: const Icon(Icons.send),
                        ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> pick(String kind) async {
    try {
      String? path;
      String? originalName;
      String? sourceMime;
      if (kind == 'file') {
        final picked = (await FilePicker.platform.pickFiles())?.files.single;
        path = picked?.path;
        originalName = picked?.name;
      } else if (kind == 'clipboard') {
        final picked = await readClipboardImage();
        if (picked == null) {
          throw StateError('Clipboard tidak berisi gambar yang bisa dibaca.');
        }
        path = picked.path;
        originalName = picked.name;
        sourceMime = picked.mimeType;
      } else {
        final picked = await ImagePicker().pickImage(
          source: kind == 'camera' ? ImageSource.camera : ImageSource.gallery,
        );
        path = picked?.path;
        originalName = picked?.name;
        sourceMime = picked?.mimeType;
      }
      if (path == null) return;
      final sourcePath = path;
      if (pending.length >= 10) {
        throw ArgumentError('Maximum 10 attachments per message.');
      }
      final f = File(sourcePath), size = await f.length();
      final err = validateAttachmentSize(size);
      if (err != null) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(err)));
        }
        return;
      }
      final copy = await widget.c.store.importAttachment(
        sessionId: widget.c.current!.id,
        sourcePath: sourcePath,
        generatedId: DateTime.now().microsecondsSinceEpoch.toString(),
      );
      setState(
        () => pending.add(
          AgentAttachment(
            id: copy.path,
            originalName:
                originalName ?? File(sourcePath).uri.pathSegments.last,
            localPath: copy.path,
            mimeType: sourceMime ?? mimeForFilename(originalName ?? sourcePath),
            sizeBytes: size,
            kind: kind == 'file'
                ? AttachmentKind.document
                : AttachmentKind.image,
            createdAt: DateTime.now(),
          ),
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Attachment could not be imported.')),
        );
      }
    }
  }
}

class ActivitySummaryCard extends StatelessWidget {
  const ActivitySummaryCard(this.session, {super.key});
  final AgentSession session;

  @override
  Widget build(BuildContext context) {
    final latest = session.activities.lastOrNull;
    final running = session.status == SessionStatus.generating;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      color: running
          ? Theme.of(context).colorScheme.primaryContainer.withValues(alpha: .4)
          : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
        child: Column(
          children: [
            Row(
              children: [
                Icon(
                  running ? Icons.bolt : Icons.check_circle_outline,
                  color: running
                      ? Theme.of(context).colorScheme.primary
                      : Colors.green,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        running ? 'Task sedang berjalan' : 'Aktivitas terakhir',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        latest?.detail ?? 'Agent sedang memulai...',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: () => showActivityTimeline(context, session),
                  child: const Text('Lihat proses'),
                ),
              ],
            ),
            if (running) const LinearProgressIndicator(minHeight: 3),
          ],
        ),
      ),
    );
  }
}

Future<void> showActivityTimeline(
  BuildContext context,
  AgentSession session,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  builder: (context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .72,
      child: Column(
        children: [
          ListTile(
            title: const Text('Proses task'),
            subtitle: Text(session.activeModelName ?? 'PC Agent'),
            trailing: IconButton(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: session.activities.isEmpty
                ? const Center(child: Text('Belum ada aktivitas'))
                : ListView.builder(
                    itemCount: session.activities.length,
                    itemBuilder: (context, index) {
                      final activity = session.activities[index];
                      final legacyOutput = activity.detail.length > 300
                          ? activity.detail
                          : '';
                      final output = activity.output.isNotEmpty
                          ? activity.output
                          : legacyOutput;
                      final detail = legacyOutput.isNotEmpty
                          ? '${activity.toolName.isEmpty ? 'Tool' : activity.toolName} selesai'
                          : activity.detail;
                      final displayKind = activity.toolName == 'shell'
                          ? 'running_command'
                          : activity.kind;
                      if (output.isNotEmpty) {
                        return ExpansionTile(
                          leading: Icon(_activityIcon(displayKind)),
                          title: Text(_activityTitle(displayKind)),
                          subtitle: Text(detail),
                          trailing: Text(formatLocalClock(activity.createdAt)),
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(72, 0, 20, 16),
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: SelectableText(output),
                              ),
                            ),
                          ],
                        );
                      }
                      return ListTile(
                        leading: Icon(_activityIcon(displayKind)),
                        title: Text(_activityTitle(displayKind)),
                        subtitle: SelectableText(detail),
                        trailing: Text(formatLocalClock(activity.createdAt)),
                      );
                    },
                  ),
          ),
        ],
      ),
    ),
  ),
);

IconData _activityIcon(String kind) => switch (kind) {
  'queued' => Icons.schedule,
  'thinking' => Icons.psychology_outlined,
  'editing' => Icons.edit_outlined,
  'testing' => Icons.science_outlined,
  'running_command' => Icons.terminal,
  'completed' => Icons.check_circle_outline,
  'failed' => Icons.error_outline,
  _ => Icons.sync,
};

String _activityTitle(String kind) => switch (kind) {
  'queued' => 'Masuk antrean',
  'thinking' => 'Menganalisis',
  'editing' => 'Mengubah file',
  'testing' => 'Menjalankan verifikasi',
  'running_command' => 'Menjalankan command',
  'completed' => 'Selesai',
  'failed' => 'Gagal',
  _ => 'Aktivitas agent',
};

class _RunningAgentCard extends StatelessWidget {
  const _RunningAgentCard();
  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2.2),
            ),
            const SizedBox(width: 12),
            const Text('Agent sedang berpikir…'),
          ],
        ),
      ),
    ),
  );
}

class MessageCard extends StatelessWidget {
  const MessageCard(this.m, this.c, {super.key});
  final ChatMessage m;
  final AppController c;
  @override
  Widget build(BuildContext context) {
    final user = m.role == MessageRole.user;
    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: Card(
        color: user ? Theme.of(context).colorScheme.primaryContainer : null,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 700),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (m.approvalRequest case final request?) ...[
                  Text(request.title),
                  Text(request.description),
                  Text('Risk: ${request.riskLevel.name} • Demo only'),
                  Wrap(
                    children: [
                      FilledButton(
                        onPressed: request.status == ApprovalStatus.pending
                            ? () => c.approveRequest(request.id)
                            : null,
                        child: const Text('Approve once'),
                      ),
                      TextButton(
                        onPressed: request.status == ApprovalStatus.pending
                            ? () => c.denyRequest(request.id)
                            : null,
                        child: const Text('Deny'),
                      ),
                    ],
                  ),
                  Text('Status: ${request.status.name}'),
                ] else if (m.clarificationRequest case final request?) ...[
                  Text(request.question),
                  Wrap(
                    children: request.choices
                        .map(
                          (x) => ActionChip(
                            label: Text(x),
                            onPressed:
                                request.status == ClarificationStatus.pending
                                ? () => c.answerClarification(request.id, x)
                                : null,
                          ),
                        )
                        .toList(),
                  ),
                  Text(
                    request.selectedAnswer ?? 'Status: ${request.status.name}',
                  ),
                ] else if (user)
                  SelectableText(m.content)
                else
                  MarkdownBody(
                    data: m.content.isEmpty ? 'Thinking…' : m.content,
                    selectable: true,
                  ),
                ...m.attachments.map((a) => AttachmentChip(a)),
                ...m.toolActivities.map(
                  (t) => ExpansionTile(
                    initiallyExpanded: t.status == ToolActivityStatus.running,
                    title: Text('${t.displayName} • ${t.status.name}'),
                    subtitle: t.progress == null
                        ? null
                        : LinearProgressIndicator(value: t.progress),
                    children: [
                      ListTile(
                        title: Text(t.summary),
                        subtitle: Text(
                          t.outputPreview ??
                              'Simulation; no terminal command runs.',
                        ),
                      ),
                    ],
                  ),
                ),
                if (m.errorMessage != null)
                  Text(
                    m.errorMessage!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                if (m.status == MessageStatus.streaming)
                  const LinearProgressIndicator(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class AttachmentChip extends StatelessWidget {
  const AttachmentChip(this.a, {super.key, this.onDelete});
  final AgentAttachment a;
  final VoidCallback? onDelete;
  @override
  Widget build(BuildContext context) => Card(
    child: SizedBox(
      width: 180,
      child: ListTile(
        leading: a.kind == AttachmentKind.image
            ? Image.file(
                File(a.localPath),
                width: 40,
                errorBuilder: (_, _, _) => const Icon(Icons.broken_image),
              )
            : const Icon(Icons.description),
        title: Text(
          a.originalName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text('${(a.sizeBytes / 1024).ceil()} KB'),
        trailing: onDelete == null
            ? null
            : IconButton(onPressed: onDelete, icon: const Icon(Icons.close)),
      ),
    ),
  );
}

class TasksPage extends StatefulWidget {
  const TasksPage(this.c, {super.key});
  final AppController c;
  @override
  State<TasksPage> createState() => _TasksPageState();
}

class _TasksPageState extends State<TasksPage> {
  @override
  void initState() {
    super.initState();
    widget.c.reloadTasks();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    return RefreshIndicator(
      onRefresh: c.reloadTasks,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'PC activity',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              Badge(
                label: Text('${c.tasks.length}'),
                child: const Icon(Icons.monitor_heart_outlined),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Agent work runs on your PC. This phone only controls and monitors tasks.',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          if (c.tasks.isEmpty)
            const Card(
              child: ListTile(
                leading: Icon(Icons.check_circle_outline),
                title: Text('PC is idle'),
                subtitle: Text('No active turns or background tasks.'),
              ),
            ),
          ...c.tasks.map(
            (task) => Card(
              child: ListTile(
                onTap: task.sessionId.isEmpty || task.source != 'agent_remote'
                    ? null
                    : () => c.openTask(task),
                leading: task.status == 'running'
                    ? const SizedBox.square(
                        dimension: 24,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      )
                    : Icon(
                        task.status == 'completed'
                            ? Icons.check_circle_outline
                            : task.status == 'stopped'
                            ? Icons.stop_circle_outlined
                            : Icons.error_outline,
                      ),
                title: Text(task.title),
                subtitle: Text(
                  [
                    task.agents.join(' + '),
                    task.source == 'codex_desktop'
                        ? 'Codex Desktop/CLI'
                        : 'Agent Remote',
                    task.detail,
                    if (task.source == 'codex_desktop' &&
                        task.updatedAt != null)
                      'Selesai ${formatLocalClock(task.updatedAt!)}'
                    else if (task.createdAt != null)
                      'Mulai ${formatLocalClock(task.createdAt!)} • ${formatElapsedDuration(task.elapsedSeconds)}',
                    if (task.status == 'running' && task.idleSeconds >= 15)
                      'Belum ada event baru selama ${formatElapsedDuration(task.idleSeconds)}',
                    task.workspace,
                  ].where((value) => value.isNotEmpty).join('\n'),
                  maxLines: 5,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: Chip(label: Text(task.status)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class FilesPage extends StatelessWidget {
  const FilesPage(this.c, {super.key});
  final AppController c;
  @override
  Widget build(BuildContext context) {
    final statuses = {for (final item in c.gitStatus) item.path: item.status};
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Workspace files',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
            IconButton(
              onPressed: c.reloadWorkspaceData,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        Text(c.workspacePath ?? 'Folder kerja PC belum terhubung'),
        if (c.gitRepository.isGitRepository)
          Card(
            margin: const EdgeInsets.symmetric(vertical: 12),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _GithubAvatar(c.gitRepository, radius: 22),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              c.gitRepository.githubRepository.isEmpty
                                  ? 'Git repository'
                                  : '${c.gitRepository.githubOwner}/${c.gitRepository.githubRepository}',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            Text('Branch: ${c.gitRepository.branch}'),
                          ],
                        ),
                      ),
                      IconButton.filledTonal(
                        tooltip: 'Fetch perubahan GitHub',
                        onPressed: c.syncGitHub,
                        icon: const Icon(Icons.sync),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    children: [
                      Chip(
                        avatar: const Icon(Icons.upload, size: 18),
                        label: Text('${c.gitRepository.ahead} keluar'),
                      ),
                      Chip(
                        avatar: const Icon(Icons.download, size: 18),
                        label: Text('${c.gitRepository.behind} masuk'),
                      ),
                    ],
                  ),
                  if (c.gitRepository.outgoing.isNotEmpty)
                    _CommitSection(
                      title: 'Perubahan keluar',
                      commits: c.gitRepository.outgoing,
                      icon: Icons.north_east,
                    ),
                  if (c.gitRepository.incoming.isNotEmpty)
                    _CommitSection(
                      title: 'Perubahan masuk',
                      commits: c.gitRepository.incoming,
                      icon: Icons.south_west,
                    ),
                ],
              ),
            ),
          )
        else
          const Card(
            child: ListTile(
              leading: Icon(Icons.cloud_off_outlined),
              title: Text('Folder ini tidak terhubung ke Git repository'),
              subtitle: Text(
                'Session tetap tersimpan khusus untuk folder ini.',
              ),
            ),
          ),
        if (c.workspaceFolder.isNotEmpty)
          TextButton.icon(
            onPressed: () => c.openWorkspaceFolder(''),
            icon: const Icon(Icons.arrow_upward),
            label: const Text('Workspace root'),
          ),
        if (c.workspaceEntries.isEmpty)
          const ListTile(
            leading: Icon(Icons.folder_open),
            title: Text('No workspace files loaded'),
          ),
        ...c.workspaceEntries.map((entry) {
          final status = statuses[entry.path];
          return ListTile(
            onTap: entry.isDirectory
                ? () => c.openWorkspaceFolder(entry.path)
                : null,
            leading: Icon(
              entry.isDirectory
                  ? Icons.folder_outlined
                  : Icons.insert_drive_file_outlined,
            ),
            title: Text(entry.name),
            trailing: status == null ? null : Chip(label: Text(status.name)),
          );
        }),
        if (c.gitStatus.isNotEmpty) ...[
          const Divider(),
          Text(
            'Git changes (${c.gitStatus.length})',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          ...c.gitStatus
              .where(
                (item) =>
                    !c.workspaceEntries.any((entry) => entry.path == item.path),
              )
              .map(
                (item) => ListTile(
                  leading: const Icon(Icons.change_history),
                  title: Text(item.path),
                  trailing: Chip(label: Text(item.status.name)),
                ),
              ),
        ],
      ],
    );
  }
}

class _GithubAvatar extends StatelessWidget {
  const _GithubAvatar(this.repository, {required this.radius});
  final GitRepositoryStatus repository;
  final double radius;

  @override
  Widget build(BuildContext context) => CircleAvatar(
    radius: radius,
    backgroundColor: Theme.of(context).colorScheme.primaryContainer,
    backgroundImage: repository.githubAvatarUrl.isEmpty
        ? null
        : NetworkImage(repository.githubAvatarUrl),
    child: repository.githubAvatarUrl.isEmpty
        ? const Icon(Icons.person_outline)
        : null,
  );
}

class _CommitSection extends StatelessWidget {
  const _CommitSection({
    required this.title,
    required this.commits,
    required this.icon,
  });
  final String title;
  final List<GitCommit> commits;
  final IconData icon;

  @override
  Widget build(BuildContext context) => ExpansionTile(
    tilePadding: EdgeInsets.zero,
    leading: Icon(icon),
    title: Text(title),
    children: commits
        .map(
          (commit) => ListTile(
            dense: true,
            contentPadding: const EdgeInsets.only(left: 12),
            leading: Text(commit.hash),
            title: Text(commit.subject),
            subtitle: Text(commit.author),
          ),
        )
        .toList(),
  );
}

class SettingsPage extends StatelessWidget {
  const SettingsPage(this.c, this.connections, {super.key});
  final AppController c;
  final ConnectionSettingsController connections;
  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      Text('Settings', style: Theme.of(context).textTheme.headlineSmall),
      const ListTile(title: Text('Appearance')),
      SegmentedButton<ThemeModeChoice>(
        segments: ThemeModeChoice.values
            .map((x) => ButtonSegment(value: x, label: Text(x.name)))
            .toList(),
        selected: {c.theme},
        onSelectionChanged: (x) => c.setTheme(x.first),
      ),
      const Divider(),
      Card(
        child: ListTile(
          leading: const Icon(Icons.hub_outlined),
          title: const Text('Agent connection'),
          subtitle: Text(
            '${connections.summary}\n${connections.providerSummary}',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => ConnectionSettingsScreen(connections, c),
            ),
          ),
        ),
      ),
      const ListTile(
        title: Text('About'),
        subtitle: Text('Agent Remote 0.3.0\nMulti-agent PC controller'),
      ),
    ],
  );
}

class ConnectionSettingsScreen extends StatelessWidget {
  const ConnectionSettingsScreen(this.controller, this.app, {super.key});
  final ConnectionSettingsController controller;
  final AppController app;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Koneksi Agent Remote')),
    body: ListenableBuilder(
      listenable: controller,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Choose where the agent will run.'),
          if (controller.error != null) Text(controller.error!),
          ...controller.catalog.providers.map(
            (provider) => Card(
              child: ListTile(
                enabled: provider.enabled,
                selected: controller.selectedProviderId == provider.id,
                leading: Icon(resolveConnectionIcon(provider.iconKey)),
                title: Text(
                  provider.displayName,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${provider.description}\n${provider.integrationStatus.name}',
                ),
                trailing: controller.selectedProviderId == provider.id
                    ? const Icon(Icons.check_circle_outline)
                    : null,
                onTap: () => controller.selectProvider(provider.id),
              ),
            ),
          ),
          if (controller.selectedProvider case final provider?) ...[
            if (provider.supportsProfiles) ...[
              const Divider(),
              const Text('Connection profiles'),
              if (controller.profilesForProvider(provider.id).isEmpty)
                const ListTile(title: Text('No connection profiles')),
              ...controller
                  .profilesForProvider(provider.id)
                  .map(
                    (profile) => ListTile(
                      title: Text(profile.displayName),
                      subtitle: Text(
                        profile.isDefault
                            ? 'Default'
                            : profile.isEnabled
                            ? 'Enabled'
                            : 'Disabled',
                      ),
                      trailing: PopupMenuButton<String>(
                        onSelected: (action) async {
                          if (action == 'default') {
                            await controller.setDefaultProfile(profile.id);
                          }
                          if (action == 'toggle') {
                            await controller.toggleProfile(profile.id);
                          }
                          if (action == 'delete') {
                            await controller.deleteProfile(profile.id);
                          }
                          if (action == 'edit' && context.mounted) {
                            await profileDialog(
                              context,
                              controller,
                              provider,
                              profile,
                            );
                          }
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'edit', child: Text('Edit')),
                          PopupMenuItem(
                            value: 'default',
                            child: Text('Set default'),
                          ),
                          PopupMenuItem(
                            value: 'toggle',
                            child: Text('Enable / disable'),
                          ),
                          PopupMenuItem(value: 'delete', child: Text('Delete')),
                        ],
                      ),
                    ),
                  ),
              if (provider.id == 'remote_gateway')
                FilledButton.icon(
                  onPressed: () => connectGateway(
                    context,
                    app,
                    controller,
                    controller.defaultProfile ??
                        controller.profilesForProvider(provider.id).firstOrNull,
                  ),
                  icon: const Icon(Icons.link),
                  label: const Text('Connect'),
                ),
              FilledButton.icon(
                onPressed: () =>
                    profileDialog(context, controller, provider, null),
                icon: const Icon(Icons.add),
                label: const Text('Add profile'),
              ),
            ] else if (provider.supportsAuthentication)
              const ListTile(
                title: Text('Sign in unavailable'),
                subtitle: Text('Available in final integration phase.'),
              ),
          ],
        ],
      ),
    ),
  );
}

Future<void> connectGateway(
  BuildContext context,
  AppController app,
  ConnectionSettingsController settings,
  ConnectionProfile? profile,
) async {
  if (profile == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Add a gateway profile first.')),
    );
    return;
  }
  final endpoint = profile.values['endpoint'] as String? ?? '';
  final saved = await CredentialStore().load(profile.id);
  if (!context.mounted) return;
  final username = TextEditingController(text: saved?.username);
  final password = TextEditingController(text: saved?.password);
  final form = GlobalKey<FormState>();
  await showDialog<void>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text('Connect ${profile.displayName}'),
      content: Form(
        key: form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(endpoint.isEmpty ? 'Endpoint is required.' : endpoint),
            TextFormField(
              controller: username,
              decoration: const InputDecoration(labelText: 'Username'),
              validator: (v) => v?.trim().isEmpty ?? true ? 'Required' : null,
            ),
            TextFormField(
              controller: password,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Password'),
              validator: (v) => v?.isEmpty ?? true ? 'Required' : null,
            ),
            const Text('Credential disimpan Android Keystore.'),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialog),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: endpoint.isEmpty
              ? null
              : () async {
                  if (!(form.currentState?.validate() ?? false)) return;
                  await CredentialStore().save(
                    profile.id,
                    GatewayCredentials(username.text.trim(), password.text),
                  );
                  await app.connect(
                    HermesRemoteConnector(Uri.parse(endpoint), password.text),
                  );
                  if (!app.isDemo) {
                    await app.loadWorkspaces(
                      profile.values['workspacePath'] as String?,
                    );
                    if (app.workspacePath case final selected?) {
                      await settings.updateProfile(
                        profile.id,
                        profile.displayName,
                        {...profile.values, 'workspacePath': selected},
                      );
                    }
                  }
                  if (dialog.mounted) {
                    Navigator.pop(dialog);
                    if (app.connectorError != null) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(app.connectorError!)),
                      );
                    }
                  }
                },
          child: const Text('Connect'),
        ),
      ],
    ),
  );
}

Future<void> profileDialog(
  BuildContext context,
  ConnectionSettingsController controller,
  ConnectionProviderDefinition provider,
  ConnectionProfile? profile,
) async {
  final name = TextEditingController(text: profile?.displayName);
  final values = <String, Object?>{...?profile?.values};
  final form = GlobalKey<FormState>();
  await showDialog<void>(
    context: context,
    builder: (dialog) => StatefulBuilder(
      builder: (_, setState) => AlertDialog(
        title: Text(profile == null ? 'Add profile' : 'Edit profile'),
        content: Form(
          key: form,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: name,
                  decoration: const InputDecoration(labelText: 'Display name'),
                  validator: (v) =>
                      v?.trim().isEmpty ?? true ? 'Required' : null,
                ),
                ...provider.configurationFields.map((field) {
                  if (field.secret) {
                    return ListTile(
                      title: Text(field.label),
                      subtitle: const Text(
                        'Available in final integration phase',
                      ),
                    );
                  }
                  if (field.type == 'select') {
                    return DropdownButtonFormField<String>(
                      initialValue: values[field.id] as String?,
                      decoration: InputDecoration(labelText: field.label),
                      items: field.options
                          .map(
                            (x) => DropdownMenuItem(value: x, child: Text(x)),
                          )
                          .toList(),
                      onChanged: (v) => setState(() => values[field.id] = v),
                      validator: (v) =>
                          field.required && v == null ? 'Required' : null,
                    );
                  }
                  if (field.type == 'toggle') {
                    return SwitchListTile(
                      title: Text(field.label),
                      value: values[field.id] as bool? ?? false,
                      onChanged: (v) => setState(() => values[field.id] = v),
                    );
                  }
                  if (field.type == 'text') {
                    return TextFormField(
                      initialValue: values[field.id] as String?,
                      decoration: InputDecoration(
                        labelText: field.label,
                        hintText: field.placeholder,
                      ),
                      onChanged: (v) => values[field.id] = v,
                      validator: (v) => field.required && (v?.isEmpty ?? true)
                          ? 'Required'
                          : null,
                    );
                  }
                  return ListTile(
                    title: Text(field.label),
                    subtitle: const Text('Unsupported field'),
                  );
                }),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              if (!(form.currentState?.validate() ?? false)) return;
              if (profile == null) {
                await controller.addProfile(name.text, values);
              } else {
                await controller.updateProfile(profile.id, name.text, values);
              }
              if (dialog.mounted) Navigator.pop(dialog);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
}

IconData resolveConnectionIcon(String key) => switch (key) {
  'desktop' => Icons.desktop_windows_outlined,
  'cloud' => Icons.cloud_outlined,
  'remote' => Icons.hub_outlined,
  'usb' => Icons.usb,
  'network' => Icons.lan_outlined,
  'custom' => Icons.tune,
  _ => Icons.device_unknown,
};

Future<String?> ask(BuildContext c, String title, String initial) async {
  final t = TextEditingController(text: initial);
  return showDialog<String>(
    context: c,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: TextField(controller: t, autofocus: true),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(c, t.text),
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

Future<bool> confirm(BuildContext c, String title) async =>
    await showDialog<bool>(
      context: c,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: const Text(
          'This removes local history. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    ) ??
    false;
