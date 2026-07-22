import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'agent_connector.dart';
import 'app_controller.dart';
import 'local_store.dart';
import 'models.dart';
import 'connection.dart';
import 'clipboard_image.dart';
import 'background_task_monitor.dart';
import 'credential_store.dart';
import 'hermes_remote_connector.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AgentRemoteBootstrap());
}

class AgentRemoteBootstrap extends StatefulWidget {
  const AgentRemoteBootstrap({super.key});

  @override
  State<AgentRemoteBootstrap> createState() => _AgentRemoteBootstrapState();
}

class _AgentRemoteBootstrapState extends State<AgentRemoteBootstrap> {
  late final AppController controller;
  ConnectionSettingsController? connections;
  String stage = 'Menyiapkan Agent Remote';
  String detail = 'Memulai komponen aplikasi';
  double progress = .06;
  bool ready = false;

  @override
  void initState() {
    super.initState();
    controller = AppController(DemoAgentConnector(), LocalStore());
    unawaited(_bootstrap());
  }

  void _setStage(String nextStage, String nextDetail, double nextProgress) {
    if (!mounted) return;
    setState(() {
      stage = nextStage;
      detail = nextDetail;
      progress = nextProgress;
    });
  }

  Future<void> _bootstrap() async {
    _setStage('Menyiapkan notifikasi', 'Mengaktifkan monitor background', .12);
    try {
      await BackgroundTaskMonitor.initialize();
    } catch (_) {}
    _setStage('Memuat aplikasi', 'Membaca session dan folder terakhir', .24);
    try {
      await controller.initialize();
    } catch (error) {
      controller.connectorError = connectionErrorMessage(error);
    }

    ConnectionCatalog catalog;
    String? catalogError;
    _setStage('Memuat koneksi', 'Membaca profil PC tersimpan', .36);
    try {
      catalog = await ConnectionCatalog.loadAsset();
    } catch (_) {
      catalog = const ConnectionCatalog(1, []);
      catalogError = 'Connection catalog could not be loaded.';
    }
    final connectionStore = ConnectionProfileStore();
    var settings = ConnectionSettingsController(
      catalog,
      connectionStore,
      error: catalogError,
    );
    try {
      await settings.initialize();
    } catch (_) {
      settings = ConnectionSettingsController(
        catalog,
        connectionStore,
        error: 'Connection settings could not be loaded.',
      );
    }
    connections = settings;

    final profile = settings.defaultProfile;
    final endpoint = profile?.values['endpoint'] as String?;
    if (profile != null && endpoint != null && endpoint.isNotEmpty) {
      try {
        _setStage('Menghubungkan PC', endpoint, .52);
        final credentials = await CredentialStore().load(profile.id);
        await controller.connect(
          HermesRemoteConnector(
            Uri.parse(endpoint),
            credentials?.password ?? '',
          ),
        );
        if (!controller.isDemo) {
          _setStage('Memuat workspace', 'Mengembalikan folder terakhir', .70);
          await controller.loadWorkspaces(
            profile.values['workspacePath'] as String?,
          );
          _setStage('Sinkron task', 'Memuat session dan proses aktif', .88);
          await controller.restoreLastSession(
            await BackgroundTaskMonitor.consumeOpenSession(),
          );
        }
      } catch (error) {
        controller.connectorError = connectionErrorMessage(error);
      }
    }
    _setStage('Siap', 'Agent Remote siap digunakan', 1);
    if (mounted) setState(() => ready = true);
  }

  @override
  Widget build(BuildContext context) {
    final settings = connections;
    if (ready && settings != null) {
      return HermesRemoteApp(controller: controller, connections: settings);
    }
    return MaterialApp(
      title: 'Agent Remote',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
        cardTheme: const CardThemeData(
          elevation: 0,
          margin: EdgeInsets.symmetric(vertical: 4),
        ),
        appBarTheme: const AppBarTheme(surfaceTintColor: Colors.transparent),
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFF9DB2FF),
        useMaterial3: true,
      ),
      home: _StartupLoadingScreen(
        stage: stage,
        detail: detail,
        progress: progress,
      ),
    );
  }
}

class _StartupLoadingScreen extends StatelessWidget {
  const _StartupLoadingScreen({
    required this.stage,
    required this.detail,
    required this.progress,
  });
  final String stage;
  final String detail;
  final double progress;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  CircleAvatar(
                    radius: 34,
                    backgroundColor: colors.primaryContainer,
                    child: Icon(
                      Icons.terminal_rounded,
                      size: 34,
                      color: colors.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Agent Remote',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 28),
                  TweenAnimationBuilder<double>(
                    tween: Tween(end: progress),
                    duration: const Duration(milliseconds: 300),
                    builder: (_, value, _) => LinearProgressIndicator(
                      value: value,
                      minHeight: 6,
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    stage,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    detail,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
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
  Widget build(BuildContext context) => ValueListenableBuilder<ThemeModeChoice>(
    valueListenable: controller.themeMode,
    builder: (_, selectedTheme, _) => MaterialApp(
      title: 'Agent Remote',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
        cardTheme: const CardThemeData(
          elevation: 0,
          margin: EdgeInsets.symmetric(vertical: 4),
        ),
        appBarTheme: const AppBarTheme(surfaceTintColor: Colors.transparent),
      ),
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
      themeMode: switch (selectedTheme) {
        ThemeModeChoice.light => ThemeMode.light,
        ThemeModeChoice.dark => ThemeMode.dark,
        _ => ThemeMode.system,
      },
      home: ListenableBuilder(
        listenable: controller,
        builder: (_, _) => AppShell(controller, connections),
      ),
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
  final Set<int> _loadedPages = {};
  AppController get c => widget.c;
  ConnectionSettingsController get connections => widget.connections;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadedPages.add(c.page);
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
    final foreground = state == AppLifecycleState.resumed;
    c.setAppForeground(foreground);
    if (foreground) _restoreNotificationSession();
  }

  Future<void> _restoreNotificationSession() async {
    final sessionId = await BackgroundTaskMonitor.consumeOpenSession();
    if (sessionId != null && sessionId.isNotEmpty) {
      await c.restoreLastSession(sessionId);
    }
  }

  void _selectPage(int index) {
    setState(() => _loadedPages.add(index));
    c.setPage(index);
    if (index == 2 && c.connected) {
      unawaited(c.reloadWorkspaceData());
    }
  }

  Widget _pageAt(int index) => KeyedSubtree(
    key: ValueKey('root-page-$index'),
    child: switch (index) {
      0 => ChatsPage(c),
      1 => TasksPage(c),
      2 => FilesPage(c),
      3 => SettingsPage(c, connections),
      _ => UsagePage(c),
    },
  );

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
    final activeTasks =
        c.tasks
            .where(
              (task) => task.status == 'running' || task.status == 'queued',
            )
            .toList()
          ..sort((left, right) {
            final leftTime = left.updatedAt ?? left.createdAt;
            final rightTime = right.updatedAt ?? right.createdAt;
            return (rightTime?.millisecondsSinceEpoch ?? 0).compareTo(
              leftTime?.millisecondsSinceEpoch ?? 0,
            );
          });
    final latestTask = activeTasks.firstOrNull;
    _loadedPages.add(c.page);
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: Row(
          children: [
            _GithubAvatar(c.gitRepository, radius: 17),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    nav[c.page].$2,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  Text(
                    c.connected ? 'PC tersambung' : 'PC offline',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: c.connected
                          ? Colors.green.shade700
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          if (latestTask != null)
            IconButton(
              tooltip: 'Lihat task aktif',
              onPressed: () => _selectPage(1),
              icon: Badge(
                label: Text('${activeTasks.length}'),
                child: const Icon(Icons.bolt_rounded),
              ),
            ),
          const SizedBox(width: 4),
        ],
      ),
      body: Row(
        children: [
          if (wide)
            NavigationRail(
              selectedIndex: c.page,
              onDestinationSelected: _selectPage,
              labelType: NavigationRailLabelType.all,
              destinations: nav
                  .asMap()
                  .entries
                  .map(
                    (entry) => NavigationRailDestination(
                      icon: _RootNavIcon(
                        icon: entry.value.$1,
                        count: entry.key == 1
                            ? c.tasks
                                  .where(
                                    (task) =>
                                        task.status == 'running' ||
                                        task.status == 'queued',
                                  )
                                  .length
                            : 0,
                      ),
                      label: Text(entry.value.$2),
                    ),
                  )
                  .toList(),
            ),
          Expanded(
            child: IndexedStack(
              index: c.page,
              children: List.generate(
                nav.length,
                (index) => _loadedPages.contains(index)
                    ? _pageAt(index)
                    : const SizedBox.shrink(),
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: wide
          ? null
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (latestTask != null)
                  _GlobalTaskBar(
                    task: latestTask,
                    activeCount: activeTasks.length,
                    onTap: () => _selectPage(1),
                  ),
                NavigationBar(
                  selectedIndex: c.page,
                  onDestinationSelected: _selectPage,
                  destinations: nav
                      .asMap()
                      .entries
                      .map(
                        (entry) => NavigationDestination(
                          icon: _RootNavIcon(
                            icon: entry.value.$1,
                            count: entry.key == 1 ? activeTasks.length : 0,
                          ),
                          label: entry.value.$2,
                        ),
                      )
                      .toList(),
                ),
              ],
            ),
    );
  }
}

const nav = [
  (Icons.home_outlined, 'Beranda'),
  (Icons.task_alt, 'Proses'),
  (Icons.folder_outlined, 'File'),
  (Icons.settings_outlined, 'Setelan'),
  (Icons.monitor_heart_outlined, 'Token'),
];

class _RootNavIcon extends StatelessWidget {
  const _RootNavIcon({required this.icon, required this.count});
  final IconData icon;
  final int count;

  @override
  Widget build(BuildContext context) => count > 0
      ? Badge(label: Text(count > 9 ? '9+' : '$count'), child: Icon(icon))
      : Icon(icon);
}

class _GlobalTaskBar extends StatelessWidget {
  const _GlobalTaskBar({
    required this.task,
    required this.activeCount,
    required this.onTap,
  });

  final AgentTask task;
  final int activeCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final detail = task.activeAgentState?.detail.isNotEmpty == true
        ? task.activeAgentState!.detail
        : task.detail;
    return Material(
      color: colors.primaryContainer,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
          child: Row(
            children: [
              const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2.2),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$activeCount task aktif',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    Text(
                      detail.isEmpty ? task.title : detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading(this.title, {this.subtitle});
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.end,
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
            ),
            if (subtitle != null)
              Text(
                subtitle!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    ],
  );
}

class ChatsPage extends StatelessWidget {
  const ChatsPage(this.c, {super.key});
  final AppController c;

  @override
  Widget build(BuildContext context) {
    DateTime timestamp(AgentTask task) =>
        task.updatedAt ??
        task.createdAt ??
        DateTime.fromMillisecondsSinceEpoch(0);
    final activeTasks =
        c.tasks
            .where(
              (task) => task.status == 'running' || task.status == 'queued',
            )
            .toList()
          ..sort((left, right) => timestamp(right).compareTo(timestamp(left)));
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _HomeWorkspaceOverview(c: c, activeTasks: activeTasks),
          if (activeTasks.isNotEmpty) ...[
            const SizedBox(height: 8),
            _HomeActiveTasksCard(c: c, tasks: activeTasks),
          ],
          const SizedBox(height: 14),
          const _SectionHeading(
            'Semua session',
            subtitle: 'Percakapan tersimpan berdasarkan folder kerja.',
          ),
          const SizedBox(height: 8),
          SearchBar(
            hintText: 'Cari session',
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
                        const Center(child: Text('Belum ada session')),
                        Center(
                          child: FilledButton.icon(
                            onPressed: c.newSession,
                            icon: const Icon(Icons.add),
                            label: const Text('Session baru'),
                          ),
                        ),
                      ],
                    )
                  : ListView(
                      padding: const EdgeInsets.only(bottom: 20),
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
}

class _HomeWorkspaceOverview extends StatelessWidget {
  const _HomeWorkspaceOverview({required this.c, required this.activeTasks});
  final AppController c;
  final List<AgentTask> activeTasks;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final path = c.workspacePath ?? '';
    final parts = path.split(RegExp(r'[\\/]')).where((part) => part.isNotEmpty);
    final workspaceName = parts.isEmpty ? 'Semua folder PC' : parts.last;
    final statusColor = c.connected ? Colors.green.shade600 : colors.outline;
    final connector = c.connector;
    final remote = connector is HermesRemoteConnector ? connector : null;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Sessions',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                workspaceName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: statusColor.withValues(alpha: .12),
            borderRadius: BorderRadius.circular(99),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                c.connected
                    ? Icons.cloud_done_outlined
                    : Icons.cloud_off_outlined,
                size: 16,
                color: statusColor,
              ),
              const SizedBox(width: 4),
              Text(
                c.connected ? 'PC aktif' : 'Offline',
                style: TextStyle(
                  color: statusColor,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 4),
        PopupMenuButton<String>(
          tooltip: 'Kategori dan pengaturan',
          icon: const Icon(Icons.tune_rounded),
          onSelected: (value) {
            if (remote == null) return;
            switch (value) {
              case 'folder':
                showFolderSheet(context, c, remote);
              case 'agent':
                showAgentSheet(context, c, remote);
              case 'task':
                if (activeTasks.isNotEmpty) c.openTask(activeTasks.first);
            }
          },
          itemBuilder: (context) => [
            if (remote != null) ...[
              PopupMenuItem(
                value: 'folder',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.folder_outlined),
                  title: const Text('Folder kerja'),
                  subtitle: Text(workspaceName),
                ),
              ),
              PopupMenuItem(
                value: 'agent',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.smart_toy_outlined),
                  title: const Text('Agent'),
                  subtitle: Text('${remote.selectedAgentIds.length} dipilih'),
                ),
              ),
            ],
            if (activeTasks.isNotEmpty)
              PopupMenuItem(
                value: 'task',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.bolt_rounded),
                  title: const Text('Task aktif'),
                  subtitle: Text('${activeTasks.length} sedang berjalan'),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _HomeActiveTasksCard extends StatelessWidget {
  const _HomeActiveTasksCard({required this.c, required this.tasks});
  final AppController c;
  final List<AgentTask> tasks;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final latest = tasks.first;
    final activeAgent = latest.activeAgentState;
    final runningAgents = tasks
        .expand((task) => task.agentStates)
        .where((state) => state.status == 'running')
        .length;
    return OutlinedButton(
      onPressed: latest.sessionId.isEmpty ? null : () => c.openTask(latest),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        alignment: Alignment.centerLeft,
        side: BorderSide(color: colors.primary.withValues(alpha: .35)),
        backgroundColor: colors.primaryContainer.withValues(alpha: .22),
      ),
      child: Row(
        children: [
          SizedBox.square(
            dimension: 28,
            child: Stack(
              alignment: Alignment.center,
              children: [
                CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: colors.primary,
                ),
                Icon(Icons.bolt, size: 15, color: colors.primary),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${tasks.length} task aktif • $runningAgents agent berjalan',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                Text(
                  activeAgent?.detail.isNotEmpty == true
                      ? '${activeAgent!.name}: ${activeAgent.detail}'
                      : latest.detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (latest.sessionId.isNotEmpty)
            const Padding(
              padding: EdgeInsets.only(left: 8),
              child: Icon(Icons.arrow_forward, size: 18),
            ),
        ],
      ),
    );
  }
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
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Pilih agent PC',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                  Badge(
                    label: Text(
                      '${remote.availableAgents.where((agent) => agent.installed).length}',
                    ),
                    child: const Icon(Icons.smart_toy_outlined),
                  ),
                ],
              ),
              Text(
                '${remote.selectedAgentIds.length} agent dipilih • ${remote.concurrencyLimit} berjalan bersamaan • batas server ${remote.maxConcurrentAgents}.',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Mode eksekusi',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: RemoteExecutionMode.values
                    .map(
                      (mode) => ChoiceChip(
                        selected: remote.executionMode == mode,
                        avatar: Icon(_executionModeIcon(mode), size: 18),
                        label: Text(_executionModeLabel(mode)),
                        onSelected: (_) {
                          setSheetState(() => _setExecutionMode(remote, mode));
                          app.refresh();
                        },
                      ),
                    )
                    .toList(),
              ),
              const SizedBox(height: 8),
              _AgentModeSummary(
                mode: remote.executionMode,
                maxConcurrentAgents: remote.maxConcurrentAgents,
                concurrencyLimit: remote.concurrencyLimit,
              ),
              if (remote.executionMode != RemoteExecutionMode.single) ...[
                const SizedBox(height: 10),
                Text(
                  'Batas proses PC',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (
                      var value = 1;
                      value <= remote.maxConcurrentAgents;
                      value++
                    )
                      ChoiceChip(
                        selected: remote.concurrencyLimit == value,
                        label: Text(
                          value == 1
                              ? 'Hemat 1'
                              : value == 2
                              ? 'Normal 2'
                              : '$value agent',
                        ),
                        onSelected: (_) {
                          setSheetState(() => remote.concurrencyLimit = value);
                          app.refresh();
                        },
                      ),
                  ],
                ),
              ],
              if (remote.executionMode == RemoteExecutionMode.coordinator &&
                  remote.selectedAgentIds.isNotEmpty) ...[
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue:
                      remote.selectedAgentIds.contains(
                        remote.coordinatorAgentId,
                      )
                      ? remote.coordinatorAgentId
                      : remote.selectedAgentIds.first,
                  decoration: const InputDecoration(
                    labelText: 'Agent koordinator',
                    prefixIcon: Icon(Icons.account_tree_outlined),
                    border: OutlineInputBorder(),
                  ),
                  items: remote.availableAgents
                      .where(
                        (agent) =>
                            agent.installed &&
                            remote.selectedAgentIds.contains(agent.id),
                      )
                      .map(
                        (agent) => DropdownMenuItem(
                          value: agent.id,
                          child: Text(agent.name),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value == null) return;
                    setSheetState(() => remote.coordinatorAgentId = value);
                    app.refresh();
                  },
                ),
              ],
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
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Agent tersedia',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  Text('${remote.selectedAgentIds.length} dipilih'),
                ],
              ),
              const SizedBox(height: 6),
              Column(
                children: [
                  if (remote.availableAgents.isEmpty)
                    const Card(
                      child: ListTile(
                        leading: Icon(Icons.search_off_outlined),
                        title: Text('Belum ada agent terdeteksi'),
                        subtitle: Text(
                          'Pastikan CLI agent terpasang dan server PC dimulai ulang.',
                        ),
                      ),
                    ),
                  ...(remote.availableAgents.toList()..sort((left, right) {
                        if (left.installed != right.installed) {
                          return left.installed ? -1 : 1;
                        }
                        return left.name.toLowerCase().compareTo(
                          right.name.toLowerCase(),
                        );
                      }))
                      .map(
                        (agent) => _AgentSelectionCard(
                          agent: agent,
                          selected: remote.selectedAgentIds.contains(agent.id),
                          single:
                              remote.executionMode ==
                              RemoteExecutionMode.single,
                          onTap: agent.installed
                              ? () {
                                  setSheetState(
                                    () => _toggleAgentSelection(remote, agent),
                                  );
                                  app.refresh();
                                }
                              : null,
                        ),
                      ),
                ],
              ),
              FilledButton(
                onPressed: remote.selectedAgentIds.isEmpty
                    ? null
                    : () => Navigator.pop(sheetContext),
                child: Text(
                  remote.selectedAgentIds.isEmpty
                      ? 'Pilih minimal satu agent'
                      : 'Gunakan ${remote.selectedAgentIds.length} agent',
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  ),
);

class _AgentModeSummary extends StatelessWidget {
  const _AgentModeSummary({
    required this.mode,
    required this.maxConcurrentAgents,
    required this.concurrencyLimit,
  });
  final RemoteExecutionMode mode;
  final int maxConcurrentAgents;
  final int concurrencyLimit;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final color = mode == RemoteExecutionMode.single
        ? Colors.green.shade700
        : mode == RemoteExecutionMode.parallel
        ? colors.tertiary
        : colors.primary;
    return Card(
      color: color.withValues(alpha: .08),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: color.withValues(alpha: .24)),
      ),
      child: ListTile(
        dense: true,
        leading: Icon(_executionModeIcon(mode), color: color),
        title: Text(
          _executionModeDescription(
            mode,
            concurrencyLimit,
            maxConcurrentAgents,
          ),
        ),
        subtitle: Text(
          _executionModeTokenNote(mode),
          style: TextStyle(color: color, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}

class _AgentSelectionCard extends StatelessWidget {
  const _AgentSelectionCard({
    required this.agent,
    required this.selected,
    required this.single,
    required this.onTap,
  });
  final RemoteAgentInfo agent;
  final bool selected;
  final bool single;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final statusColor = agent.installed
        ? Colors.green.shade700
        : colors.outline;
    return Card(
      color: selected ? colors.primaryContainer.withValues(alpha: .42) : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: selected ? colors.primary : colors.outlineVariant,
          width: selected ? 1.5 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        enabled: agent.installed,
        selected: selected,
        onTap: onTap,
        leading: CircleAvatar(
          backgroundColor: statusColor.withValues(alpha: .12),
          child: Icon(
            agent.installed ? Icons.terminal_outlined : Icons.download_outlined,
            color: statusColor,
          ),
        ),
        title: Text(
          agent.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (agent.description.isNotEmpty)
              Text(
                agent.description,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            Text(
              agent.installed
                  ? '${agent.supportsStreaming ? 'Streaming live' : 'Output standar'} • ${agent.command}'
                  : 'CLI belum ditemukan pada PC',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: statusColor),
            ),
          ],
        ),
        trailing: Icon(
          selected
              ? Icons.check_circle
              : single
              ? Icons.radio_button_unchecked
              : Icons.add_circle_outline,
          color: selected ? colors.primary : null,
        ),
      ),
    );
  }
}

void _setExecutionMode(HermesRemoteConnector remote, RemoteExecutionMode mode) {
  remote.executionMode = mode;
  remote.concurrencyLimit = mode == RemoteExecutionMode.single
      ? 1
      : remote.concurrencyLimit < 2
      ? remote.maxConcurrentAgents.clamp(1, 2)
      : remote.concurrencyLimit.clamp(1, remote.maxConcurrentAgents);
  if (remote.selectedAgentIds.isEmpty) {
    final firstInstalled = remote.availableAgents
        .where((agent) => agent.installed)
        .firstOrNull;
    if (firstInstalled != null) remote.selectedAgentIds = {firstInstalled.id};
  }
  if (mode == RemoteExecutionMode.single &&
      remote.selectedAgentIds.length > 1) {
    final selected = remote.selectedAgentIds;
    final keep = selected.contains(remote.coordinatorAgentId)
        ? remote.coordinatorAgentId
        : selected.first;
    remote.selectedAgentIds = {keep};
  }
  if (!remote.selectedAgentIds.contains(remote.coordinatorAgentId)) {
    remote.coordinatorAgentId = remote.selectedAgentIds.firstOrNull ?? '';
  }
}

void _toggleAgentSelection(
  HermesRemoteConnector remote,
  RemoteAgentInfo agent,
) {
  if (!agent.installed) return;
  if (remote.executionMode == RemoteExecutionMode.single) {
    remote.selectedAgentIds = {agent.id};
  } else if (remote.selectedAgentIds.contains(agent.id)) {
    if (remote.selectedAgentIds.length > 1) {
      remote.selectedAgentIds = {...remote.selectedAgentIds}..remove(agent.id);
    }
  } else {
    remote.selectedAgentIds = {...remote.selectedAgentIds, agent.id};
  }
  if (!remote.selectedAgentIds.contains(remote.coordinatorAgentId)) {
    remote.coordinatorAgentId = remote.selectedAgentIds.firstOrNull ?? '';
  }
}

String _executionModeLabel(RemoteExecutionMode mode) => switch (mode) {
  RemoteExecutionMode.single => 'Hemat',
  RemoteExecutionMode.parallel => 'Multi-agent',
  RemoteExecutionMode.coordinator => 'Koordinator',
};

IconData _executionModeIcon(RemoteExecutionMode mode) => switch (mode) {
  RemoteExecutionMode.single => Icons.person_outline,
  RemoteExecutionMode.parallel => Icons.groups_outlined,
  RemoteExecutionMode.coordinator => Icons.account_tree_outlined,
};

String _executionModeDescription(
  RemoteExecutionMode mode,
  int concurrencyLimit,
  int maxConcurrentAgents,
) => switch (mode) {
  RemoteExecutionMode.single => 'Satu agent aktif. Beban PC paling rendah.',
  RemoteExecutionMode.parallel =>
    '$concurrencyLimit agent aktif bersamaan, sisanya antre. Batas server $maxConcurrentAgents.',
  RemoteExecutionMode.coordinator =>
    '$concurrencyLimit worker aktif bersamaan, lalu koordinator menyatukan hasil.',
};

String _executionModeTokenNote(RemoteExecutionMode mode) => switch (mode) {
  RemoteExecutionMode.single => 'Pemakaian token normal.',
  RemoteExecutionMode.parallel =>
    'Token bertambah sesuai jumlah agent yang dijalankan.',
  RemoteExecutionMode.coordinator =>
    'Token lebih besar karena worker dan koordinator sama-sama berjalan.',
};

Future<void> showFolderSheet(
  BuildContext context,
  AppController app,
  HermesRemoteConnector remote,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  builder: (sheetContext) => _FolderPickerSheet(app: app, remote: remote),
);

class _FolderPickerSheet extends StatefulWidget {
  const _FolderPickerSheet({required this.app, required this.remote});
  final AppController app;
  final HermesRemoteConnector remote;

  @override
  State<_FolderPickerSheet> createState() => _FolderPickerSheetState();
}

class _FolderPickerSheetState extends State<_FolderPickerSheet> {
  final searchController = TextEditingController();
  PcFolderListing? listing;
  bool loading = true;
  bool selecting = false;
  String query = '';
  String? error;
  int requestId = 0;

  @override
  void initState() {
    super.initState();
    _load(widget.app.workspacePath ?? '');
  }

  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }

  Future<void> _load(String path) async {
    final currentRequest = ++requestId;
    if (mounted) setState(() => loading = true);
    try {
      final next = await widget.remote.browsePcFolders(path);
      if (!mounted || currentRequest != requestId) return;
      searchController.clear();
      setState(() {
        listing = next;
        query = '';
        error = null;
        loading = false;
      });
    } catch (exception) {
      if (!mounted || currentRequest != requestId) return;
      setState(() {
        error = _folderPickerError(exception);
        loading = false;
      });
    }
  }

  Future<void> _selectFolder() async {
    final path = listing?.path ?? '';
    if (path.isEmpty || selecting) return;
    setState(() {
      selecting = true;
      error = null;
    });
    try {
      await widget.app.selectWorkspace(path);
      if (mounted) Navigator.pop(context);
    } catch (exception) {
      if (!mounted) return;
      setState(() {
        selecting = false;
        error = _folderPickerError(exception);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final currentListing = listing;
    final normalizedQuery = query.trim().toLowerCase();
    final folders =
        (currentListing?.folders ?? const <AgentWorkspace>[])
            .where(
              (folder) =>
                  normalizedQuery.isEmpty ||
                  folder.name.toLowerCase().contains(normalizedQuery) ||
                  folder.path.toLowerCase().contains(normalizedQuery),
            )
            .toList()
          ..sort(
            (left, right) =>
                left.name.toLowerCase().compareTo(right.name.toLowerCase()),
          );
    final path = currentListing?.path ?? '';
    final isCurrentWorkspace =
        path.isNotEmpty && path == widget.app.workspacePath;
    final availableHeight =
        MediaQuery.sizeOf(context).height -
        MediaQuery.viewInsetsOf(context).bottom;
    return SafeArea(
      child: SizedBox(
        height: availableHeight * .9,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Pilih folder PC',
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        Text(
                          'Bebas pilih disk atau folder kerja yang tersedia.',
                          style: TextStyle(color: colors.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Tutup',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            if (loading) const LinearProgressIndicator(minHeight: 2),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Card(
                child: ListTile(
                  leading: Icon(
                    path.isEmpty
                        ? Icons.storage_outlined
                        : Icons.folder_open_outlined,
                  ),
                  title: Text(
                    path.isEmpty ? 'Disk dan drive PC' : path,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: isCurrentWorkspace
                      ? const Text('Folder aktif terakhir')
                      : null,
                  trailing: IconButton(
                    tooltip: 'Pilih disk',
                    onPressed: loading ? null : () => _load(''),
                    icon: const Icon(Icons.dns_outlined),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: SearchBar(
                controller: searchController,
                hintText: 'Cari folder pada lokasi ini',
                leading: const Icon(Icons.search),
                trailing: [
                  if (query.isNotEmpty)
                    IconButton(
                      tooltip: 'Hapus pencarian',
                      onPressed: () {
                        searchController.clear();
                        setState(() => query = '');
                      },
                      icon: const Icon(Icons.close),
                    ),
                ],
                onChanged: (value) => setState(() => query = value),
              ),
            ),
            Expanded(
              child: _FolderPickerList(
                listing: currentListing,
                folders: folders,
                loading: loading,
                error: error,
                query: query,
                onRetry: () => _load(path),
                onOpen: _load,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: path.isEmpty || loading || selecting
                      ? null
                      : _selectFolder,
                  icon: selecting
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.folder_special_outlined),
                  label: Text(
                    selecting
                        ? 'Mengaktifkan folder...'
                        : isCurrentWorkspace
                        ? 'Gunakan folder aktif'
                        : 'Gunakan folder ini',
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FolderPickerList extends StatelessWidget {
  const _FolderPickerList({
    required this.listing,
    required this.folders,
    required this.loading,
    required this.error,
    required this.query,
    required this.onRetry,
    required this.onOpen,
  });
  final PcFolderListing? listing;
  final List<AgentWorkspace> folders;
  final bool loading;
  final String? error;
  final String query;
  final VoidCallback onRetry;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (listing == null && loading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 12),
            Text('Memuat folder PC...'),
          ],
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      children: [
        if (error case final message?)
          Card(
            color: colors.errorContainer,
            child: ListTile(
              leading: Icon(Icons.error_outline, color: colors.error),
              title: const Text('Folder tidak dapat dimuat'),
              subtitle: Text(message),
              trailing: IconButton(
                tooltip: 'Coba lagi',
                onPressed: loading ? null : onRetry,
                icon: const Icon(Icons.refresh),
              ),
            ),
          ),
        if (listing?.parent case final parent?)
          Card(
            child: ListTile(
              enabled: !loading,
              leading: const Icon(Icons.drive_folder_upload_outlined),
              title: const Text('Folder induk'),
              subtitle: Text(
                parent,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: const Icon(Icons.arrow_upward),
              onTap: loading ? null : () => onOpen(parent),
            ),
          ),
        if (!loading && folders.isEmpty)
          Card(
            child: ListTile(
              leading: Icon(
                query.trim().isEmpty
                    ? Icons.folder_off_outlined
                    : Icons.search_off_outlined,
              ),
              title: Text(
                query.trim().isEmpty
                    ? 'Tidak ada subfolder'
                    : 'Folder tidak ditemukan',
              ),
              subtitle: Text(
                query.trim().isEmpty
                    ? 'Folder ini tetap dapat dipilih sebagai workspace.'
                    : 'Ubah kata pencarian atau hapus filter.',
              ),
            ),
          ),
        ...folders.map(
          (folder) => Card(
            child: ListTile(
              enabled: !loading,
              leading: const Icon(Icons.folder_outlined),
              title: Text(
                folder.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                folder.path,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: loading ? null : () => onOpen(folder.path),
            ),
          ),
        ),
      ],
    );
  }
}

String _folderPickerError(Object exception) {
  final message = exception.toString().trim();
  if (message.isEmpty) return 'Kesalahan tidak diketahui.';
  return message
      .replaceFirst('Bad state: ', '')
      .replaceFirst('StateError: ', '');
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
    bool sessionRunning(AgentSession session) =>
        session.status == SessionStatus.generating ||
        c.tasks.any(
          (task) =>
              task.sessionId == session.id &&
              (task.status == 'running' || task.status == 'queued'),
        );
    sessions.sort((left, right) {
      final leftRunning = sessionRunning(left);
      final rightRunning = sessionRunning(right);
      if (leftRunning != rightRunning) return rightRunning ? 1 : -1;
      return right.updatedAt.compareTo(left.updatedAt);
    });
    if (query.isNotEmpty && sessions.isEmpty) return const SizedBox.shrink();
    final active = project.workspace.path == c.workspacePath;
    final sessionIds = project.sessions.map((session) => session.id).toSet();
    final activeTasks = c.tasks
        .where(
          (task) =>
              sessionIds.contains(task.sessionId) &&
              (task.status == 'running' || task.status == 'queued'),
        )
        .toList();
    final activeAgents = activeTasks
        .expand((task) => task.agentStates)
        .where((state) => state.status == 'running')
        .length;
    final colors = Theme.of(context).colorScheme;
    return Card(
      color: active || activeTasks.isNotEmpty
          ? colors.surfaceContainerHigh
          : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(
          color: activeTasks.isNotEmpty
              ? colors.primary.withValues(alpha: .45)
              : colors.outlineVariant,
        ),
      ),
      child: ExpansionTile(
        key: PageStorageKey('project-${project.workspace.path}'),
        initiallyExpanded: active || activeTasks.isNotEmpty || query.isNotEmpty,
        leading: Icon(
          activeTasks.isNotEmpty
              ? Icons.folder_special_outlined
              : active
              ? Icons.folder_open_outlined
              : Icons.folder_outlined,
          color: activeTasks.isNotEmpty ? colors.primary : null,
        ),
        title: Text(project.workspace.name),
        subtitle: Text(
          activeTasks.isEmpty
              ? project.workspace.path
              : '${activeTasks.length} task aktif • $activeAgents agent berjalan\n${project.workspace.path}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (project.isGitRepository)
              Tooltip(
                message: 'Git repository terdeteksi',
                child: Icon(
                  Icons.account_tree_outlined,
                  size: 18,
                  color: colors.secondary,
                ),
              ),
            if (project.isGitRepository) const SizedBox(width: 10),
            if (activeTasks.isNotEmpty)
              Badge(
                label: Text('${activeTasks.length}'),
                child: Icon(Icons.bolt, color: colors.primary),
              ),
            if (activeTasks.isNotEmpty) const SizedBox(width: 12),
            Icon(
              active ? Icons.radio_button_checked : Icons.expand_more,
              size: 20,
            ),
          ],
        ),
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
          (item) =>
              item.sessionId == session.id &&
              (item.status == 'running' || item.status == 'queued'),
        )
        .firstOrNull;
    final running = task != null || session.status == SessionStatus.generating;
    final activeAgent = task?.activeAgentState;
    final runningAgents =
        task?.agentStates.where((state) => state.status == 'running').length ??
        0;
    final colors = Theme.of(context).colorScheme;
    final messageCount = session.messageCount > 0
        ? session.messageCount
        : session.messages.length;
    final preview = session.preview.trim().isNotEmpty
        ? session.preview.trim()
        : session.messages.lastOrNull?.content.trim() ?? '';
    final needsAttention =
        session.status == SessionStatus.waitingApproval ||
        session.status == SessionStatus.waitingClarification ||
        session.status == SessionStatus.failed;
    final statusColor = running
        ? colors.primary
        : _sessionStatusColor(colors, session.status);
    final queued = task?.status == 'queued' && runningAgents == 0;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      margin: const EdgeInsets.fromLTRB(24, 3, 8, 3),
      decoration: BoxDecoration(
        color: running
            ? colors.primaryContainer.withValues(alpha: .28)
            : needsAttention
            ? statusColor.withValues(alpha: .08)
            : null,
        borderRadius: BorderRadius.circular(14),
        border: running || needsAttention
            ? Border(left: BorderSide(color: statusColor, width: 4))
            : null,
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 6,
          ),
          leading: running
              ? SizedBox.square(
                  dimension: 30,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: statusColor,
                      ),
                      Icon(
                        queued ? Icons.schedule_rounded : Icons.bolt,
                        size: 16,
                        color: statusColor,
                      ),
                    ],
                  ),
                )
              : CircleAvatar(
                  radius: 16,
                  backgroundColor: statusColor.withValues(alpha: .1),
                  child: Icon(
                    _sessionStatusIcon(session.status, session.isPinned),
                    size: 18,
                    color: statusColor,
                  ),
                ),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (running)
                Text(
                  queued ? 'MENUNGGU GILIRAN' : 'SEDANG MENGERJAKAN',
                  style: TextStyle(
                    color: statusColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: .7,
                  ),
                ),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      session.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: running || needsAttention
                            ? FontWeight.w700
                            : null,
                      ),
                    ),
                  ),
                  if (session.isPinned) ...[
                    const SizedBox(width: 6),
                    Tooltip(
                      message: 'Session disematkan',
                      child: Icon(
                        Icons.push_pin_rounded,
                        size: 16,
                        color: colors.primary,
                      ),
                    ),
                  ],
                ],
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
                      activeAgent?.detail.isNotEmpty == true
                          ? activeAgent!.detail
                          : task?.detail.isNotEmpty == true
                          ? task!.detail
                          : 'Agent sedang berpikir...',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (task != null)
                      Text(
                        '${task.agentStates.isEmpty ? task.agents.join(' + ') : '$runningAgents/${task.agentStates.length} agent'} • ${activeAgent?.name ?? 'Menunggu agent'} • ${_taskPhaseLabel(activeAgent?.phase ?? 'preparing')} • ${formatElapsedDuration(task.elapsedSeconds)}',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (preview.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        preview,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 5,
                      children: [
                        _SessionMetaBadge(
                          icon: _sessionStatusIcon(
                            session.status,
                            session.isPinned,
                          ),
                          label: _sessionStatusLabel(
                            session.status,
                            empty: messageCount == 0,
                          ),
                          color: statusColor,
                        ),
                        if (session.activeModelName?.trim().isNotEmpty == true)
                          _SessionMetaBadge(
                            icon: Icons.smart_toy_outlined,
                            label: session.activeModelName!.trim(),
                            color: colors.secondary,
                          ),
                        _SessionMetaBadge(
                          icon: Icons.chat_bubble_outline,
                          label: '$messageCount pesan',
                          color: colors.onSurfaceVariant,
                        ),
                        _SessionMetaBadge(
                          icon: Icons.schedule_outlined,
                          label: _sessionUpdatedLabel(session.updatedAt),
                          color: colors.onSurfaceVariant,
                        ),
                      ],
                    ),
                  ],
                ),
          trailing: Icon(running ? Icons.arrow_forward : Icons.chevron_right),
          onTap: () => c.openProjectSession(project, session),
        ),
      ),
    );
  }
}

class _SessionMetaBadge extends StatelessWidget {
  const _SessionMetaBadge({
    required this.icon,
    required this.label,
    required this.color,
  });
  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .08),
      borderRadius: BorderRadius.circular(999),
      border: Border.all(color: color.withValues(alpha: .16)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    ),
  );
}

String _sessionStatusLabel(SessionStatus status, {required bool empty}) =>
    switch (status) {
      SessionStatus.idle => empty ? 'Baru' : 'Selesai',
      SessionStatus.generating => 'Berjalan',
      SessionStatus.waitingApproval => 'Butuh approval',
      SessionStatus.waitingClarification => 'Butuh jawaban',
      SessionStatus.stopped => 'Dihentikan',
      SessionStatus.failed => 'Gagal',
    };

Color _sessionStatusColor(ColorScheme colors, SessionStatus status) =>
    switch (status) {
      SessionStatus.idle => Colors.green.shade700,
      SessionStatus.generating => colors.primary,
      SessionStatus.waitingApproval ||
      SessionStatus.waitingClarification => Colors.orange.shade800,
      SessionStatus.stopped => colors.outline,
      SessionStatus.failed => colors.error,
    };

IconData _sessionStatusIcon(SessionStatus status, bool pinned) {
  if (pinned && status == SessionStatus.idle) return Icons.push_pin_outlined;
  return switch (status) {
    SessionStatus.idle => Icons.check_circle_outline,
    SessionStatus.generating => Icons.bolt,
    SessionStatus.waitingApproval => Icons.approval_outlined,
    SessionStatus.waitingClarification => Icons.help_outline,
    SessionStatus.stopped => Icons.stop_circle_outlined,
    SessionStatus.failed => Icons.error_outline,
  };
}

String _sessionUpdatedLabel(DateTime value) {
  final local = value.toLocal();
  final now = DateTime.now();
  final date = DateTime(local.year, local.month, local.day);
  final today = DateTime(now.year, now.month, now.day);
  final clock = formatLocalClock(local);
  if (date == today) return 'Hari ini $clock';
  if (date == today.subtract(const Duration(days: 1))) {
    return 'Kemarin $clock';
  }
  final day = local.day.toString().padLeft(2, '0');
  final month = local.month.toString().padLeft(2, '0');
  return '$day/$month/${local.year} $clock';
}

String _taskPermissionLabel(String permission) => switch (permission) {
  'ask' => 'Ask approval',
  'full' => 'Full access',
  _ => 'Workspace access',
};

String _taskPhaseLabel(String phase) => switch (phase) {
  'queued' => 'Menunggu antrean',
  'preparing' => 'Menyiapkan',
  'thinking' => 'Menganalisis',
  'running_command' => 'Menjalankan command',
  'editing' => 'Mengubah file',
  'testing' => 'Menjalankan verifikasi',
  'responding' => 'Menyusun respons',
  'coordinating' => 'Koordinasi agent',
  'completed' => 'Selesai',
  'failed' => 'Gagal',
  'stopped' => 'Dihentikan',
  _ => phase,
};

String _taskRoleLabel(String role) => switch (role) {
  'coordinator' => 'Coordinator',
  'worker' => 'Worker',
  _ => 'Agent',
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

class _ChatContextBar extends StatelessWidget {
  const _ChatContextBar({
    required this.session,
    required this.task,
    required this.workspacePath,
  });
  final AgentSession session;
  final AgentTask? task;
  final String workspacePath;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final folderParts = workspacePath
        .split(RegExp(r'[\\/]'))
        .where((part) => part.isNotEmpty);
    final folder = folderParts.isEmpty
        ? 'Folder belum dipilih'
        : folderParts.last;
    final agentLabel = task?.agentStates.isNotEmpty == true
        ? task!.agentStates.map((state) => state.name).join(' + ')
        : session.activeModelName ?? 'Agent PC';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: .55),
        border: Border(bottom: BorderSide(color: colors.outlineVariant)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _ContextChip(icon: Icons.folder_outlined, label: folder),
            const SizedBox(width: 7),
            _ContextChip(icon: Icons.smart_toy_outlined, label: agentLabel),
            if (task != null) ...[
              const SizedBox(width: 7),
              _ContextChip(
                icon: Icons.hub_outlined,
                label:
                    '${_taskModeLabel(task!.mode)} • ${task!.concurrency} slot',
              ),
              const SizedBox(width: 7),
              _ContextChip(
                icon: Icons.security_outlined,
                label: _taskPermissionLabel(task!.permission),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ContextChip extends StatelessWidget {
  const _ContextChip({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(99),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15),
        const SizedBox(width: 5),
        Text(label, style: Theme.of(context).textTheme.labelMedium),
      ],
    ),
  );
}

class _ChatScreenState extends State<ChatScreen> {
  final text = TextEditingController();
  final messageScroll = ScrollController();
  final pending = <AgentAttachment>[];
  bool submitting = false;
  bool awayFromLatest = false;
  int unseenMessages = 0;
  int trackedMessageCount = 0;
  String? trackedSessionId;
  String? trackedLatestMessageId;

  @override
  void initState() {
    super.initState();
    messageScroll.addListener(_handleMessageScroll);
  }

  @override
  void dispose() {
    messageScroll
      ..removeListener(_handleMessageScroll)
      ..dispose();
    text.dispose();
    super.dispose();
  }

  Future<void> _showSessionSwitcher() async {
    final c = widget.c;
    final selected = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: DraggableScrollableSheet(
          expand: false,
          initialChildSize: .72,
          minChildSize: .42,
          maxChildSize: .92,
          builder: (context, scrollController) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Session folder ini',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Session baru',
                      onPressed: () => Navigator.pop(sheetContext, '__new__'),
                      icon: const Icon(Icons.add_comment_outlined),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  controller: scrollController,
                  itemCount: c.sessions.length,
                  itemBuilder: (_, index) {
                    final session = c.sessions[index];
                    final active = session.id == c.currentId;
                    return ListTile(
                      selected: active,
                      leading: Icon(
                        session.status == SessionStatus.generating
                            ? Icons.bolt_rounded
                            : Icons.chat_bubble_outline,
                      ),
                      title: Text(
                        session.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        session.preview.isEmpty
                            ? _sessionStatusLabel(
                                session.status,
                                empty: session.messageCount == 0,
                              )
                            : session.preview,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: active
                          ? const Icon(Icons.check_circle_outline)
                          : null,
                      onTap: () => Navigator.pop(sheetContext, session.id),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || selected == null) return;
    if (selected == '__new__') {
      await c.newSession();
      return;
    }
    final session = c.sessions.where((item) => item.id == selected).firstOrNull;
    if (session != null && session.id != c.currentId) await c.open(session);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c, s = c.current!;
    _trackSessionMessages(s);
    final sessionTasks = c.tasks.where((task) => task.sessionId == s.id);
    final activeTask = sessionTasks
        .where((task) => task.status == 'running' || task.status == 'queued')
        .firstOrNull;
    final sessionTask = activeTask ?? sessionTasks.firstOrNull;
    final activeAgent = activeTask?.activeAgentState;
    final connectionSubtitle = c.isDemo
        ? 'Demo Mode • lokal'
        : activeAgent != null
        ? '${activeAgent.name} • ${_taskPhaseLabel(activeAgent.phase)}'
        : c.capabilities.supportsAgentExecution
        ? '${s.activeModelName ?? 'PC Agent'} • Terhubung'
        : 'Remote composer • dikirim ke PC';
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: c.closeCurrentSession),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(s.title),
            Text(
              connectionSubtitle,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Pilih session',
            onPressed: _showSessionSwitcher,
            icon: const Icon(Icons.forum_outlined),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            _ChatContextBar(
              session: s,
              task: sessionTask,
              workspacePath: c.workspacePath ?? '',
            ),
            if (sessionTask != null ||
                s.activities.isNotEmpty ||
                s.status == SessionStatus.generating)
              ActivitySummaryCard(s, task: sessionTask),
            Expanded(
              child: c.loadingSession
                  ? const Center(child: CircularProgressIndicator())
                  : Stack(
                      children: [
                        Positioned.fill(
                          child: ListView.builder(
                            key: const ValueKey('chat-message-list'),
                            controller: messageScroll,
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
                                      s.messages.last.role !=
                                          MessageRole.assistant);
                              if (showRunning && i == 0) {
                                return _RunningAgentCard(task: activeTask);
                              }
                              final offset = showRunning ? 1 : 0;
                              return MessageCard(
                                s.messages[s.messages.length -
                                    1 -
                                    (i - offset)],
                                c,
                              );
                            },
                          ),
                        ),
                        if (awayFromLatest)
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 12,
                            child: Center(
                              child: FilledButton.tonalIcon(
                                key: const ValueKey('chat-latest-button'),
                                onPressed: _scrollToLatest,
                                icon: const Icon(Icons.arrow_downward_rounded),
                                label: Text(
                                  unseenMessages > 0
                                      ? '${unseenMessages > 99 ? '99+' : unseenMessages} pesan baru'
                                      : 'Ke pesan terbaru',
                                ),
                              ),
                            ),
                          ),
                      ],
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
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (c.capabilities.supportsImages ||
                          c.capabilities.supportsFiles)
                        PopupMenuButton<String>(
                          tooltip: 'Tambah attachment',
                          icon: const Icon(Icons.add_circle_outline),
                          onSelected: pick,
                          itemBuilder: (_) => [
                            if (c.capabilities.supportsImages)
                              const PopupMenuItem(
                                value: 'image',
                                child: ListTile(
                                  leading: Icon(Icons.photo_outlined),
                                  title: Text('Pilih dari galeri'),
                                  contentPadding: EdgeInsets.zero,
                                ),
                              ),
                            if (c.capabilities.supportsImages)
                              const PopupMenuItem(
                                value: 'camera',
                                child: ListTile(
                                  leading: Icon(Icons.camera_alt_outlined),
                                  title: Text('Ambil dari kamera'),
                                  contentPadding: EdgeInsets.zero,
                                ),
                              ),
                            if (c.capabilities.supportsImages)
                              const PopupMenuItem(
                                value: 'clipboard',
                                child: ListTile(
                                  leading: Icon(Icons.content_paste_outlined),
                                  title: Text('Tempel gambar clipboard'),
                                  contentPadding: EdgeInsets.zero,
                                ),
                              ),
                            if (c.capabilities.supportsFiles)
                              const PopupMenuItem(
                                value: 'file',
                                child: ListTile(
                                  leading: Icon(Icons.description_outlined),
                                  title: Text('Pilih file'),
                                  contentPadding: EdgeInsets.zero,
                                ),
                              ),
                          ],
                        ),
                      Expanded(
                        child: TextField(
                          controller: text,
                          maxLines: 6,
                          minLines: 1,
                          textCapitalization: TextCapitalization.sentences,
                          contextMenuBuilder: (context, editableTextState) {
                            final items = [
                              ...editableTextState.contextMenuButtonItems,
                              ContextMenuButtonItem(
                                label: 'Tempel gambar',
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
                                ? 'Kirim instruksi ke Demo Agent'
                                : 'Instruksikan agent di PC...',
                            border: InputBorder.none,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 10,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      if (s.status == SessionStatus.generating)
                        IconButton.filled(
                          tooltip: 'Hentikan task',
                          style: IconButton.styleFrom(
                            backgroundColor: Theme.of(
                              context,
                            ).colorScheme.errorContainer,
                            foregroundColor: Theme.of(
                              context,
                            ).colorScheme.onErrorContainer,
                          ),
                          onPressed: c.stop,
                          icon: const Icon(Icons.stop_rounded),
                        )
                      else
                        ValueListenableBuilder<TextEditingValue>(
                          valueListenable: text,
                          builder: (context, value, _) {
                            final canSend =
                                value.text.trim().isNotEmpty ||
                                pending.isNotEmpty;
                            return IconButton.filled(
                              tooltip: submitting
                                  ? 'Mengirim instruksi'
                                  : 'Kirim',
                              onPressed: canSend && !submitting ? submit : null,
                              icon: submitting
                                  ? const SizedBox.square(
                                      dimension: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.arrow_upward_rounded),
                            );
                          },
                        ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 4, 8, 2),
                    child: Row(
                      children: [
                        Icon(
                          s.status == SessionStatus.generating
                              ? Icons.sync_rounded
                              : Icons.shield_outlined,
                          size: 14,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            s.status == SessionStatus.generating
                                ? 'Task berjalan di PC • draft tetap tersimpan'
                                : submitting
                                ? 'Menyimpan dan mengirim instruksi...'
                                : pending.isNotEmpty
                                ? '${pending.length}/10 attachment • maks 15 MB/file'
                                : 'Pesan kosong tidak akan dikirim',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> submit() async {
    final prompt = text.text.trim();
    final attachments = List<AgentAttachment>.of(pending);
    if (submitting || prompt.isEmpty && attachments.isEmpty) return;
    final submittedDraft = text.value;
    setState(() => submitting = true);
    var sent = false;
    try {
      await widget.c.send(prompt, attachments: attachments);
      sent = true;
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Instruksi gagal dikirim. Coba lagi.')),
        );
      }
    }
    if (!mounted) return;
    setState(() {
      if (sent) {
        if (text.value == submittedDraft) text.clear();
        pending.removeWhere(attachments.contains);
      }
      submitting = false;
    });
    if (sent) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToLatest());
    }
  }

  void _handleMessageScroll() {
    if (!messageScroll.hasClients) return;
    final nextAway = messageScroll.offset > 120;
    if (nextAway == awayFromLatest) return;
    setState(() {
      awayFromLatest = nextAway;
      if (!nextAway) unseenMessages = 0;
    });
  }

  void _trackSessionMessages(AgentSession session) {
    final latestId = session.messages.lastOrNull?.id;
    if (trackedSessionId != session.id) {
      trackedSessionId = session.id;
      trackedLatestMessageId = latestId;
      trackedMessageCount = session.messages.length;
      unseenMessages = 0;
      awayFromLatest = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && messageScroll.hasClients) messageScroll.jumpTo(0);
      });
      return;
    }
    if (latestId == null || latestId == trackedLatestMessageId) {
      trackedMessageCount = session.messages.length;
      return;
    }
    final addedMessages = session.messages.length > trackedMessageCount
        ? session.messages.length - trackedMessageCount
        : 1;
    trackedLatestMessageId = latestId;
    trackedMessageCount = session.messages.length;
    if (!awayFromLatest) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !awayFromLatest) return;
      setState(() => unseenMessages += addedMessages);
    });
  }

  void _scrollToLatest() {
    if (!messageScroll.hasClients) return;
    if (awayFromLatest || unseenMessages > 0) {
      setState(() {
        awayFromLatest = false;
        unseenMessages = 0;
      });
    }
    messageScroll.animateTo(
      0,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
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
  const ActivitySummaryCard(this.session, {super.key, this.task});
  final AgentSession session;
  final AgentTask? task;

  @override
  Widget build(BuildContext context) {
    final latest = session.activities.lastOrNull;
    final activeAgent = task?.activeAgentState;
    final running =
        task?.status == 'running' ||
        task?.status == 'queued' ||
        session.status == SessionStatus.generating;
    final detail = activeAgent?.detail.isNotEmpty == true
        ? activeAgent!.detail
        : task?.detail.isNotEmpty == true
        ? task!.detail
        : latest?.detail ?? 'Agent sedang memulai...';
    final runningAgents =
        task?.agentStates.where((state) => state.status == 'running').length ??
        0;
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
                        running
                            ? task == null
                                  ? 'Task sedang berjalan'
                                  : '$runningAgents/${task!.agentStates.length} agent aktif • ${_taskModeLabel(task!.mode)}'
                            : 'Aktivitas terakhir',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        detail,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: () =>
                      showActivityTimeline(context, session, task: task),
                  child: const Text('Lihat proses'),
                ),
              ],
            ),
            if (task?.agentStates.isNotEmpty == true)
              Padding(
                padding: const EdgeInsets.only(left: 36, top: 6),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (
                        var index = 0;
                        index < task!.agentStates.length;
                        index++
                      ) ...[
                        if (index > 0) const Text(' • '),
                        Text(
                          task!.agentStates[index].name,
                          style: Theme.of(context).textTheme.labelMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            if (running) const LinearProgressIndicator(minHeight: 3),
          ],
        ),
      ),
    );
  }
}

class _SessionAgentPill extends StatelessWidget {
  const _SessionAgentPill({required this.state, required this.active});
  final AgentTaskAgentState state;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final color = _taskStatusColor(colors, state.status);
    return Container(
      width: 210,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: active
            ? colors.primaryContainer.withValues(alpha: .55)
            : colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: active ? colors.primary : colors.outlineVariant,
        ),
      ),
      child: Row(
        children: [
          _TaskStatusIcon(status: state.status, compact: true),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  state.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                Text(
                  '${_taskPhaseLabel(state.phase)} • ${state.detail}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: active ? colors.primary : color,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> showActivityTimeline(
  BuildContext context,
  AgentSession session, {
  AgentTask? task,
}) {
  final agentStates = task?.agentStates ?? const <AgentTaskAgentState>[];
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .72,
        child: Column(
          children: [
            ListTile(
              title: const Text('Proses task'),
              subtitle: Text(
                task == null
                    ? session.activeModelName ?? 'PC Agent'
                    : '${task.agentStates.length} agent • ${_taskModeLabel(task.mode)}',
              ),
              trailing: IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ),
            if (agentStates.isNotEmpty)
              SizedBox(
                height: 84,
                child: ListView.separated(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 6,
                  ),
                  scrollDirection: Axis.horizontal,
                  itemCount: agentStates.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (context, index) {
                    final state = agentStates[index];
                    return _SessionAgentPill(
                      state: state,
                      active: state.id == task?.activeAgent && state.isActive,
                    );
                  },
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
                            trailing: Text(
                              formatLocalClock(activity.createdAt),
                            ),
                            children: [
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  72,
                                  0,
                                  20,
                                  16,
                                ),
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
}

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
  const _RunningAgentCard({this.task});
  final AgentTask? task;

  @override
  Widget build(BuildContext context) {
    final activeAgent = task?.activeAgentState;
    final title = activeAgent?.name ?? 'Agent';
    final detail = activeAgent?.detail.isNotEmpty == true
        ? activeAgent!.detail
        : 'Agent sedang memproses instruksi...';
    return Align(
      alignment: Alignment.centerLeft,
      child: Card(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2.2),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '$title • ${_taskPhaseLabel(activeAgent?.phase ?? 'thinking')}',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        detail,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if ((task?.agentStates.length ?? 0) > 1)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text('${task!.agentStates.length} agent'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class MessageCard extends StatelessWidget {
  const MessageCard(this.m, this.c, {super.key});
  final ChatMessage m;
  final AppController c;
  @override
  Widget build(BuildContext context) {
    final user = m.role == MessageRole.user;
    final system = m.role == MessageRole.system;
    final colors = Theme.of(context).colorScheme;
    final statusColor = _messageStatusColor(colors, m.status);
    final roleLabel = switch (m.role) {
      MessageRole.user => 'Anda',
      MessageRole.system => 'Sistem',
      MessageRole.assistant =>
        c.current?.activeModelName?.trim().isNotEmpty == true
            ? c.current!.activeModelName!.trim()
            : 'Agent',
    };
    final copyable =
        m.content.trim().isNotEmpty &&
        m.approvalRequest == null &&
        m.clarificationRequest == null;
    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: Card(
        color: user
            ? colors.primaryContainer
            : system
            ? colors.tertiaryContainer.withValues(alpha: .45)
            : null,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(
            color: m.status == MessageStatus.failed
                ? colors.error.withValues(alpha: .55)
                : colors.outlineVariant,
          ),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 700),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      radius: 14,
                      backgroundColor: statusColor.withValues(alpha: .12),
                      child: Icon(
                        _messageRoleIcon(m.role),
                        size: 16,
                        color: statusColor,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            roleLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                          Wrap(
                            spacing: 7,
                            runSpacing: 2,
                            children: [
                              Text(
                                _messageStatusLabel(m.status),
                                style: Theme.of(context).textTheme.labelSmall
                                    ?.copyWith(
                                      color: statusColor,
                                      fontWeight: FontWeight.w700,
                                    ),
                              ),
                              Text(
                                formatLocalClock(m.updatedAt),
                                style: Theme.of(context).textTheme.labelSmall
                                    ?.copyWith(color: colors.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    if (copyable)
                      IconButton(
                        tooltip: 'Salin pesan',
                        visualDensity: VisualDensity.compact,
                        onPressed: () async {
                          await Clipboard.setData(
                            ClipboardData(text: m.content),
                          );
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Pesan disalin.'),
                              duration: Duration(seconds: 1),
                            ),
                          );
                        },
                        icon: const Icon(Icons.copy_all_outlined, size: 19),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                if (m.approvalRequest case final request?) ...[
                  _ApprovalRequestCard(request: request, controller: c),
                ] else if (m.clarificationRequest case final request?) ...[
                  _ClarificationRequestCard(request: request, controller: c),
                ] else if (user)
                  SelectableText(
                    m.content.isEmpty ? _messageEmptyText(m.status) : m.content,
                  )
                else
                  MarkdownBody(
                    data: m.content.isEmpty
                        ? _messageEmptyText(m.status)
                        : m.content,
                    selectable: true,
                  ),
                ...m.attachments.map((a) => AttachmentChip(a)),
                ...m.toolActivities.map(_ToolActivityCard.new),
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

String _messageStatusLabel(MessageStatus status) => switch (status) {
  MessageStatus.queued => 'Antre',
  MessageStatus.streaming => 'Berjalan',
  MessageStatus.complete => 'Selesai',
  MessageStatus.stopped => 'Dihentikan',
  MessageStatus.failed => 'Gagal',
};

String _messageEmptyText(MessageStatus status) => switch (status) {
  MessageStatus.queued => 'Menunggu giliran...',
  MessageStatus.streaming => 'Menunggu respons agent...',
  MessageStatus.complete => 'Tidak ada konten tambahan.',
  MessageStatus.stopped => 'Task dihentikan.',
  MessageStatus.failed => 'Respons agent gagal.',
};

Color _messageStatusColor(ColorScheme colors, MessageStatus status) =>
    switch (status) {
      MessageStatus.queued => colors.secondary,
      MessageStatus.streaming => colors.primary,
      MessageStatus.complete => Colors.green.shade700,
      MessageStatus.stopped => colors.outline,
      MessageStatus.failed => colors.error,
    };

IconData _messageRoleIcon(MessageRole role) => switch (role) {
  MessageRole.user => Icons.person_outline,
  MessageRole.assistant => Icons.smart_toy_outlined,
  MessageRole.system => Icons.settings_suggest_outlined,
};

class _ToolActivityCard extends StatelessWidget {
  const _ToolActivityCard(this.activity);
  final ToolActivity activity;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final statusColor = _toolActivityStatusColor(colors, activity.status);
    final running = activity.status == ToolActivityStatus.running;
    final progress = activity.progress?.clamp(0.0, 1.0).toDouble();
    final error = activity.error?.trim() ?? '';
    final output = activity.outputPreview?.trim() ?? '';
    final detail = error.isNotEmpty
        ? error
        : output.isNotEmpty
        ? output
        : _toolActivityEmptyDetail(activity.status);
    final displayName = activity.displayName.trim().isNotEmpty
        ? activity.displayName.trim()
        : activity.toolName.trim().isNotEmpty
        ? activity.toolName.trim()
        : 'Aktivitas agent';
    final duration = activity.completedAt
        ?.difference(activity.startedAt)
        .inSeconds;
    return Card(
      margin: const EdgeInsets.only(top: 8),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: statusColor.withValues(alpha: .25)),
      ),
      child: ExpansionTile(
        key: ValueKey('tool-${activity.id}'),
        initiallyExpanded:
            running || activity.status == ToolActivityStatus.failed,
        leading: CircleAvatar(
          backgroundColor: statusColor.withValues(alpha: .12),
          child: running
              ? Padding(
                  padding: const EdgeInsets.all(10),
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: statusColor,
                  ),
                )
              : Icon(_toolActivityIcon(activity), color: statusColor, size: 20),
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(width: 6),
            _ToolActivityStatusBadge(
              status: activity.status,
              color: statusColor,
            ),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              activity.summary.trim().isEmpty
                  ? _toolActivityStatusLabel(activity.status)
                  : activity.summary.trim(),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            if (running) ...[
              const SizedBox(height: 6),
              LinearProgressIndicator(value: progress),
              if (progress != null) ...[
                const SizedBox(height: 3),
                Text('${(progress * 100).round()}%'),
              ],
            ],
          ],
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              error.isNotEmpty ? 'Error' : 'Output',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: error.isNotEmpty
                    ? colors.error
                    : colors.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: error.isNotEmpty
                  ? colors.errorContainer
                  : colors.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: SelectableText(
              detail,
              style: TextStyle(
                fontFamily: 'monospace',
                color: error.isNotEmpty ? colors.onErrorContainer : null,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: Wrap(
              spacing: 10,
              runSpacing: 4,
              children: [
                Text('Mulai ${formatLocalClock(activity.startedAt)}'),
                if (duration != null)
                  Text('Durasi ${formatElapsedDuration(duration)}'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ToolActivityStatusBadge extends StatelessWidget {
  const _ToolActivityStatusBadge({required this.status, required this.color});
  final ToolActivityStatus status;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .1),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      _toolActivityStatusLabel(status),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        color: color,
        fontWeight: FontWeight.w800,
      ),
    ),
  );
}

String _toolActivityStatusLabel(ToolActivityStatus status) => switch (status) {
  ToolActivityStatus.pending => 'Menunggu',
  ToolActivityStatus.running => 'Berjalan',
  ToolActivityStatus.success => 'Selesai',
  ToolActivityStatus.failed => 'Gagal',
  ToolActivityStatus.cancelled => 'Dibatalkan',
};

Color _toolActivityStatusColor(ColorScheme colors, ToolActivityStatus status) =>
    switch (status) {
      ToolActivityStatus.pending => colors.secondary,
      ToolActivityStatus.running => colors.primary,
      ToolActivityStatus.success => Colors.green.shade700,
      ToolActivityStatus.failed => colors.error,
      ToolActivityStatus.cancelled => colors.outline,
    };

IconData _toolActivityIcon(ToolActivity activity) {
  final tool = activity.toolName.toLowerCase();
  if (tool.contains('shell') ||
      tool.contains('command') ||
      tool.contains('terminal')) {
    return Icons.terminal_outlined;
  }
  if (tool.contains('file') ||
      tool.contains('write') ||
      tool.contains('edit')) {
    return Icons.edit_note_outlined;
  }
  if (tool.contains('subagent') || tool.contains('agent')) {
    return Icons.groups_outlined;
  }
  if (tool.contains('test')) return Icons.science_outlined;
  return Icons.build_outlined;
}

String _toolActivityEmptyDetail(ToolActivityStatus status) => switch (status) {
  ToolActivityStatus.pending => 'Menunggu tool dijalankan.',
  ToolActivityStatus.running => 'Output belum tersedia.',
  ToolActivityStatus.success => 'Selesai tanpa output tambahan.',
  ToolActivityStatus.failed => 'Tool gagal tanpa detail error.',
  ToolActivityStatus.cancelled => 'Aktivitas dibatalkan.',
};

class _ApprovalRequestCard extends StatefulWidget {
  const _ApprovalRequestCard({required this.request, required this.controller});
  final ApprovalRequest request;
  final AppController controller;

  @override
  State<_ApprovalRequestCard> createState() => _ApprovalRequestCardState();
}

class _ApprovalRequestCardState extends State<_ApprovalRequestCard> {
  bool busy = false;

  Future<void> _resolve(ApprovalDecision decision) async {
    if (busy || widget.request.status != ApprovalStatus.pending) return;
    if (decision == ApprovalDecision.approve &&
        (widget.request.riskLevel == ApprovalRiskLevel.high ||
            widget.request.riskLevel == ApprovalRiskLevel.critical)) {
      final confirmed = await _confirmHighRiskApproval();
      if (!confirmed) return;
    }
    setState(() => busy = true);
    try {
      if (decision == ApprovalDecision.approve) {
        await widget.controller.approveRequest(widget.request.id);
      } else {
        await widget.controller.denyRequest(widget.request.id);
      }
    } catch (exception) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_interactionError(exception))));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<bool> _confirmHighRiskApproval() async =>
      await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: const Text('Setujui aksi berisiko tinggi?'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.request.description),
                if (widget.request.commandPreview?.trim().isNotEmpty ==
                    true) ...[
                  const SizedBox(height: 12),
                  const Text(
                    'Command yang akan dijalankan:',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  SelectableText(widget.request.commandPreview!.trim()),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('Batal'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('Tetap setujui'),
            ),
          ],
        ),
      ) ??
      false;

  @override
  Widget build(BuildContext context) {
    final request = widget.request;
    final colors = Theme.of(context).colorScheme;
    final riskColor = _approvalRiskColor(colors, request.riskLevel);
    final pending = request.status == ApprovalStatus.pending;
    final command = request.commandPreview?.trim() ?? '';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: riskColor.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: riskColor.withValues(alpha: .28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                backgroundColor: riskColor.withValues(alpha: .14),
                child: Icon(Icons.gpp_maybe_outlined, color: riskColor),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      request.title.isEmpty
                          ? 'Persetujuan diperlukan'
                          : request.title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const Text('Agent menunggu keputusan sebelum melanjutkan.'),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _InteractionBadge(
                icon: Icons.warning_amber_outlined,
                label: _approvalRiskLabel(request.riskLevel),
                color: riskColor,
              ),
              _InteractionBadge(
                icon: _approvalStatusIcon(request.status),
                label: _approvalStatusLabel(request.status),
                color: _approvalStatusColor(colors, request.status),
              ),
              if (request.isDemo)
                _InteractionBadge(
                  icon: Icons.science_outlined,
                  label: 'Mode demo',
                  color: colors.secondary,
                ),
            ],
          ),
          const SizedBox(height: 10),
          Text(request.description),
          if (command.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: colors.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: SelectableText(
                command,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            ),
          ],
          if (request.expiresAt case final expires?) ...[
            const SizedBox(height: 8),
            Text(
              'Berlaku sampai ${formatLocalClock(expires)}',
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
          ],
          if (pending) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: busy
                      ? null
                      : () => _resolve(ApprovalDecision.approve),
                  icon: busy
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.check),
                  label: const Text('Setujui sekali'),
                ),
                OutlinedButton.icon(
                  onPressed: busy
                      ? null
                      : () => _resolve(ApprovalDecision.deny),
                  icon: const Icon(Icons.close),
                  label: const Text('Tolak'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _ClarificationRequestCard extends StatefulWidget {
  const _ClarificationRequestCard({
    required this.request,
    required this.controller,
  });
  final ClarificationRequest request;
  final AppController controller;

  @override
  State<_ClarificationRequestCard> createState() =>
      _ClarificationRequestCardState();
}

class _ClarificationRequestCardState extends State<_ClarificationRequestCard> {
  final answerController = TextEditingController();
  bool busy = false;

  @override
  void dispose() {
    answerController.dispose();
    super.dispose();
  }

  Future<void> _answer(String value) async {
    final answer = value.trim();
    if (answer.isEmpty ||
        busy ||
        widget.request.status != ClarificationStatus.pending) {
      return;
    }
    setState(() => busy = true);
    try {
      await widget.controller.answerClarification(widget.request.id, answer);
      answerController.clear();
    } catch (exception) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_interactionError(exception))));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final request = widget.request;
    final colors = Theme.of(context).colorScheme;
    final pending = request.status == ClarificationStatus.pending;
    final statusColor = _clarificationStatusColor(colors, request.status);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.primary.withValues(alpha: .06),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.primary.withValues(alpha: .22)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                backgroundColor: colors.primary.withValues(alpha: .12),
                child: Icon(Icons.help_outline, color: colors.primary),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Agent membutuhkan jawaban',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(request.question),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _InteractionBadge(
                icon: _clarificationStatusIcon(request.status),
                label: _clarificationStatusLabel(request.status),
                color: statusColor,
              ),
              if (request.isDemo)
                _InteractionBadge(
                  icon: Icons.science_outlined,
                  label: 'Mode demo',
                  color: colors.secondary,
                ),
            ],
          ),
          if (request.choices.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: request.choices
                  .map(
                    (choice) => ActionChip(
                      avatar: const Icon(Icons.reply_outlined, size: 18),
                      label: Text(choice),
                      onPressed: pending && !busy
                          ? () => _answer(choice)
                          : null,
                    ),
                  )
                  .toList(),
            ),
          ],
          if (request.allowFreeText && pending) ...[
            const SizedBox(height: 10),
            TextField(
              controller: answerController,
              enabled: !busy,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              decoration: InputDecoration(
                labelText: 'Jawaban lain',
                hintText: 'Tulis jawaban untuk agent',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  tooltip: 'Kirim jawaban',
                  onPressed: busy ? null : () => _answer(answerController.text),
                  icon: busy
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send_outlined),
                ),
              ),
              onSubmitted: _answer,
            ),
          ],
          if (request.selectedAnswer case final answer?) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha: .1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text('Jawaban: $answer'),
            ),
          ] else if (!pending && request.choices.isEmpty) ...[
            const SizedBox(height: 8),
            Text(_clarificationStatusLabel(request.status)),
          ],
        ],
      ),
    );
  }
}

class _InteractionBadge extends StatelessWidget {
  const _InteractionBadge({
    required this.icon,
    required this.label,
    required this.color,
  });
  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .1),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    ),
  );
}

String _approvalRiskLabel(ApprovalRiskLevel risk) => switch (risk) {
  ApprovalRiskLevel.low => 'Risiko rendah',
  ApprovalRiskLevel.medium => 'Risiko sedang',
  ApprovalRiskLevel.high => 'Risiko tinggi',
  ApprovalRiskLevel.critical => 'Risiko kritis',
  ApprovalRiskLevel.unknown => 'Risiko tidak diketahui',
};

Color _approvalRiskColor(ColorScheme colors, ApprovalRiskLevel risk) =>
    switch (risk) {
      ApprovalRiskLevel.low => Colors.green.shade700,
      ApprovalRiskLevel.medium => colors.tertiary,
      ApprovalRiskLevel.high => Colors.orange.shade800,
      ApprovalRiskLevel.critical => colors.error,
      ApprovalRiskLevel.unknown => colors.outline,
    };

String _approvalStatusLabel(ApprovalStatus status) => switch (status) {
  ApprovalStatus.pending => 'Menunggu keputusan',
  ApprovalStatus.approved => 'Disetujui',
  ApprovalStatus.denied => 'Ditolak',
  ApprovalStatus.expired => 'Kedaluwarsa',
  ApprovalStatus.cancelled => 'Dibatalkan',
};

IconData _approvalStatusIcon(ApprovalStatus status) => switch (status) {
  ApprovalStatus.pending => Icons.hourglass_top_outlined,
  ApprovalStatus.approved => Icons.check_circle_outline,
  ApprovalStatus.denied => Icons.cancel_outlined,
  ApprovalStatus.expired => Icons.timer_off_outlined,
  ApprovalStatus.cancelled => Icons.block_outlined,
};

Color _approvalStatusColor(ColorScheme colors, ApprovalStatus status) =>
    switch (status) {
      ApprovalStatus.pending => colors.primary,
      ApprovalStatus.approved => Colors.green.shade700,
      ApprovalStatus.denied => colors.error,
      ApprovalStatus.expired => colors.outline,
      ApprovalStatus.cancelled => colors.outline,
    };

String _clarificationStatusLabel(ClarificationStatus status) =>
    switch (status) {
      ClarificationStatus.pending => 'Menunggu jawaban',
      ClarificationStatus.answered => 'Terjawab',
      ClarificationStatus.cancelled => 'Dibatalkan',
      ClarificationStatus.expired => 'Kedaluwarsa',
    };

IconData _clarificationStatusIcon(ClarificationStatus status) =>
    switch (status) {
      ClarificationStatus.pending => Icons.question_answer_outlined,
      ClarificationStatus.answered => Icons.check_circle_outline,
      ClarificationStatus.cancelled => Icons.block_outlined,
      ClarificationStatus.expired => Icons.timer_off_outlined,
    };

Color _clarificationStatusColor(
  ColorScheme colors,
  ClarificationStatus status,
) => switch (status) {
  ClarificationStatus.pending => colors.primary,
  ClarificationStatus.answered => Colors.green.shade700,
  ClarificationStatus.cancelled => colors.outline,
  ClarificationStatus.expired => colors.outline,
};

String _interactionError(Object exception) {
  final message = exception.toString().trim();
  if (message.isEmpty) return 'Aksi gagal diproses.';
  return message
      .replaceFirst('Bad state: ', '')
      .replaceFirst('StateError: ', '');
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

enum _TaskViewFilter { all, active, attention, completed }

bool _taskNeedsAttention(AgentTask task) =>
    task.status == 'failed' ||
    task.status == 'stopped' ||
    task.agentStates.any(
      (state) => state.status == 'failed' || state.status == 'stopped',
    );

int _taskSortRank(AgentTask task) {
  if (task.status == 'running') return 0;
  if (task.status == 'queued') return 1;
  if (_taskNeedsAttention(task)) return 2;
  if (task.status == 'completed') return 3;
  return 4;
}

String _taskStatusLabel(String status) => switch (status) {
  'running' => 'Berjalan',
  'queued' => 'Antre',
  'completed' => 'Selesai',
  'failed' => 'Gagal',
  'stopped' => 'Dihentikan',
  _ => status,
};

String _taskModeLabel(String mode) => switch (mode) {
  'parallel' => 'Parallel',
  'coordinator' => 'Koordinator',
  _ => 'Single',
};

Color _taskStatusColor(ColorScheme colors, String status) => switch (status) {
  'running' => colors.primary,
  'queued' => colors.secondary,
  'completed' => Colors.green,
  'failed' => colors.error,
  'stopped' => colors.tertiary,
  _ => colors.onSurfaceVariant,
};

class TasksPage extends StatefulWidget {
  const TasksPage(this.c, {super.key});
  final AppController c;
  @override
  State<TasksPage> createState() => _TasksPageState();
}

class _TasksPageState extends State<TasksPage> {
  _TaskViewFilter filter = _TaskViewFilter.all;

  @override
  void initState() {
    super.initState();
    widget.c.reloadTasks();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final tasks = [...c.tasks]
      ..sort((left, right) {
        final rank = _taskSortRank(left).compareTo(_taskSortRank(right));
        if (rank != 0) return rank;
        final leftTime = left.updatedAt ?? left.createdAt;
        final rightTime = right.updatedAt ?? right.createdAt;
        return (rightTime?.millisecondsSinceEpoch ?? 0).compareTo(
          leftTime?.millisecondsSinceEpoch ?? 0,
        );
      });
    final activeCount = tasks
        .where((task) => task.status == 'running' || task.status == 'queued')
        .length;
    final runningAgents = tasks
        .expand((task) => task.agentStates)
        .where((state) => state.status == 'running')
        .length;
    final attentionCount = tasks.where(_taskNeedsAttention).length;
    final completedCount = tasks
        .where((task) => task.status == 'completed')
        .length;
    final visibleTasks = tasks.where(
      (task) => switch (filter) {
        _TaskViewFilter.active =>
          task.status == 'running' || task.status == 'queued',
        _TaskViewFilter.attention => _taskNeedsAttention(task),
        _TaskViewFilter.completed => task.status == 'completed',
        _TaskViewFilter.all => true,
      },
    );
    return RefreshIndicator(
      onRefresh: c.reloadTasks,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Aktivitas PC',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              Badge(
                label: Text('${tasks.length}'),
                child: const Icon(Icons.monitor_heart_outlined),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Pantau seluruh agent dan proses yang berjalan di PC.',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          _TaskSummaryStrip(
            active: activeCount,
            agents: runningAgents,
            attention: attentionCount,
          ),
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _TaskFilterChip(
                  label: 'Semua',
                  count: tasks.length,
                  selected: filter == _TaskViewFilter.all,
                  onSelected: () =>
                      setState(() => filter = _TaskViewFilter.all),
                ),
                _TaskFilterChip(
                  label: 'Aktif',
                  count: activeCount,
                  selected: filter == _TaskViewFilter.active,
                  onSelected: () =>
                      setState(() => filter = _TaskViewFilter.active),
                ),
                _TaskFilterChip(
                  label: 'Perhatian',
                  count: attentionCount,
                  selected: filter == _TaskViewFilter.attention,
                  onSelected: () =>
                      setState(() => filter = _TaskViewFilter.attention),
                ),
                _TaskFilterChip(
                  label: 'Selesai',
                  count: completedCount,
                  selected: filter == _TaskViewFilter.completed,
                  onSelected: () =>
                      setState(() => filter = _TaskViewFilter.completed),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          if (tasks.isEmpty)
            const Card(
              child: ListTile(
                leading: Icon(Icons.check_circle_outline),
                title: Text('PC sedang idle'),
                subtitle: Text('Belum ada task agent yang tercatat.'),
              ),
            )
          else if (visibleTasks.isEmpty)
            const Card(
              child: ListTile(
                leading: Icon(Icons.filter_alt_off_outlined),
                title: Text('Tidak ada task pada filter ini'),
                subtitle: Text('Pilih filter lain untuk melihat task.'),
              ),
            )
          else
            ...visibleTasks.map((task) => _AgentTaskCard(c: c, task: task)),
        ],
      ),
    );
  }
}

class _TaskSummaryStrip extends StatelessWidget {
  const _TaskSummaryStrip({
    required this.active,
    required this.agents,
    required this.attention,
  });

  final int active;
  final int agents;
  final int attention;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    Widget metric(IconData icon, String value, String label, Color color) =>
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 11),
            child: Column(
              children: [
                Icon(icon, size: 19, color: color),
                const SizedBox(height: 3),
                Text(
                  value,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w900,
                  ),
                ),
                Text(label, style: Theme.of(context).textTheme.labelSmall),
              ],
            ),
          ),
        );
    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Row(
        children: [
          metric(Icons.bolt_rounded, '$active', 'Aktif', colors.primary),
          SizedBox(
            height: 44,
            child: VerticalDivider(color: colors.outlineVariant),
          ),
          metric(
            Icons.smart_toy_outlined,
            '$agents',
            'Agent',
            colors.secondary,
          ),
          SizedBox(
            height: 44,
            child: VerticalDivider(color: colors.outlineVariant),
          ),
          metric(
            Icons.warning_amber_rounded,
            '$attention',
            'Perhatian',
            attention > 0 ? colors.error : colors.onSurfaceVariant,
          ),
        ],
      ),
    );
  }
}

class _TaskFilterChip extends StatelessWidget {
  const _TaskFilterChip({
    required this.label,
    required this.count,
    required this.selected,
    required this.onSelected,
  });
  final String label;
  final int count;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: FilterChip(
      selected: selected,
      onSelected: (_) => onSelected(),
      label: Text('$label ($count)'),
    ),
  );
}

class _AgentTaskCard extends StatelessWidget {
  const _AgentTaskCard({required this.c, required this.task});
  final AppController c;
  final AgentTask task;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final statusColor = _taskStatusColor(colors, task.status);
    final runningCount = task.agentStates
        .where((state) => state.status == 'running')
        .length;
    final canOpen = task.sessionId.isNotEmpty && task.source == 'agent_remote';
    final activeAgent = task.activeAgentState;
    final canStop =
        canOpen && (task.status == 'running' || task.status == 'queued');
    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(
          color: task.status == 'running' || _taskNeedsAttention(task)
              ? statusColor.withValues(alpha: .55)
              : colors.outlineVariant,
        ),
      ),
      child: ExpansionTile(
        key: PageStorageKey('task-${task.id}'),
        initiallyExpanded: task.status == 'running',
        leading: _TaskStatusIcon(status: task.status),
        title: Text(
          task.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 5),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${_taskStatusLabel(task.status)} • '
                '${task.status == 'running' ? '$runningCount/${task.agentStates.length} aktif' : '${task.agentStates.length} agent'} • '
                '${_taskModeLabel(task.mode)} • ${task.concurrency} slot',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: statusColor,
                  fontWeight: FontWeight.w800,
                ),
              ),
              if (activeAgent?.detail.isNotEmpty == true ||
                  task.detail.isNotEmpty)
                Text(
                  activeAgent?.detail.isNotEmpty == true
                      ? activeAgent!.detail
                      : task.detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        children: [
          Divider(color: colors.outlineVariant),
          if (task.agentStates.isEmpty)
            ListTile(
              dense: true,
              leading: const Icon(Icons.smart_toy_outlined),
              title: Text(task.agents.join(' + ')),
              subtitle: Text(task.detail),
            )
          else
            ...task.agentStates.map(
              (state) => _TaskAgentStateTile(
                state: state,
                highlighted: state.id == task.activeAgent && state.isActive,
              ),
            ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              [
                task.source == 'codex_desktop'
                    ? 'Codex Desktop/CLI'
                    : 'Agent Remote',
                if (task.createdAt != null)
                  'Mulai ${formatLocalClock(task.createdAt!)}',
                formatElapsedDuration(task.elapsedSeconds),
                if (task.changedFiles > 0) '${task.changedFiles} file berubah',
                _taskPermissionLabel(task.permission),
              ].where((value) => value.isNotEmpty).join(' • '),
              style: Theme.of(
                context,
              ).textTheme.labelMedium?.copyWith(color: colors.onSurfaceVariant),
            ),
          ),
          if (task.status == 'running' && task.idleSeconds >= 15)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Belum ada event baru selama ${formatElapsedDuration(task.idleSeconds)}',
                  style: TextStyle(color: colors.tertiary),
                ),
              ),
            ),
          if (task.workspace.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  task.workspace,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
          if (canOpen)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (canStop) ...[
                    OutlinedButton.icon(
                      onPressed: () async {
                        final accepted = await confirm(
                          context,
                          'Hentikan task ini?',
                        );
                        if (accepted) await c.stopSession(task.sessionId);
                      },
                      icon: const Icon(Icons.stop_circle_outlined, size: 18),
                      label: const Text('Stop'),
                    ),
                    const SizedBox(width: 8),
                  ],
                  FilledButton.tonalIcon(
                    onPressed: () => c.openTask(task),
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: const Text('Buka session'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _TaskAgentStateTile extends StatelessWidget {
  const _TaskAgentStateTile({required this.state, required this.highlighted});
  final AgentTaskAgentState state;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: highlighted
            ? colors.primaryContainer.withValues(alpha: .38)
            : colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: highlighted ? colors.primary : colors.outlineVariant,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: highlighted
                ? colors.primary
                : colors.surfaceContainerHighest,
            foregroundColor: highlighted
                ? colors.onPrimary
                : colors.onSurfaceVariant,
            child: Text(
              state.name.isEmpty ? '?' : state.name[0].toUpperCase(),
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        state.name,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    Text(
                      _taskRoleLabel(state.role),
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  state.detail.isEmpty
                      ? _taskPhaseLabel(state.phase)
                      : state.detail,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 7),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      _taskPhaseLabel(state.phase),
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: highlighted ? colors.primary : colors.secondary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      formatElapsedDuration(state.elapsedSeconds),
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                    if (state.isActive && state.idleSeconds >= 15)
                      Text(
                        'idle ${formatElapsedDuration(state.idleSeconds)}',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: colors.tertiary,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _TaskStatusIcon(status: state.status, compact: true),
        ],
      ),
    );
  }
}

class _TaskStatusIcon extends StatelessWidget {
  const _TaskStatusIcon({required this.status, this.compact = false});
  final String status;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final color = _taskStatusColor(colors, status);
    if (status == 'running' || status == 'queued') {
      return SizedBox.square(
        dimension: compact ? 18 : 26,
        child: CircularProgressIndicator(
          strokeWidth: compact ? 2 : 2.5,
          color: color,
        ),
      );
    }
    return Icon(
      status == 'completed'
          ? Icons.check_circle_outline
          : status == 'stopped'
          ? Icons.stop_circle_outlined
          : Icons.error_outline,
      size: compact ? 20 : 26,
      color: color,
    );
  }
}

enum _GitChangeFilter { all, modified, added, deleted, untracked }

enum _FilesView { explorer, changes, git }

class FilesPage extends StatefulWidget {
  const FilesPage(this.c, {super.key});
  final AppController c;

  @override
  State<FilesPage> createState() => _FilesPageState();
}

class _FilesPageState extends State<FilesPage> with WidgetsBindingObserver {
  static const liveSyncInterval = Duration(seconds: 10);
  static const remoteSyncInterval = Duration(seconds: 60);
  _GitChangeFilter filter = _GitChangeFilter.all;
  _FilesView view = _FilesView.explorer;
  Timer? liveSyncTimer;
  bool liveSyncRunning = false;
  DateTime? liveSyncUpdatedAt;
  DateTime? liveRemoteFetchedAt;
  Object? liveSyncError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    startLiveSync();
  }

  void startLiveSync() {
    liveSyncTimer?.cancel();
    WidgetsBinding.instance.addPostFrameCallback((_) => refreshLive());
    liveSyncTimer = Timer.periodic(liveSyncInterval, (_) => refreshLive());
  }

  Future<void> refreshLive({bool force = false}) async {
    if (!mounted ||
        liveSyncRunning ||
        !force && (!widget.c.connected || widget.c.page != 2)) {
      return;
    }
    liveSyncRunning = true;
    if (mounted) setState(() {});
    try {
      final now = DateTime.now();
      final fetchRemote =
          force ||
          liveRemoteFetchedAt == null ||
          now.difference(liveRemoteFetchedAt!) >= remoteSyncInterval;
      await widget.c.reloadWorkspaceData(fetchGit: fetchRemote);
      if (fetchRemote) liveRemoteFetchedAt = DateTime.now();
      liveSyncUpdatedAt = DateTime.now();
      liveSyncError = null;
    } catch (error) {
      liveSyncError = error;
    } finally {
      liveSyncRunning = false;
      if (mounted) setState(() {});
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      startLiveSync();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      liveSyncTimer?.cancel();
    }
  }

  @override
  void dispose() {
    liveSyncTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> openFile(String path) async {
    final editor = switch (widget.c.connector) {
      final WorkspaceFileEditor value => value,
      _ => null,
    };
    if (editor == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Connector belum mendukung preview file.'),
        ),
      );
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _WorkspaceFileScreen(
          editor: editor,
          path: path,
          onSaved: () => widget.c.reloadWorkspaceData(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final statuses = {for (final item in c.gitStatus) item.path: item.status};
    final counts = {
      for (final status in GitFileStatus.values)
        status: c.gitStatus.where((item) => item.status == status).length,
    };
    final selectedStatus = switch (filter) {
      _GitChangeFilter.all => null,
      _GitChangeFilter.modified => GitFileStatus.modified,
      _GitChangeFilter.added => GitFileStatus.added,
      _GitChangeFilter.deleted => GitFileStatus.deleted,
      _GitChangeFilter.untracked => GitFileStatus.untracked,
    };
    final visibleChanges =
        c.gitStatus
            .where(
              (item) => selectedStatus == null || item.status == selectedStatus,
            )
            .toList()
          ..sort((left, right) {
            final statusOrder = left.status.index.compareTo(right.status.index);
            return statusOrder != 0
                ? statusOrder
                : left.path.toLowerCase().compareTo(right.path.toLowerCase());
          });
    final entries = c.workspaceEntries.toList()
      ..sort((left, right) {
        if (left.isDirectory != right.isDirectory) {
          return left.isDirectory ? -1 : 1;
        }
        return left.name.toLowerCase().compareTo(right.name.toLowerCase());
      });
    final repository = c.gitRepository;
    final syncSummary = repository.remoteUrl.isEmpty
        ? 'Remote belum dikonfigurasi'
        : repository.ahead == 0 && repository.behind == 0
        ? 'Sinkron dengan remote'
        : '${repository.ahead} keluar • ${repository.behind} masuk';
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'File & Git',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
            _LiveSyncBadge(
              connected: c.connected,
              running: liveSyncRunning,
              updatedAt: liveSyncUpdatedAt,
              error: liveSyncError,
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: 'Muat ulang workspace',
              onPressed: () => refreshLive(force: true),
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        Text(
          c.workspacePath ?? 'Folder kerja PC belum terhubung',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        SegmentedButton<_FilesView>(
          segments: const [
            ButtonSegment(
              value: _FilesView.explorer,
              icon: Icon(Icons.folder_outlined),
              label: Text('Explorer'),
            ),
            ButtonSegment(
              value: _FilesView.changes,
              icon: Icon(Icons.difference_outlined),
              label: Text('Changes'),
            ),
            ButtonSegment(
              value: _FilesView.git,
              icon: Icon(Icons.account_tree_outlined),
              label: Text('Git'),
            ),
          ],
          selected: {view},
          onSelectionChanged: (value) => setState(() => view = value.first),
        ),
        if (view == _FilesView.explorer)
          Card(
            margin: const EdgeInsets.only(top: 12),
            color: Theme.of(context).colorScheme.primaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  const CircleAvatar(child: Icon(Icons.code_outlined)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Editor workspace',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const Text(
                          'Tap file untuk preview, lihat diff, atau edit manual. 0 token AI.',
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right),
                ],
              ),
            ),
          ),
        if (view == _FilesView.git && repository.isGitRepository)
          Card(
            margin: const EdgeInsets.symmetric(vertical: 12),
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _GithubAvatar(repository, radius: 22),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              repository.githubRepository.isEmpty
                                  ? 'Repository Git lokal'
                                  : '${repository.githubOwner}/${repository.githubRepository}',
                              style: Theme.of(context).textTheme.titleMedium,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              syncSummary,
                              style: TextStyle(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton.filledTonal(
                        tooltip: repository.remoteUrl.isEmpty
                            ? 'Remote Git belum tersedia'
                            : 'Fetch perubahan remote',
                        onPressed: repository.remoteUrl.isEmpty
                            ? null
                            : c.syncGitHub,
                        icon: const Icon(Icons.sync),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  _EnvironmentRow(
                    icon: Icons.difference_outlined,
                    title: 'Changes',
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '+${repository.additions}',
                          style: TextStyle(color: Colors.green.shade700),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '-${repository.deletions}',
                          style: TextStyle(color: Colors.red.shade700),
                        ),
                      ],
                    ),
                  ),
                  _EnvironmentRow(
                    icon: Icons.computer_outlined,
                    title: 'Local',
                    subtitle: c.workspacePath ?? '',
                  ),
                  _EnvironmentRow(
                    icon: Icons.account_tree_outlined,
                    title: repository.branch.isEmpty
                        ? 'Branch tidak diketahui'
                        : repository.branch,
                    subtitle: repository.upstream.isEmpty
                        ? 'Upstream belum dikonfigurasi'
                        : repository.upstream,
                  ),
                  _EnvironmentRow(
                    icon: Icons.commit_outlined,
                    title: 'Commit atau push',
                    subtitle: repository.ahead > 0
                        ? '${repository.ahead} commit siap dikirim'
                        : 'Tidak ada commit keluar',
                  ),
                  _EnvironmentRow(
                    icon: Icons.code_outlined,
                    title: repository.githubCliAuthenticated
                        ? 'GitHub CLI: ${repository.githubCliUser.isEmpty ? 'authenticated' : repository.githubCliUser}'
                        : repository.githubCliInstalled
                        ? 'GitHub CLI belum login'
                        : 'GitHub CLI tidak tersedia',
                  ),
                  _EnvironmentRow(
                    icon: Icons.compare_arrows_outlined,
                    title: 'Bandingkan branch',
                    subtitle: repository.upstream.isEmpty
                        ? 'Pilih upstream lebih dahulu'
                        : '${repository.branch} ↔ ${repository.upstream}',
                    trailing: repository.remoteUrl.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Fetch dan bandingkan ulang',
                            onPressed: c.syncGitHub,
                            icon: const Icon(Icons.refresh, size: 20),
                          ),
                  ),
                  if (entries.isNotEmpty) ...[
                    const Divider(height: 24),
                    Text(
                      'Sources',
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 4),
                    ...entries
                        .take(4)
                        .map(
                          (entry) => _EnvironmentRow(
                            icon: entry.isDirectory
                                ? Icons.folder_outlined
                                : Icons.description_outlined,
                            title: entry.name,
                            subtitle: entry.path,
                          ),
                        ),
                  ],
                  const SizedBox(height: 10),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final columns = constraints.maxWidth < 360 ? 2 : 3;
                      final width =
                          (constraints.maxWidth - ((columns - 1) * 8)) /
                          columns;
                      return Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          SizedBox(
                            width: width,
                            child: _GitMetricCard(
                              icon: Icons.difference_outlined,
                              value: c.gitStatus.length,
                              label: 'File berubah',
                            ),
                          ),
                          SizedBox(
                            width: width,
                            child: _GitMetricCard(
                              icon: Icons.upload_outlined,
                              value: repository.ahead,
                              label: 'Keluar',
                            ),
                          ),
                          SizedBox(
                            width: width,
                            child: _GitMetricCard(
                              icon: Icons.download_outlined,
                              value: repository.behind,
                              label: 'Masuk',
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                  if (repository.outgoing.isNotEmpty)
                    _CommitSection(
                      title: 'Commit belum dikirim',
                      commits: repository.outgoing,
                      icon: Icons.north_east,
                    ),
                  if (repository.incoming.isNotEmpty)
                    _CommitSection(
                      title: 'Commit dari remote',
                      commits: repository.incoming,
                      icon: Icons.south_west,
                    ),
                ],
              ),
            ),
          )
        else if (!repository.isGitRepository && view == _FilesView.git)
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: Icon(
                    repository.nestedRepositories.isEmpty
                        ? Icons.cloud_off_outlined
                        : Icons.account_tree_outlined,
                  ),
                  title: Text(
                    repository.nestedRepositories.isEmpty
                        ? 'Folder ini bukan Git repository'
                        : 'Folder induk memuat ${repository.nestedRepositories.length} Git repository',
                  ),
                  subtitle: Text(
                    repository.nestedRepositories.isEmpty
                        ? 'Session tetap tersimpan khusus untuk folder ini.'
                        : 'Pilih repository agar branch, remote, commit, dan perubahan terbaca tepat.',
                  ),
                ),
                ...repository.nestedRepositories.map(
                  (nested) => ListTile(
                    dense: true,
                    leading: const Icon(Icons.folder_special_outlined),
                    title: Text(nested.name),
                    subtitle: Text(
                      nested.path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => c.selectWorkspace(nested.path),
                  ),
                ),
              ],
            ),
          ),
        if (view == _FilesView.changes && repository.isGitRepository) ...[
          Row(
            children: [
              Expanded(
                child: Text(
                  'Perubahan kode',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              Text('${c.gitStatus.length} file'),
            ],
          ),
          const SizedBox(height: 8),
          if (c.gitStatus.isNotEmpty)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _GitFilterChip(
                    label: 'Semua',
                    count: c.gitStatus.length,
                    selected: filter == _GitChangeFilter.all,
                    onSelected: () =>
                        setState(() => filter = _GitChangeFilter.all),
                  ),
                  _GitFilterChip(
                    label: 'Diubah',
                    count: counts[GitFileStatus.modified] ?? 0,
                    selected: filter == _GitChangeFilter.modified,
                    onSelected: () =>
                        setState(() => filter = _GitChangeFilter.modified),
                  ),
                  _GitFilterChip(
                    label: 'Ditambah',
                    count: counts[GitFileStatus.added] ?? 0,
                    selected: filter == _GitChangeFilter.added,
                    onSelected: () =>
                        setState(() => filter = _GitChangeFilter.added),
                  ),
                  _GitFilterChip(
                    label: 'Dihapus',
                    count: counts[GitFileStatus.deleted] ?? 0,
                    selected: filter == _GitChangeFilter.deleted,
                    onSelected: () =>
                        setState(() => filter = _GitChangeFilter.deleted),
                  ),
                  _GitFilterChip(
                    label: 'Belum dilacak',
                    count: counts[GitFileStatus.untracked] ?? 0,
                    selected: filter == _GitChangeFilter.untracked,
                    onSelected: () =>
                        setState(() => filter = _GitChangeFilter.untracked),
                  ),
                ],
              ),
            ),
          if (c.gitStatus.isEmpty)
            const Card(
              child: ListTile(
                leading: Icon(Icons.check_circle_outline),
                title: Text('Workspace bersih'),
                subtitle: Text(
                  'Tidak ada perubahan lokal yang belum disimpan.',
                ),
              ),
            )
          else if (visibleChanges.isEmpty)
            const Card(
              child: ListTile(
                leading: Icon(Icons.filter_alt_off_outlined),
                title: Text('Tidak ada file pada filter ini'),
              ),
            )
          else
            Card(
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  for (
                    var index = 0;
                    index < visibleChanges.length;
                    index++
                  ) ...[
                    if (index > 0) const Divider(height: 1),
                    _GitChangeTile(
                      visibleChanges[index],
                      onTap: () => openFile(visibleChanges[index].path),
                    ),
                  ],
                ],
              ),
            ),
          const SizedBox(height: 12),
        ],
        if (view == _FilesView.explorer) ...[
          Row(
            children: [
              Expanded(
                child: Text(
                  'Isi folder',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              if (c.workspaceFolder.isNotEmpty)
                TextButton.icon(
                  onPressed: () => c.openWorkspaceFolder(''),
                  icon: const Icon(Icons.home_outlined),
                  label: const Text('Root'),
                ),
            ],
          ),
          Text(
            c.workspaceFolder.isEmpty ? 'Workspace root' : c.workspaceFolder,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          if (entries.isEmpty)
            Card(
              child: ListTile(
                leading: const Icon(Icons.folder_open),
                title: Text(
                  c.workspacePath == null
                      ? 'Pilih folder kerja dari halaman utama'
                      : 'Folder kosong atau belum termuat',
                ),
              ),
            )
          else
            Card(
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  for (var index = 0; index < entries.length; index++) ...[
                    if (index > 0) const Divider(height: 1),
                    Builder(
                      builder: (context) {
                        final entry = entries[index];
                        final status = statuses[entry.path];
                        return ListTile(
                          onTap: entry.isDirectory
                              ? () => c.openWorkspaceFolder(entry.path)
                              : () => openFile(entry.path),
                          leading: Icon(
                            entry.isDirectory
                                ? Icons.folder_outlined
                                : Icons.insert_drive_file_outlined,
                          ),
                          title: Text(
                            entry.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: status == null
                              ? entry.isDirectory
                                    ? const Icon(Icons.chevron_right)
                                    : null
                              : Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    _GitStatusBadge(status),
                                    const SizedBox(width: 4),
                                    const Icon(Icons.chevron_right),
                                  ],
                                ),
                        );
                      },
                    ),
                  ],
                ],
              ),
            ),
        ],
      ],
    );
  }
}

class _LiveSyncBadge extends StatelessWidget {
  const _LiveSyncBadge({
    required this.connected,
    required this.running,
    required this.updatedAt,
    required this.error,
  });
  final bool connected;
  final bool running;
  final DateTime? updatedAt;
  final Object? error;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final failed = error != null;
    final color = !connected
        ? colors.outline
        : failed
        ? colors.error
        : colors.primary;
    final label = !connected
        ? 'Offline'
        : running
        ? 'Sync...'
        : failed
        ? 'Retry'
        : 'Live';
    final message = !connected
        ? 'Hubungkan PC untuk live sync Git'
        : failed
        ? 'Live sync gagal: $error'
        : updatedAt == null
        ? 'Status lokal 5 detik • remote 30 detik'
        : 'Terakhir sync ${formatLocalClock(updatedAt!)}';
    return Tooltip(
      message: message,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: .12),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (running)
              SizedBox.square(
                dimension: 12,
                child: CircularProgressIndicator(strokeWidth: 2, color: color),
              )
            else
              Icon(
                !connected
                    ? Icons.cloud_off_outlined
                    : failed
                    ? Icons.sync_problem_outlined
                    : Icons.sync_outlined,
                size: 15,
                color: color,
              ),
            const SizedBox(width: 5),
            Text(
              label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: color,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _FileViewMode { preview, diff, edit }

class _WorkspaceFileScreen extends StatefulWidget {
  const _WorkspaceFileScreen({
    required this.editor,
    required this.path,
    required this.onSaved,
  });
  final WorkspaceFileEditor editor;
  final String path;
  final Future<void> Function() onSaved;

  @override
  State<_WorkspaceFileScreen> createState() => _WorkspaceFileScreenState();
}

class _WorkspaceFileScreenState extends State<_WorkspaceFileScreen> {
  final code = TextEditingController();
  final search = TextEditingController();
  late Future<WorkspaceFileDocument> load;
  WorkspaceFileDocument? document;
  _FileViewMode mode = _FileViewMode.preview;
  bool saving = false;
  bool allowPop = false;

  bool get dirty => document != null && code.text != document!.content;

  @override
  void initState() {
    super.initState();
    code.addListener(_changed);
    search.addListener(_changed);
    load = _fetch();
  }

  Future<WorkspaceFileDocument> _fetch() async {
    final value = await widget.editor.getWorkspaceFile(widget.path);
    document = value;
    code.text = value.content;
    if (!value.editable && mode == _FileViewMode.edit) {
      mode = _FileViewMode.preview;
    }
    return value;
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _reload() {
    setState(() {
      document = null;
      mode = _FileViewMode.preview;
      search.clear();
      load = _fetch();
    });
  }

  Future<bool> _confirmDiscard() async {
    if (!dirty) return true;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Buang perubahan?'),
            content: const Text(
              'Edit manual belum disimpan ke PC. Perubahan akan hilang.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Tetap di editor'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Buang'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _close() async {
    if (!await _confirmDiscard() || !mounted) return;
    setState(() => allowPop = true);
    Navigator.of(context).pop();
  }

  Future<void> _save() async {
    final current = document;
    if (current == null || !dirty || saving) return;
    final delta = _lineDelta(current.content, code.text);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Simpan ke PC?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(current.path),
            const SizedBox(height: 10),
            Text('+${delta.$1} baris  •  -${delta.$2} baris'),
            const SizedBox(height: 6),
            const Text('Edit manual ini tidak memakai token AI.'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Batal'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.save_outlined),
            label: const Text('Simpan'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => saving = true);
    try {
      final saved = await widget.editor.saveWorkspaceFile(
        path: current.path,
        content: code.text,
        baseHash: current.hash,
      );
      document = saved;
      code.text = saved.content;
      mode = _FileViewMode.preview;
      await widget.onSaved();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('File tersimpan ke PC • 0 token AI')),
      );
    } catch (error) {
      if (!mounted) return;
      final conflict = error.toString().contains('HTTP 409');
      if (conflict) {
        final reload = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('File berubah di PC'),
            content: const Text(
              'Versi PC lebih baru. Muat ulang untuk mencegah perubahan tertimpa.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Pertahankan edit'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Muat ulang'),
              ),
            ],
          ),
        );
        if (reload == true && mounted) _reload();
      } else {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Gagal menyimpan: $error')));
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  void dispose() {
    code
      ..removeListener(_changed)
      ..dispose();
    search
      ..removeListener(_changed)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: allowPop || !dirty,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _close();
    },
    child: Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: IconButton(
          tooltip: 'Kembali',
          onPressed: _close,
          icon: const Icon(Icons.arrow_back),
        ),
        title: Text(
          document?.name ?? widget.path.split('/').last,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: 'Salin path',
            onPressed: () =>
                Clipboard.setData(ClipboardData(text: widget.path)),
            icon: const Icon(Icons.content_copy_outlined),
          ),
          IconButton(
            tooltip: 'Muat ulang',
            onPressed: dirty ? null : _reload,
            icon: const Icon(Icons.refresh),
          ),
          IconButton.filled(
            tooltip: 'Simpan ke PC',
            onPressed: dirty && !saving ? _save : null,
            icon: saving
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: FutureBuilder<WorkspaceFileDocument>(
        future: load,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting &&
              snapshot.data == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError || snapshot.data == null) {
            return _FileLoadError(error: snapshot.error, onRetry: _reload);
          }
          final value = document ?? snapshot.data!;
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Column(
                children: [
                  _FileHeader(document: value, dirty: dirty),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<_FileViewMode>(
                      segments: [
                        const ButtonSegment(
                          value: _FileViewMode.preview,
                          icon: Icon(Icons.visibility_outlined),
                          label: Text('Preview'),
                        ),
                        const ButtonSegment(
                          value: _FileViewMode.diff,
                          icon: Icon(Icons.difference_outlined),
                          label: Text('Diff'),
                        ),
                        ButtonSegment(
                          value: _FileViewMode.edit,
                          enabled: value.editable,
                          icon: const Icon(Icons.edit_outlined),
                          label: const Text('Edit'),
                        ),
                      ],
                      selected: {mode},
                      onSelectionChanged: (selection) {
                        setState(() => mode = selection.first);
                      },
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (mode != _FileViewMode.edit)
                    TextField(
                      controller: search,
                      decoration: InputDecoration(
                        isDense: true,
                        prefixIcon: const Icon(Icons.search),
                        hintText: 'Cari dalam file',
                        suffixIcon: search.text.isEmpty
                            ? null
                            : IconButton(
                                tooltip: 'Hapus pencarian',
                                onPressed: search.clear,
                                icon: const Icon(Icons.close),
                              ),
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  if (mode != _FileViewMode.edit) const SizedBox(height: 10),
                  Expanded(
                    child: switch (mode) {
                      _FileViewMode.preview => _CodePane(
                        text: value.content,
                        query: search.text,
                      ),
                      _FileViewMode.diff =>
                        value.diff.isEmpty
                            ? const _NoDiffCard()
                            : _CodePane(
                                text: value.diff,
                                query: search.text,
                                diff: true,
                              ),
                      _FileViewMode.edit => TextField(
                        controller: code,
                        expands: true,
                        minLines: null,
                        maxLines: null,
                        keyboardType: TextInputType.multiline,
                        textAlignVertical: TextAlignVertical.top,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 13,
                          height: 1.45,
                        ),
                        decoration: const InputDecoration(
                          alignLabelWithHint: true,
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.all(12),
                        ),
                      ),
                    },
                  ),
                ],
              ),
            ),
          );
        },
      ),
    ),
  );
}

class _FileHeader extends StatelessWidget {
  const _FileHeader({required this.document, required this.dirty});
  final WorkspaceFileDocument document;
  final bool dirty;

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.description_outlined),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  document.path,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
              ),
              if (dirty)
                const Chip(
                  avatar: Icon(Icons.circle, size: 10),
                  label: Text('Belum disimpan'),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              _FileMetaChip(
                icon: Icons.data_object_outlined,
                label: _formatFileBytes(document.size),
              ),
              _FileMetaChip(
                icon: Icons.format_list_numbered,
                label: '${document.lineCount} baris',
              ),
              const _FileMetaChip(
                icon: Icons.savings_outlined,
                label: 'Manual • 0 token',
              ),
              if (document.gitStatus.isNotEmpty)
                _FileMetaChip(
                  icon: Icons.difference_outlined,
                  label: document.gitStatus,
                ),
              if (!document.editable)
                const _FileMetaChip(
                  icon: Icons.lock_outline,
                  label: 'Read-only',
                ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _FileMetaChip extends StatelessWidget {
  const _FileMetaChip({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(999),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15),
        const SizedBox(width: 5),
        Text(label, style: Theme.of(context).textTheme.labelMedium),
      ],
    ),
  );
}

class _CodePane extends StatelessWidget {
  const _CodePane({required this.text, this.query = '', this.diff = false});
  final String text, query;
  final bool diff;

  @override
  Widget build(BuildContext context) {
    final lines = text.split('\n');
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceContainerLowest,
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Scrollbar(
        child: ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: lines.length,
          itemBuilder: (context, index) {
            final line = lines[index];
            final background = !diff
                ? Colors.transparent
                : line.startsWith('+') && !line.startsWith('+++')
                ? Colors.green.withValues(alpha: .12)
                : line.startsWith('-') && !line.startsWith('---')
                ? Colors.red.withValues(alpha: .12)
                : line.startsWith('@@')
                ? colors.primary.withValues(alpha: .10)
                : Colors.transparent;
            return Container(
              color: background,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 44,
                    child: Text(
                      '${index + 1}',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _HighlightedCodeLine(line: line, query: query),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _HighlightedCodeLine extends StatelessWidget {
  const _HighlightedCodeLine({required this.line, required this.query});
  final String line, query;

  @override
  Widget build(BuildContext context) {
    final normalizedQuery = query.trim().toLowerCase();
    final index = normalizedQuery.isEmpty
        ? -1
        : line.toLowerCase().indexOf(normalizedQuery);
    final base = TextStyle(
      fontFamily: 'monospace',
      fontSize: 13,
      height: 1.45,
      color: Theme.of(context).colorScheme.onSurface,
    );
    if (index < 0) {
      return SelectableText(line.isEmpty ? ' ' : line, style: base);
    }
    return SelectableText.rich(
      TextSpan(
        style: base,
        children: [
          TextSpan(text: line.substring(0, index)),
          TextSpan(
            text: line.substring(index, index + normalizedQuery.length),
            style: TextStyle(
              backgroundColor: Theme.of(context).colorScheme.tertiaryContainer,
              fontWeight: FontWeight.w800,
            ),
          ),
          TextSpan(text: line.substring(index + normalizedQuery.length)),
        ],
      ),
    );
  }
}

class _NoDiffCard extends StatelessWidget {
  const _NoDiffCard();

  @override
  Widget build(BuildContext context) => const Center(
    child: Card(
      child: Padding(
        padding: EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle_outline, size: 40),
            SizedBox(height: 10),
            Text('Tidak ada diff Git untuk file ini'),
          ],
        ),
      ),
    ),
  );
}

class _FileLoadError extends StatelessWidget {
  const _FileLoadError({required this.error, required this.onRetry});
  final Object? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.file_present_outlined,
            size: 48,
            color: Theme.of(context).colorScheme.error,
          ),
          const SizedBox(height: 12),
          const Text(
            'File tidak dapat dibuka',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            '$error',
            textAlign: TextAlign.center,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 14),
          FilledButton.tonalIcon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('Coba lagi'),
          ),
        ],
      ),
    ),
  );
}

(int, int) _lineDelta(String before, String after) {
  Map<String, int> counts(String value) {
    final result = <String, int>{};
    for (final line in value.split('\n')) {
      result[line] = (result[line] ?? 0) + 1;
    }
    return result;
  }

  final beforeLines = counts(before);
  final afterLines = counts(after);
  var additions = 0;
  var deletions = 0;
  for (final line in {...beforeLines.keys, ...afterLines.keys}) {
    final delta = (afterLines[line] ?? 0) - (beforeLines[line] ?? 0);
    if (delta > 0) additions += delta;
    if (delta < 0) deletions -= delta;
  }
  return (additions, deletions);
}

String _formatFileBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

class _EnvironmentRow extends StatelessWidget {
  const _EnvironmentRow({
    required this.icon,
    required this.title,
    this.subtitle = '',
    this.trailing,
  });
  final IconData icon;
  final String title, subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        Icon(
          icon,
          size: 19,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
              if (subtitle.isNotEmpty)
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
        ?trailing,
      ],
    ),
  );
}

class _GitMetricCard extends StatelessWidget {
  const _GitMetricCard({
    required this.icon,
    required this.value,
    required this.label,
  });
  final IconData icon;
  final int value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: colors.primaryContainer.withValues(alpha: .55),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(icon, size: 19, color: colors.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$value',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _GitFilterChip extends StatelessWidget {
  const _GitFilterChip({
    required this.label,
    required this.count,
    required this.selected,
    required this.onSelected,
  });
  final String label;
  final int count;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: FilterChip(
      selected: selected,
      onSelected: (_) => onSelected(),
      label: Text('$label ($count)'),
    ),
  );
}

class _GitChangeTile extends StatelessWidget {
  const _GitChangeTile(this.entry, {required this.onTap});
  final GitStatusEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = _gitStatusColor(Theme.of(context).colorScheme, entry.status);
    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      leading: CircleAvatar(
        radius: 18,
        backgroundColor: color.withValues(alpha: .12),
        child: Icon(_gitStatusIcon(entry.status), size: 19, color: color),
      ),
      title: Text(entry.path, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _GitStatusBadge(entry.status),
          const SizedBox(width: 4),
          const Icon(Icons.chevron_right),
        ],
      ),
    );
  }
}

class _GitStatusBadge extends StatelessWidget {
  const _GitStatusBadge(this.status);
  final GitFileStatus status;

  @override
  Widget build(BuildContext context) {
    final color = _gitStatusColor(Theme.of(context).colorScheme, status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        _gitStatusLabel(status),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

String _gitStatusLabel(GitFileStatus status) => switch (status) {
  GitFileStatus.added => 'Ditambah',
  GitFileStatus.modified => 'Diubah',
  GitFileStatus.deleted => 'Dihapus',
  GitFileStatus.untracked => 'Baru',
};

IconData _gitStatusIcon(GitFileStatus status) => switch (status) {
  GitFileStatus.added => Icons.add_circle_outline,
  GitFileStatus.modified => Icons.edit_outlined,
  GitFileStatus.deleted => Icons.delete_outline,
  GitFileStatus.untracked => Icons.fiber_new_outlined,
};

Color _gitStatusColor(ColorScheme colors, GitFileStatus status) =>
    switch (status) {
      GitFileStatus.added => Colors.green.shade700,
      GitFileStatus.modified => colors.tertiary,
      GitFileStatus.deleted => colors.error,
      GitFileStatus.untracked => colors.primary,
    };

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

class UsagePage extends StatefulWidget {
  const UsagePage(this.c, {super.key});
  final AppController c;

  @override
  State<UsagePage> createState() => _UsagePageState();
}

class _UsagePageState extends State<UsagePage> {
  String range = '24h';
  String provider = '';
  String model = '';
  String scope = 'all';
  bool showDetails = false;
  late Future<ProviderUsageSnapshot> usage;

  ProviderUsageMonitor? get monitor => switch (widget.c.connector) {
    final ProviderUsageMonitor value => value,
    _ => null,
  };

  @override
  void initState() {
    super.initState();
    usage = _request();
  }

  Future<ProviderUsageSnapshot> _request() {
    final current = monitor;
    if (current == null) {
      return Future.value(
        const ProviderUsageSnapshot(
          available: false,
          source: '9router',
          range: '24h',
          summary: ProviderUsageSummary(),
          providers: [],
          models: [],
          recent: [],
          attribution: '',
          reason: 'Connector aktif belum mendukung telemetry provider.',
        ),
      );
    }
    return current.getProviderUsage(
      range: range,
      provider: provider,
      model: model,
      scope: scope,
    );
  }

  void reload() {
    setState(() {
      usage = _request();
    });
  }

  void selectRange(String value) {
    if (range == value) return;
    range = value;
    reload();
  }

  void selectProvider(String? value) {
    provider = value ?? '';
    reload();
  }

  void selectModel(String? value) {
    model = value ?? '';
    reload();
  }

  void selectScope(String value) {
    if (scope == value) return;
    scope = value;
    provider = '';
    model = '';
    reload();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<ProviderUsageSnapshot>(
    future: usage,
    builder: (context, snapshot) {
      final value = snapshot.data;
      return RefreshIndicator(
        onRefresh: () async {
          reload();
          await usage;
        },
        child: ListView(
          key: const ValueKey('provider-usage-page'),
          padding: const EdgeInsets.all(16),
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Pemakaian Token',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      Text(
                        'Telemetry read-only dari 9Router di PC.',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton.filledTonal(
                  tooltip: 'Muat ulang telemetry',
                  onPressed: reload,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _UsageScopeSelector(scope: scope, onChanged: selectScope),
            const SizedBox(height: 12),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children:
                    const {
                      'today': 'Hari ini',
                      '24h': '24 jam',
                      '7d': '7 hari',
                      '30d': '30 hari',
                      '60d': '60 hari',
                    }.entries.map((entry) {
                      return Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(entry.value),
                          selected: range == entry.key,
                          onSelected: (_) => selectRange(entry.key),
                        ),
                      );
                    }).toList(),
              ),
            ),
            const SizedBox(height: 12),
            if (snapshot.connectionState == ConnectionState.waiting &&
                value == null)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(20),
                  child: Center(child: CircularProgressIndicator()),
                ),
              )
            else if (snapshot.hasError)
              _UsageUnavailableCard(
                message:
                    'Telemetry gagal dimuat. Periksa backend Agent Remote.',
                onRetry: reload,
              )
            else if (value == null || !value.available)
              _UsageUnavailableCard(
                message: value?.reason.isNotEmpty == true
                    ? value!.reason
                    : '9Router belum terdeteksi di PC.',
                onRetry: reload,
              )
            else if (scope == 'mobile' && !value.mobileFilterAvailable)
              _MobileUsageSetupCard(
                keyName: value.mobileKeyName,
                message: value.reason,
                onRetry: reload,
              )
            else ...[
              _UsageFilters(
                snapshot: value,
                provider: provider,
                model: model,
                onProviderChanged: selectProvider,
                onModelChanged: selectModel,
              ),
              const SizedBox(height: 12),
              _UsageSummaryGrid(value.summary),
              const SizedBox(height: 12),
              Card(
                clipBehavior: Clip.antiAlias,
                child: ExpansionTile(
                  initiallyExpanded: showDetails,
                  onExpansionChanged: (expanded) =>
                      setState(() => showDetails = expanded),
                  leading: const Icon(Icons.insights_outlined),
                  title: Text(
                    value.active?.model ?? 'Model belum aktif',
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  subtitle: Text(
                    value.active == null
                        ? 'Model, quota, dan atribusi tersembunyi'
                        : '${value.active!.provider} • model aktif',
                  ),
                  children: [
                    _ActiveModelCard(value.active),
                    _QuotaTracker(value.quotaAccounts),
                    Card(
                      color: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHighest,
                      child: ListTile(
                        leading: Icon(
                          scope == 'mobile'
                              ? Icons.phone_android_outlined
                              : Icons.computer_outlined,
                        ),
                        title: Text(
                          scope == 'mobile'
                              ? 'Konsumsi task dari HP'
                              : 'Semua konsumsi PC',
                        ),
                        subtitle: Text(
                          scope == 'mobile'
                              ? 'Atribusi memakai API key 9Router khusus Agent Remote. Key tidak pernah dikirim ke HP.'
                              : 'Mencakup seluruh request 9Router pada PC, termasuk Codex Desktop dan CLI.',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Request terbaru',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              if (value.recent.isEmpty)
                const Card(
                  child: ListTile(
                    leading: Icon(Icons.inbox_outlined),
                    title: Text('Tidak ada request pada filter ini'),
                  ),
                )
              else
                Card(
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      for (
                        var index = 0;
                        index < value.recent.length;
                        index++
                      ) ...[
                        if (index > 0) const Divider(height: 1),
                        _UsageRequestTile(value.recent[index]),
                      ],
                    ],
                  ),
                ),
            ],
          ],
        ),
      );
    },
  );
}

class _QuotaTracker extends StatelessWidget {
  const _QuotaTracker(this.accounts);
  final List<ProviderQuotaAccount> accounts;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Quota 9Router',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            Text('${accounts.where((value) => value.active).length} aktif'),
          ],
        ),
        const SizedBox(height: 8),
        if (accounts.isEmpty)
          const Card(
            child: ListTile(
              leading: Icon(Icons.data_usage_outlined),
              title: Text('Account 9Router belum terbaca'),
            ),
          )
        else
          ...accounts.map((account) {
            final healthy =
                account.active &&
                account.status == 'active' &&
                !account.limitReached;
            final remaining = account.quotas.fold<double>(
              100,
              (lowest, quota) => quota.remainingPercent < lowest
                  ? quota.remainingPercent
                  : lowest,
            );
            return Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ExpansionTile(
                initiallyExpanded: false,
                leading: CircleAvatar(
                  backgroundColor:
                      (healthy
                              ? Colors.green
                              : account.active
                              ? colors.error
                              : colors.outline)
                          .withValues(alpha: .12),
                  child: Icon(
                    Icons.route_outlined,
                    color: healthy
                        ? Colors.green.shade700
                        : account.active
                        ? colors.error
                        : colors.outline,
                  ),
                ),
                title: Text(
                  account.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  [
                    account.provider,
                    if (account.plan.isNotEmpty) account.plan,
                    if (account.model.isNotEmpty) account.model,
                    if (account.quotas.isNotEmpty)
                      '${remaining.toStringAsFixed(0)}% tersisa',
                    account.active ? account.status : 'nonaktif',
                  ].join(' • '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                children: [
                  if (account.quotas.isEmpty)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        account.error.isNotEmpty
                            ? account.error
                            : 'Provider tidak menyediakan persentase quota.',
                        style: TextStyle(color: colors.onSurfaceVariant),
                      ),
                    )
                  else
                    ...account.quotas.map(
                      (quota) => Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    quota.label,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                Text(
                                  '${quota.remainingPercent.toStringAsFixed(0)}% tersisa',
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            LinearProgressIndicator(
                              value: quota.usedPercent / 100,
                            ),
                            if (quota.resetAt != null) ...[
                              const SizedBox(height: 4),
                              Text(
                                'Reset ${formatLocalClock(quota.resetAt!)}',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            );
          }),
      ],
    );
  }
}

class _UsageScopeSelector extends StatelessWidget {
  const _UsageScopeSelector({required this.scope, required this.onChanged});
  final String scope;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Sumber penggunaan',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                  value: 'all',
                  icon: Icon(Icons.computer_outlined),
                  label: Text('Semua PC'),
                ),
                ButtonSegment(
                  value: 'mobile',
                  icon: Icon(Icons.phone_android_outlined),
                  label: Text('Dari HP'),
                ),
              ],
              selected: {scope},
              onSelectionChanged: (values) => onChanged(values.first),
            ),
          ),
        ],
      ),
    ),
  );
}

class _MobileUsageSetupCard extends StatelessWidget {
  const _MobileUsageSetupCard({
    required this.keyName,
    required this.message,
    required this.onRetry,
  });
  final String keyName, message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.key_outlined),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Aktifkan atribusi HP',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            message.isEmpty
                ? 'Buat API key khusus pada 9Router agar request HP tidak tercampur dengan desktop.'
                : message,
          ),
          const SizedBox(height: 8),
          SelectableText(
            keyName.isEmpty ? 'Agent Remote Mobile' : keyName,
            style: const TextStyle(fontFamily: 'monospace'),
          ),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('Cek lagi'),
          ),
        ],
      ),
    ),
  );
}

class _UsageFilters extends StatelessWidget {
  const _UsageFilters({
    required this.snapshot,
    required this.provider,
    required this.model,
    required this.onProviderChanged,
    required this.onModelChanged,
  });
  final ProviderUsageSnapshot snapshot;
  final String provider, model;
  final ValueChanged<String?> onProviderChanged, onModelChanged;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth < 600
          ? constraints.maxWidth
          : (constraints.maxWidth - 12) / 2;
      return Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          SizedBox(
            width: width,
            child: DropdownButtonFormField<String>(
              initialValue: snapshot.providers.contains(provider)
                  ? provider
                  : '',
              decoration: const InputDecoration(
                labelText: 'Provider',
                border: OutlineInputBorder(),
              ),
              items: [
                const DropdownMenuItem(
                  value: '',
                  child: Text('Semua provider'),
                ),
                ...snapshot.providers.map(
                  (value) => DropdownMenuItem(value: value, child: Text(value)),
                ),
              ],
              onChanged: onProviderChanged,
            ),
          ),
          SizedBox(
            width: width,
            child: DropdownButtonFormField<String>(
              initialValue: snapshot.models.contains(model) ? model : '',
              decoration: const InputDecoration(
                labelText: 'Model',
                border: OutlineInputBorder(),
              ),
              items: [
                const DropdownMenuItem(value: '', child: Text('Semua model')),
                ...snapshot.models.map(
                  (value) => DropdownMenuItem(value: value, child: Text(value)),
                ),
              ],
              onChanged: onModelChanged,
            ),
          ),
        ],
      );
    },
  );
}

class _UsageSummaryGrid extends StatelessWidget {
  const _UsageSummaryGrid(this.summary);
  final ProviderUsageSummary summary;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = constraints.maxWidth >= 720 ? 5 : 2;
      final width = (constraints.maxWidth - ((columns - 1) * 8)) / columns;
      return Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _UsageMetric(
            width,
            'Request',
            _formatUsageNumber(summary.requests),
            Colors.white,
          ),
          _UsageMetric(
            width,
            'Input',
            _formatUsageNumber(summary.inputTokens),
            Colors.deepOrangeAccent,
          ),
          _UsageMetric(
            width,
            'Output',
            _formatUsageNumber(summary.outputTokens),
            Colors.greenAccent,
          ),
          _UsageMetric(
            width,
            'Cache',
            _formatUsageNumber(summary.cachedTokens),
            Colors.lightBlueAccent,
          ),
          _UsageMetric(
            width,
            'Est. biaya',
            '\$${summary.estimatedCost.toStringAsFixed(2)}',
            Colors.amberAccent,
          ),
        ],
      );
    },
  );
}

class _UsageMetric extends StatelessWidget {
  const _UsageMetric(this.width, this.label, this.value, this.color);
  final double width;
  final String label, value;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label.toUpperCase(),
              style: Theme.of(context).textTheme.labelSmall,
            ),
            const SizedBox(height: 6),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: color,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _ActiveModelCard extends StatelessWidget {
  const _ActiveModelCard(this.entry);
  final ProviderUsageEntry? entry;

  @override
  Widget build(BuildContext context) {
    final value = entry;
    if (value == null) {
      return const Card(
        child: ListTile(
          leading: Icon(Icons.route_outlined),
          title: Text('Belum ada model aktif'),
        ),
      );
    }
    final activeColor = value.isActive
        ? Colors.green.shade700
        : Colors.orange.shade700;
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: activeColor.withValues(alpha: .14),
          child: Icon(Icons.route_outlined, color: activeColor),
        ),
        title: Text(
          value.model,
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        subtitle: Text(
          '${value.provider} • ${value.isActive ? 'Aktif sekarang' : 'Terakhir digunakan'} • ${formatLocalClock(value.timestamp)}',
        ),
        trailing: value.isActive
            ? const Icon(Icons.circle, size: 12, color: Colors.green)
            : null,
      ),
    );
  }
}

class _UsageRequestTile extends StatelessWidget {
  const _UsageRequestTile(this.entry);
  final ProviderUsageEntry entry;

  @override
  Widget build(BuildContext context) => ListTile(
    dense: true,
    leading: Icon(
      entry.status == 'ok' ? Icons.circle : Icons.error_outline,
      size: entry.status == 'ok' ? 10 : 20,
      color: entry.status == 'ok'
          ? Colors.green
          : Theme.of(context).colorScheme.error,
    ),
    title: Text(entry.model, maxLines: 1, overflow: TextOverflow.ellipsis),
    subtitle: Text(
      '${entry.provider} • ${formatLocalClock(entry.timestamp)} • cache ${_formatUsageNumber(entry.cachedTokens)}',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
    trailing: Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '${_formatUsageNumber(entry.inputTokens)}↑',
            style: const TextStyle(color: Colors.deepOrangeAccent),
          ),
          const TextSpan(text: '  '),
          TextSpan(
            text: '${_formatUsageNumber(entry.outputTokens)}↓',
            style: const TextStyle(color: Colors.greenAccent),
          ),
        ],
      ),
      textAlign: TextAlign.end,
    ),
  );
}

class _UsageUnavailableCard extends StatelessWidget {
  const _UsageUnavailableCard({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      leading: const Icon(Icons.monitor_heart_outlined),
      title: const Text('Telemetry belum tersedia'),
      subtitle: Text(message),
      trailing: IconButton(
        tooltip: 'Coba lagi',
        onPressed: onRetry,
        icon: const Icon(Icons.refresh),
      ),
    ),
  );
}

String _formatUsageNumber(int value) {
  final digits = value.abs().toString();
  final buffer = StringBuffer();
  for (var index = 0; index < digits.length; index++) {
    if (index > 0 && (digits.length - index) % 3 == 0) buffer.write('.');
    buffer.write(digits[index]);
  }
  return '${value < 0 ? '-' : ''}$buffer';
}

class _NotificationSoundCard extends StatefulWidget {
  const _NotificationSoundCard();

  @override
  State<_NotificationSoundCard> createState() => _NotificationSoundCardState();
}

class _NotificationSoundCardState extends State<_NotificationSoundCard> {
  String name = '';
  bool loading = true;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final value = await BackgroundTaskMonitor.getNotificationSound();
      if (mounted) name = value?['name'] ?? '';
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _pick() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final value = await BackgroundTaskMonitor.pickNotificationSound();
      if (mounted && value != null) {
        setState(() => name = value['name'] ?? 'Suara custom');
      }
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _reset() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await BackgroundTaskMonitor.clearNotificationSound();
      if (mounted) setState(() => name = '');
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _preview() async {
    if (busy || name.isEmpty) return;
    setState(() => busy = true);
    try {
      await BackgroundTaskMonitor.previewNotificationSound();
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void _showError(Object error) {
    if (!mounted) return;
    final message = error is PlatformException
        ? error.message ?? 'File suara tidak dapat dipakai.'
        : 'File suara tidak dapat dipakai.';
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const CircleAvatar(child: Icon(Icons.music_note_outlined)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      loading
                          ? 'Membaca suara...'
                          : name.isEmpty
                          ? 'Suara default Android'
                          : name,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      name.isEmpty
                          ? 'Pilih audio dari Downloads, Drive, atau aplikasi lain. Maksimal 50 MB.'
                          : 'File tersimpan aman di aplikasi dan tetap aktif setelah restart.',
                    ),
                  ],
                ),
              ),
              if (busy || loading) ...[
                const SizedBox(width: 12),
                const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (name.isNotEmpty)
                  TextButton.icon(
                    onPressed: busy ? null : _reset,
                    icon: const Icon(Icons.restart_alt),
                    label: const Text('Default'),
                  ),
                if (name.isNotEmpty)
                  OutlinedButton.icon(
                    onPressed: busy ? null : _preview,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Preview'),
                  ),
                FilledButton.tonalIcon(
                  onPressed: loading || busy ? null : _pick,
                  icon: const Icon(Icons.audio_file_outlined),
                  label: const Text('Pilih file'),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class SettingsPage extends StatelessWidget {
  const SettingsPage(this.c, this.connections, {super.key});
  final AppController c;
  final ConnectionSettingsController connections;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: connections,
    builder: (context, _) {
      final colors = Theme.of(context).colorScheme;
      final selectedProvider = connections.selectedProvider;
      final enabledProfiles = connections.profiles
          .where((profile) => profile.isEnabled)
          .length;
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Pengaturan', style: Theme.of(context).textTheme.headlineSmall),
          Text(
            'Atur tampilan, koneksi PC, dan profil gateway.',
            style: TextStyle(color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          const _SettingsSectionTitle(
            icon: Icons.palette_outlined,
            title: 'Tampilan',
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Tema aplikasi'),
                  const SizedBox(height: 10),
                  SegmentedButton<ThemeModeChoice>(
                    showSelectedIcon: false,
                    segments: ThemeModeChoice.values
                        .map(
                          (choice) => ButtonSegment(
                            value: choice,
                            label: Text(_themeModeLabel(choice)),
                          ),
                        )
                        .toList(),
                    selected: {c.theme},
                    onSelectionChanged: (choice) => c.setTheme(choice.first),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          const _SettingsSectionTitle(
            icon: Icons.hub_outlined,
            title: 'Koneksi PC',
          ),
          Card(
            clipBehavior: Clip.antiAlias,
            child: ListTile(
              contentPadding: const EdgeInsets.all(14),
              leading: CircleAvatar(
                backgroundColor:
                    (c.connected ? Colors.green.shade700 : colors.error)
                        .withValues(alpha: .12),
                child: Icon(
                  c.connected
                      ? Icons.desktop_windows_outlined
                      : Icons.link_off_outlined,
                  color: c.connected ? Colors.green.shade700 : colors.error,
                ),
              ),
              title: Text(
                c.connected ? 'PC terhubung' : 'PC belum terhubung',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(
                '${selectedProvider?.displayName ?? 'Pilih metode koneksi'}\n'
                '$enabledProfiles profil aktif • ${connections.catalog.providers.length} provider',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
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
          FilledButton.tonalIcon(
            onPressed: () => scanPairingQr(context, c, connections),
            icon: const Icon(Icons.qr_code_scanner_rounded),
            label: const Text('Scan QR Pairing'),
          ),
          if (c.connectorError case final error?)
            Card(
              color: colors.errorContainer,
              child: ListTile(
                leading: Icon(Icons.error_outline, color: colors.error),
                title: const Text('Koneksi membutuhkan perhatian'),
                subtitle: Text(error),
              ),
            ),
          const SizedBox(height: 12),
          const _SettingsSectionTitle(
            icon: Icons.notifications_active_outlined,
            title: 'Notifikasi task',
          ),
          const _NotificationSoundCard(),
          if (c.connector case final SecurityMonitor monitor) ...[
            const SizedBox(height: 12),
            const _SettingsSectionTitle(
              icon: Icons.security_outlined,
              title: 'Keamanan API',
            ),
            _SecurityAuditCard(
              monitor,
              weakToken: switch (c.connector) {
                final HermesRemoteConnector remote =>
                  remote.token.trim().length < 16 || remote.token == 'admin',
                _ => false,
              },
            ),
          ],
          const SizedBox(height: 12),
          const _SettingsSectionTitle(
            icon: Icons.info_outline,
            title: 'Tentang',
          ),
          const Card(
            child: ListTile(
              leading: Icon(Icons.smart_toy_outlined),
              title: Text('Agent Remote 0.3.0'),
              subtitle: Text('Remote controller untuk multi-agent di PC'),
            ),
          ),
        ],
      );
    },
  );
}

class _SecurityAuditCard extends StatefulWidget {
  const _SecurityAuditCard(this.monitor, {required this.weakToken});
  final SecurityMonitor monitor;
  final bool weakToken;

  @override
  State<_SecurityAuditCard> createState() => _SecurityAuditCardState();
}

class _SecurityAuditCardState extends State<_SecurityAuditCard> {
  late Future<SecurityAuditSnapshot> audit;

  @override
  void initState() {
    super.initState();
    audit = widget.monitor.getSecurityAudit();
  }

  @override
  void didUpdateWidget(covariant _SecurityAuditCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.monitor, widget.monitor)) {
      audit = widget.monitor.getSecurityAudit();
    }
  }

  void refresh() => setState(() => audit = widget.monitor.getSecurityAudit());

  @override
  Widget build(BuildContext context) => Card(
    clipBehavior: Clip.antiAlias,
    child: FutureBuilder<SecurityAuditSnapshot>(
      future: audit,
      builder: (context, snapshot) {
        final colors = Theme.of(context).colorScheme;
        if (snapshot.connectionState != ConnectionState.done) {
          return const Column(
            children: [
              ListTile(
                leading: Icon(Icons.admin_panel_settings_outlined),
                title: Text('Memuat log akses API'),
                subtitle: Text('Membaca audit lokal dari server PC.'),
              ),
              LinearProgressIndicator(),
            ],
          );
        }
        if (snapshot.hasError) {
          return ListTile(
            leading: Icon(Icons.warning_amber_rounded, color: colors.error),
            title: const Text('Log akses tidak dapat dimuat'),
            subtitle: const Text(
              'Backend lama mungkin belum mendukung audit IP.',
            ),
            trailing: IconButton(
              tooltip: 'Coba lagi',
              onPressed: refresh,
              icon: const Icon(Icons.refresh),
            ),
          );
        }
        final value = snapshot.data!;
        final denied = value.entries.where((entry) => !entry.authorized).length;
        return Column(
          children: [
            ListTile(
              leading: CircleAvatar(
                backgroundColor:
                    (denied > 0 ? colors.error : Colors.green.shade700)
                        .withValues(alpha: .12),
                child: Icon(
                  denied > 0
                      ? Icons.gpp_maybe_outlined
                      : Icons.verified_user_outlined,
                  color: denied > 0 ? colors.error : Colors.green.shade700,
                ),
              ),
              title: const Text(
                'Akses API terbaru',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(
                value.entries.isEmpty
                    ? 'Belum ada akses yang tercatat.'
                    : '${value.entries.length} event • $denied ditolak',
              ),
              trailing: IconButton(
                tooltip: 'Muat ulang log',
                onPressed: refresh,
                icon: const Icon(Icons.refresh),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'IP berasal dari koneksi langsung ke server. Log tidak menyimpan token, password, prompt, atau output agent.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            if (widget.weakToken)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: colors.errorContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  'Token koneksi masih lemah atau memakai default admin. Ganti dengan token acak minimal 16 karakter sebelum server diakses perangkat lain.',
                  style: TextStyle(color: colors.onErrorContainer),
                ),
              ),
            if (value.entries.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Hubungkan HP lalu muat ulang untuk melihat IP.'),
                ),
              )
            else
              ...value.entries
                  .take(8)
                  .map(
                    (entry) => ListTile(
                      dense: true,
                      leading: Icon(
                        entry.authorized
                            ? Icons.login_rounded
                            : Icons.block_outlined,
                        color: entry.authorized
                            ? Colors.green.shade700
                            : colors.error,
                      ),
                      title: Text(
                        entry.ipAddress,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      subtitle: Text(
                        '${entry.authorized ? 'Akses berhasil' : 'Akses ditolak'} • '
                        '${formatLocalClock(entry.timestamp)}\n'
                        '${entry.method} ${entry.path}'
                        '${entry.userAgent.isEmpty ? '' : ' • ${entry.userAgent}'}',
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
          ],
        );
      },
    ),
  );
}

class _SettingsSectionTitle extends StatelessWidget {
  const _SettingsSectionTitle({required this.icon, required this.title});
  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 4, bottom: 6),
    child: Row(
      children: [
        Icon(icon, size: 19),
        const SizedBox(width: 8),
        Text(title, style: Theme.of(context).textTheme.titleMedium),
      ],
    ),
  );
}

String _themeModeLabel(ThemeModeChoice choice) => switch (choice) {
  ThemeModeChoice.system => 'Sistem',
  ThemeModeChoice.light => 'Terang',
  ThemeModeChoice.dark => 'Gelap',
};

class ConnectionSettingsScreen extends StatelessWidget {
  const ConnectionSettingsScreen(this.controller, this.app, {super.key});
  final ConnectionSettingsController controller;
  final AppController app;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Koneksi Agent Remote'),
      actions: [
        IconButton(
          onPressed: () => scanPairingQr(context, app, controller),
          tooltip: 'Hubungkan dengan QR',
          icon: const Icon(Icons.qr_code_scanner_rounded),
        ),
      ],
    ),
    body: ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final colors = Theme.of(context).colorScheme;
        final selectedProvider = controller.selectedProvider;
        final providerProfiles =
            selectedProvider == null
                  ? <ConnectionProfile>[]
                  : controller.profilesForProvider(selectedProvider.id).toList()
              ..sort((left, right) {
                if (left.isDefault != right.isDefault) {
                  return left.isDefault ? -1 : 1;
                }
                if (left.isEnabled != right.isEnabled) {
                  return left.isEnabled ? -1 : 1;
                }
                return left.displayName.toLowerCase().compareTo(
                  right.displayName.toLowerCase(),
                );
              });
        final connectionProfile =
            providerProfiles
                .where((profile) => profile.isDefault && profile.isEnabled)
                .firstOrNull ??
            providerProfiles.where((profile) => profile.isEnabled).firstOrNull;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _ConnectionOverviewCard(app: app, controller: controller),
            if (controller.error case final error?)
              Card(
                color: colors.errorContainer,
                child: ListTile(
                  leading: Icon(Icons.error_outline, color: colors.error),
                  title: const Text('Konfigurasi gagal dimuat'),
                  subtitle: Text(error),
                ),
              ),
            const SizedBox(height: 14),
            Text(
              'Pilih sumber agent',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            Text(
              'Provider menentukan lokasi agent berjalan, bukan model API di dalam CLI.',
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            ...controller.catalog.providers.map(
              (provider) => _ConnectionProviderCard(
                provider: provider,
                selected: controller.selectedProviderId == provider.id,
                onTap: provider.enabled
                    ? () => controller.selectProvider(provider.id)
                    : null,
              ),
            ),
            if (selectedProvider case final provider?) ...[
              const SizedBox(height: 14),
              Text(
                'Konfigurasi ${provider.displayName}',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (provider.capabilities.isNotEmpty)
                Card(
                  child: ExpansionTile(
                    leading: const Icon(Icons.extension_outlined),
                    title: const Text('Kemampuan koneksi'),
                    subtitle: Text('${provider.capabilities.length} fitur'),
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: provider.capabilities
                                .map(
                                  (capability) => Chip(
                                    label: Text(
                                      _connectionCapabilityLabel(capability),
                                    ),
                                  ),
                                )
                                .toList(),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              if (provider.supportsProfiles) ...[
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Profil koneksi',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    Text('${providerProfiles.length} profil'),
                  ],
                ),
                if (providerProfiles.isEmpty)
                  const Card(
                    child: ListTile(
                      leading: Icon(Icons.add_link_outlined),
                      title: Text('Belum ada profil koneksi'),
                      subtitle: Text(
                        'Tambahkan endpoint PC sebelum menghubungkan aplikasi.',
                      ),
                    ),
                  )
                else
                  ...providerProfiles.map(
                    (profile) => _ConnectionProfileCard(
                      profile: profile,
                      onAction: (action) => _handleConnectionProfileAction(
                        context: context,
                        action: action,
                        controller: controller,
                        provider: provider,
                        profile: profile,
                      ),
                    ),
                  ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (provider.mode == ConnectionMode.remoteGateway)
                      FilledButton.icon(
                        onPressed: connectionProfile == null
                            ? null
                            : () => connectGateway(
                                context,
                                app,
                                controller,
                                connectionProfile,
                              ),
                        icon: const Icon(Icons.link),
                        label: Text(
                          app.connected ? 'Hubungkan ulang' : 'Hubungkan ke PC',
                        ),
                      ),
                    OutlinedButton.icon(
                      onPressed: () =>
                          profileDialog(context, controller, provider, null),
                      icon: const Icon(Icons.add),
                      label: const Text('Tambah profil'),
                    ),
                  ],
                ),
              ] else if (provider.supportsAuthentication)
                const Card(
                  child: ListTile(
                    leading: Icon(Icons.lock_clock_outlined),
                    title: Text('Login belum tersedia'),
                    subtitle: Text('Provider ini masih tahap integrasi.'),
                  ),
                ),
            ],
          ],
        );
      },
    ),
  );
}

class _ConnectionOverviewCard extends StatelessWidget {
  const _ConnectionOverviewCard({required this.app, required this.controller});
  final AppController app;
  final ConnectionSettingsController controller;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final statusColor = app.connected ? Colors.green.shade700 : colors.error;
    final activeProfiles = controller.profiles
        .where((profile) => profile.isEnabled)
        .length;
    return Card(
      color: statusColor.withValues(alpha: .08),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: statusColor.withValues(alpha: .3)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: statusColor.withValues(alpha: .14),
                  child: Icon(
                    app.connected ? Icons.lan_outlined : Icons.link_off,
                    color: statusColor,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        app.connected
                            ? 'PC terhubung'
                            : 'Belum terhubung ke PC',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      Text(
                        controller.selectedProvider?.displayName ??
                            'Pilih provider koneksi',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _ConnectionInfoBadge(
                  icon: Icons.hub_outlined,
                  label: '${controller.catalog.providers.length} provider',
                ),
                _ConnectionInfoBadge(
                  icon: Icons.person_pin_circle_outlined,
                  label: '$activeProfiles profil aktif',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ConnectionProviderCard extends StatelessWidget {
  const _ConnectionProviderCard({
    required this.provider,
    required this.selected,
    required this.onTap,
  });
  final ConnectionProviderDefinition provider;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final statusColor = _connectionProviderStatusColor(colors, provider);
    return Card(
      color: selected ? colors.primaryContainer.withValues(alpha: .45) : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(
          color: selected ? colors.primary : colors.outlineVariant,
          width: selected ? 1.5 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                backgroundColor: colors.primary.withValues(alpha: .1),
                child: Icon(resolveConnectionIcon(provider.iconKey)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            provider.displayName,
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                        if (selected)
                          Icon(Icons.check_circle, color: colors.primary),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      provider.description,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                    const SizedBox(height: 8),
                    _ConnectionInfoBadge(
                      icon: _connectionProviderStatusIcon(provider),
                      label: _connectionProviderStatusLabel(provider),
                      color: statusColor,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConnectionInfoBadge extends StatelessWidget {
  const _ConnectionInfoBadge({
    required this.icon,
    required this.label,
    this.color,
  });
  final IconData icon;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final resolved = color ?? Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: resolved.withValues(alpha: .1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: resolved),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: resolved,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _connectionProviderStatusLabel(ConnectionProviderDefinition provider) =>
    switch (provider.integrationStatus) {
      ConnectionIntegrationStatus.available => 'Siap digunakan',
      ConnectionIntegrationStatus.experimental => 'Eksperimental',
      ConnectionIntegrationStatus.deferred =>
        provider.supportsProfiles ? 'Perlu konfigurasi' : 'Tahap pengembangan',
      ConnectionIntegrationStatus.unavailable => 'Tidak tersedia',
      ConnectionIntegrationStatus.unknown => 'Status tidak diketahui',
    };

IconData _connectionProviderStatusIcon(ConnectionProviderDefinition provider) =>
    switch (provider.integrationStatus) {
      ConnectionIntegrationStatus.available => Icons.check_circle_outline,
      ConnectionIntegrationStatus.experimental => Icons.science_outlined,
      ConnectionIntegrationStatus.deferred => Icons.schedule_outlined,
      ConnectionIntegrationStatus.unavailable => Icons.block_outlined,
      ConnectionIntegrationStatus.unknown => Icons.help_outline,
    };

Color _connectionProviderStatusColor(
  ColorScheme colors,
  ConnectionProviderDefinition provider,
) => switch (provider.integrationStatus) {
  ConnectionIntegrationStatus.available => Colors.green.shade700,
  ConnectionIntegrationStatus.experimental => colors.tertiary,
  ConnectionIntegrationStatus.deferred => colors.secondary,
  ConnectionIntegrationStatus.unavailable => colors.error,
  ConnectionIntegrationStatus.unknown => colors.outline,
};

class _ConnectionProfileCard extends StatelessWidget {
  const _ConnectionProfileCard({required this.profile, required this.onAction});
  final ConnectionProfile profile;
  final ValueChanged<String> onAction;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final endpoint = profile.values['endpoint'] as String? ?? '';
    final transport = profile.values['transportType'] as String? ?? '';
    return Card(
      child: ListTile(
        leading: Icon(
          profile.isEnabled ? Icons.link_outlined : Icons.link_off_outlined,
          color: profile.isEnabled ? colors.primary : colors.outline,
        ),
        title: Text(
          profile.displayName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              [
                if (profile.isDefault) 'Default',
                profile.isEnabled ? 'Aktif' : 'Nonaktif',
              ].join(' • '),
            ),
            if (transport.isNotEmpty || endpoint.isNotEmpty)
              Text(
                [
                  if (transport.isNotEmpty) transport,
                  if (endpoint.isNotEmpty) endpoint,
                ].join(' • '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
        trailing: PopupMenuButton<String>(
          onSelected: onAction,
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'edit', child: Text('Edit profil')),
            PopupMenuItem(
              value: 'default',
              enabled: !profile.isDefault,
              child: const Text('Jadikan default'),
            ),
            PopupMenuItem(
              value: 'toggle',
              child: Text(profile.isEnabled ? 'Nonaktifkan' : 'Aktifkan'),
            ),
            const PopupMenuDivider(),
            const PopupMenuItem(value: 'delete', child: Text('Hapus profil')),
          ],
        ),
      ),
    );
  }
}

Future<void> _handleConnectionProfileAction({
  required BuildContext context,
  required String action,
  required ConnectionSettingsController controller,
  required ConnectionProviderDefinition provider,
  required ConnectionProfile profile,
}) async {
  if (action == 'default') {
    await controller.setDefaultProfile(profile.id);
  } else if (action == 'toggle') {
    await controller.toggleProfile(profile.id);
  } else if (action == 'delete') {
    final confirmed = await _confirmProfileDelete(context, profile);
    if (confirmed) await controller.deleteProfile(profile.id);
  } else if (action == 'edit' && context.mounted) {
    await profileDialog(context, controller, provider, profile);
  }
}

Future<bool> _confirmProfileDelete(
  BuildContext context,
  ConnectionProfile profile,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Hapus profil koneksi?'),
        content: Text(
          'Profil "${profile.displayName}" dihapus dari perangkat ini.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Hapus'),
          ),
        ],
      ),
    ) ??
    false;

String _connectionCapabilityLabel(ConnectionCapability capability) =>
    switch (capability) {
      ConnectionCapability.sessions => 'Session',
      ConnectionCapability.chat => 'Chat',
      ConnectionCapability.images => 'Gambar',
      ConnectionCapability.files => 'File',
      ConnectionCapability.approvals => 'Approval',
      ConnectionCapability.clarification => 'Klarifikasi',
      ConnectionCapability.toolStreaming => 'Aktivitas live',
      ConnectionCapability.stop => 'Stop task',
      ConnectionCapability.modelSelection => 'Pilihan model',
      ConnectionCapability.workspaceAccess => 'Akses workspace',
    };

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

Future<void> scanPairingQr(
  BuildContext context,
  AppController app,
  ConnectionSettingsController settings,
) async {
  final pairing = await Navigator.push<PairingData>(
    context,
    MaterialPageRoute(builder: (_) => const _PairingScannerPage()),
  );
  if (pairing == null || !context.mounted) return;
  try {
    await settings.selectProvider('remote_gateway');
    final existing = settings.profiles
        .where(
          (profile) =>
              profile.providerId == 'remote_gateway' &&
              profile.values['endpoint'] == pairing.endpoint,
        )
        .firstOrNull;
    final profileId =
        existing?.id ??
        await settings.addProfile(pairing.name, {
          'transportType': 'tailscaleServe',
          'endpoint': pairing.endpoint,
        });
    if (existing != null) {
      await settings.updateProfile(profileId, pairing.name, {
        ...existing.values,
        'transportType': 'tailscaleServe',
        'endpoint': pairing.endpoint,
      });
    }
    await settings.setDefaultProfile(profileId);
    await CredentialStore().save(
      profileId,
      GatewayCredentials('admin', pairing.token),
    );
    await app.connect(
      HermesRemoteConnector(Uri.parse(pairing.endpoint), pairing.token),
    );
    if (!app.isDemo) await app.loadWorkspaces(null);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(app.connectorError ?? '${pairing.name} tersambung'),
      ),
    );
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(connectionErrorMessage(error))));
    }
  }
}

class _PairingScannerPage extends StatefulWidget {
  const _PairingScannerPage();

  @override
  State<_PairingScannerPage> createState() => _PairingScannerPageState();
}

class _PairingScannerPageState extends State<_PairingScannerPage> {
  bool handled = false;

  void _handle(BarcodeCapture capture) {
    if (handled) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      final pairing = value == null ? null : PairingData.parse(value);
      if (pairing == null) continue;
      handled = true;
      Navigator.pop(context, pairing);
      return;
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Scan QR Agent Remote')),
    body: Stack(
      fit: StackFit.expand,
      children: [
        MobileScanner(onDetect: _handle),
        Align(
          alignment: Alignment.bottomCenter,
          child: SafeArea(
            child: Card(
              margin: const EdgeInsets.all(20),
              child: const Padding(
                padding: EdgeInsets.all(14),
                child: Text(
                  'Arahkan kamera ke QR pada PC. Jangan bagikan QR karena berisi token akses.',
                ),
              ),
            ),
          ),
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
