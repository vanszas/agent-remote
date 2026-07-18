import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_remote/agent_connector.dart';
import 'package:hermes_remote/app_controller.dart';
import 'package:hermes_remote/connection.dart';
import 'package:hermes_remote/hermes_remote_connector.dart';
import 'package:hermes_remote/local_store.dart';
import 'package:hermes_remote/main.dart' as app;
import 'package:hermes_remote/models.dart';

void main() {
  testWidgets('Material 3 demo shell renders', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          appBar: AppBar(title: const Text('Agent Remote')),
          body: const Text('Demo Mode'),
        ),
      ),
    );
    expect(find.text('Agent Remote'), findsOneWidget);
    expect(find.text('Demo Mode'), findsOneWidget);
  });

  testWidgets('task dashboard stays clear and filters on narrow screens', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = AppController(DemoAgentConnector(), LocalStore())
      ..tasks = [
        AgentTask(
          id: 'running',
          title: 'Upgrade UI aktif',
          status: 'running',
          mode: 'parallel',
          activeAgent: 'codex',
          agents: const ['codex', 'claude'],
          agentStates: const [
            AgentTaskAgentState(
              id: 'codex',
              name: 'Codex',
              status: 'running',
              phase: 'testing',
              detail: 'Menjalankan flutter test',
            ),
            AgentTaskAgentState(
              id: 'claude',
              name: 'Claude Code',
              status: 'queued',
              phase: 'preparing',
              detail: 'Menunggu eksekusi',
            ),
          ],
        ),
        const AgentTask(
          id: 'completed',
          title: 'Task lama selesai',
          status: 'completed',
          agents: ['codex'],
        ),
        const AgentTask(
          id: 'failed',
          title: 'Task perlu perhatian',
          status: 'failed',
          agents: ['gemini'],
        ),
      ];

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: app.TasksPage(controller))),
    );
    await tester.pump();

    expect(find.text('Aktivitas PC'), findsOneWidget);
    expect(find.text('Aktif (1)'), findsOneWidget);
    expect(find.text('Perhatian (1)'), findsOneWidget);
    expect(find.text('Codex'), findsOneWidget);
    expect(find.text('Claude Code'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(-520, 0),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Selesai (1)'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Task lama selesai'), findsOneWidget);
    expect(find.text('Upgrade UI aktif'), findsNothing);
    expect(find.text('Task perlu perhatian'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('chat shows descriptive progress for every running agent', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final now = DateTime(2026, 7, 18, 16);
    final controller = AppController(DemoAgentConnector(), LocalStore());
    controller.sessions.add(
      AgentSession(
        id: 'session-live',
        title: 'Upgrade session UI',
        createdAt: now,
        updatedAt: now,
        status: SessionStatus.generating,
        activeModelName: 'Codex + Claude Code',
      ),
    );
    controller.currentId = 'session-live';
    controller.tasks = const [
      AgentTask(
        id: 'run-live',
        sessionId: 'session-live',
        title: 'Upgrade session UI',
        status: 'running',
        mode: 'parallel',
        activeAgent: 'codex',
        agents: ['codex', 'claude'],
        agentStates: [
          AgentTaskAgentState(
            id: 'codex',
            name: 'Codex',
            status: 'running',
            phase: 'testing',
            detail: 'Menjalankan flutter test',
          ),
          AgentTaskAgentState(
            id: 'claude',
            name: 'Claude Code',
            status: 'queued',
            phase: 'preparing',
            detail: 'Menunggu eksekusi',
          ),
        ],
      ),
    ];

    await tester.pumpWidget(MaterialApp(home: app.ChatScreen(controller)));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('1/2 agent aktif • Parallel'), findsOneWidget);
    expect(find.text('Codex'), findsWidgets);
    expect(find.text('Claude Code'), findsOneWidget);
    expect(find.textContaining('Menjalankan flutter test'), findsWidgets);
    expect(find.text('Codex • Menjalankan verifikasi'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Lihat proses'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Proses task'), findsOneWidget);
    expect(find.text('2 agent • Parallel'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('chat composer blocks empty and duplicate sends narrowly', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final connector = _DelayedDemoConnector();
    final controller = AppController(connector, _MemoryLocalStore());
    final now = DateTime(2026, 7, 18, 20);
    controller.sessions.add(
      AgentSession(
        id: 'composer-session',
        title: 'Composer aman',
        createdAt: now,
        updatedAt: now,
        activeModelName: 'Codex',
      ),
    );
    controller.currentId = 'composer-session';

    await tester.pumpWidget(MaterialApp(home: app.ChatScreen(controller)));
    await tester.pump(const Duration(milliseconds: 200));

    final sendFinder = find.widgetWithIcon(
      IconButton,
      Icons.arrow_upward_rounded,
    );
    expect(sendFinder, findsOneWidget);
    expect(find.byTooltip('Kirim'), findsOneWidget);
    expect(tester.widget<IconButton>(sendFinder).onPressed, isNull);
    expect(find.text('Pesan kosong tidak akan dikirim'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.enterText(find.byType(TextField), 'Periksa status');
    await tester.pump();
    expect(tester.widget<IconButton>(sendFinder).onPressed, isNotNull);

    await tester.tap(sendFinder);
    await tester.tap(sendFinder);
    await tester.pump(const Duration(milliseconds: 200));

    expect(connector.sendCount, 1);
    expect(
      controller.current!.messages.where((m) => m.role == MessageRole.user),
      hasLength(1),
    );
    expect(find.byTooltip('Hentikan task'), findsOneWidget);
    expect(
      find.text('Task berjalan di PC • draft tetap tersimpan'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    connector.release.complete();
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('home collapses idle folders and highlights active work', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final now = DateTime(2026, 7, 18, 17);
    final idleSession = AgentSession(
      id: 'idle-session',
      title: 'Session idle tersembunyi',
      createdAt: now,
      updatedAt: now,
    );
    final runningSession = AgentSession(
      id: 'running-session',
      title: 'Session aktif terlihat',
      createdAt: now,
      updatedAt: now,
      status: SessionStatus.generating,
    );
    final controller = AppController(DemoAgentConnector(), LocalStore())
      ..workspacePath = r'C:\selected-elsewhere'
      ..projects = [
        AgentProject(
          workspace: const AgentWorkspace(
            id: 'idle',
            name: 'Project Idle',
            path: r'C:\idle',
          ),
          sessions: [idleSession],
        ),
        AgentProject(
          workspace: const AgentWorkspace(
            id: 'active',
            name: 'Project Aktif',
            path: r'C:\active',
          ),
          sessions: [runningSession],
        ),
      ]
      ..tasks = const [
        AgentTask(
          id: 'active-run',
          sessionId: 'running-session',
          title: 'Session aktif terlihat',
          status: 'running',
          activeAgent: 'codex',
          agents: ['codex'],
          agentStates: [
            AgentTaskAgentState(
              id: 'codex',
              name: 'Codex',
              status: 'running',
              phase: 'editing',
              detail: 'Mengubah tampilan home',
            ),
          ],
        ),
      ];

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: app.ChatsPage(controller))),
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Project & Session'), findsOneWidget);
    expect(find.text('1 task aktif • 1 agent berjalan'), findsWidgets);
    expect(find.text('Project Idle'), findsOneWidget);
    expect(find.text('Project Aktif'), findsOneWidget);
    expect(find.text('Session aktif terlihat'), findsOneWidget);
    expect(find.text('Session idle tersembunyi'), findsNothing);
    expect(
      find.textContaining('Codex: Mengubah tampilan home'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('session cards expose status metadata on narrow screens', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final createdAt = DateTime(2026, 7, 1, 9);
    final project = AgentProject(
      workspace: const AgentWorkspace(
        id: 'repo',
        name: 'Agent Remote',
        path: r'C:\repo',
      ),
      sessions: [
        AgentSession(
          id: 'failed-session',
          title: 'Push repository gagal',
          createdAt: createdAt,
          updatedAt: DateTime(2026, 7, 10, 12),
          isPinned: true,
          activeModelName: 'Codex',
          preview: 'Authentication ke remote ditolak.',
          messageCount: 12,
          status: SessionStatus.failed,
        ),
        AgentSession(
          id: 'approval-session',
          title: 'Menunggu izin command',
          createdAt: createdAt,
          updatedAt: DateTime(2026, 7, 9, 11),
          activeModelName: 'Claude Code',
          preview: 'Agent menunggu keputusan pengguna.',
          messageCount: 3,
          status: SessionStatus.waitingApproval,
        ),
        AgentSession(
          id: 'new-session',
          title: 'Session baru',
          createdAt: createdAt,
          updatedAt: DateTime(2026, 7, 8, 10),
          activeModelName: 'Codex',
        ),
      ],
    );
    final controller = AppController(DemoAgentConnector(), LocalStore())
      ..workspacePath = r'C:\repo';

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: app.ProjectSessionGroup(controller, project),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Push repository gagal'), findsOneWidget);
    expect(find.text('Gagal'), findsOneWidget);
    expect(find.text('Codex'), findsWidgets);
    expect(find.text('12 pesan'), findsOneWidget);
    expect(find.textContaining('10/07/2026'), findsOneWidget);
    expect(find.byTooltip('Session disematkan'), findsOneWidget);
    expect(find.text('Butuh approval'), findsOneWidget);
    expect(find.text('3 pesan'), findsOneWidget);
    expect(find.text('Baru'), findsOneWidget);
    expect(find.text('0 pesan'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('file dashboard summarizes and filters git changes narrowly', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = AppController(DemoAgentConnector(), LocalStore())
      ..workspacePath = r'C:\repo'
      ..gitRepository = const GitRepositoryStatus(
        isGitRepository: true,
        branch: 'main',
        upstream: 'origin/main',
        remoteUrl: 'https://github.com/vanszas/agent-remote.git',
        githubOwner: 'vanszas',
        githubRepository: 'agent-remote',
        additions: 81,
        deletions: 55,
        githubCliInstalled: true,
        githubCliAuthenticated: true,
        githubCliUser: 'vanszas',
        ahead: 2,
        behind: 1,
      )
      ..gitStatus = const [
        GitStatusEntry('lib/main.dart', GitFileStatus.modified),
        GitStatusEntry('lib/new_panel.dart', GitFileStatus.added),
        GitStatusEntry('lib/old_panel.dart', GitFileStatus.deleted),
        GitStatusEntry('notes.txt', GitFileStatus.untracked),
      ]
      ..workspaceEntries = const [
        WorkspaceEntry('README.md', 'README.md', false),
        WorkspaceEntry('lib', 'lib', true),
      ];

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: app.FilesPage(controller))),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('File & Git'), findsOneWidget);
    expect(find.text('vanszas/agent-remote'), findsOneWidget);
    expect(find.text('Changes'), findsOneWidget);
    expect(find.text('+81'), findsOneWidget);
    expect(find.text('-55'), findsOneWidget);
    expect(find.text('GitHub CLI: vanszas'), findsOneWidget);
    expect(find.text('Sources'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Perubahan kode'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Semua (4)'), findsOneWidget);
    expect(find.text('Diubah (1)'), findsOneWidget);
    expect(find.text('Ditambah (1)'), findsOneWidget);
    expect(find.text('lib/main.dart'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(-300, 0),
    );
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('Ditambah (1)'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('lib/new_panel.dart'), findsOneWidget);
    expect(find.text('lib/main.dart'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('usage dashboard filters real token flow on narrow screens', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final connector = _UsageDemoConnector();
    final controller = AppController(connector, LocalStore());

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: app.UsagePage(controller))),
    );
    await tester.pumpAndSettle();

    expect(find.text('Pemakaian Token'), findsOneWidget);
    expect(find.text('gpt-5.6-sol'), findsWidgets);
    expect(find.text('1.203'), findsOneWidget);
    expect(find.text('160.028.505'), findsOneWidget);
    expect(find.text('504.719'), findsOneWidget);
    expect(find.textContaining('Aktif sekarang'), findsOneWidget);
    expect(find.text('Sumber penggunaan'), findsOneWidget);
    expect(find.text('Semua PC'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Dari HP'));
    await tester.pumpAndSettle();
    expect(connector.lastScope, 'mobile');

    await tester.drag(
      find.byType(SingleChildScrollView).first,
      const Offset(-220, 0),
    );
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('7 hari'));
    await tester.pumpAndSettle();

    expect(connector.lastRange, '7d');
    expect(tester.takeException(), isNull);
  });

  testWidgets('workspace file editor previews and saves without agent prompt', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final connector = _FileEditorDemoConnector();
    final controller = AppController(connector, LocalStore())
      ..workspacePath = r'C:\repo'
      ..workspaceEntries = const [
        WorkspaceEntry('README.md', 'README.md', false),
      ];

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: app.FilesPage(controller))),
    );
    await tester.scrollUntilVisible(
      find.text('README.md'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('README.md'));
    await tester.pumpAndSettle();

    expect(find.text('Preview'), findsOneWidget);
    expect(find.text('Manual • 0 token'), findsOneWidget);
    expect(find.text('# Agent Remote'), findsOneWidget);

    await tester.tap(find.text('Edit'));
    await tester.pump();
    final editor = find.byType(TextField);
    expect(editor, findsOneWidget);
    await tester.enterText(editor, '# Agent Remote\nUpdated\n');
    await tester.pump();
    expect(find.text('Belum disimpan'), findsOneWidget);
    await tester.tap(find.byTooltip('Simpan ke PC'));
    await tester.pumpAndSettle();
    expect(find.text('Simpan ke PC?'), findsOneWidget);

    await tester.tap(find.text('Simpan'));
    await tester.pumpAndSettle();
    expect(connector.savedContent, '# Agent Remote\nUpdated\n');
    expect(find.text('Manual • 0 token'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('connection settings stay descriptive on narrow screens', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final catalog = ConnectionCatalog.parse('''
      {"schemaVersion":1,"providers":[{
        "id":"remote_gateway",
        "mode":"remoteGateway",
        "displayName":"Gateway agent PC",
        "description":"Kontrol agent CLI yang terdeteksi otomatis pada PC.",
        "iconKey":"remote",
        "sortOrder":10,
        "enabled":true,
        "integrationStatus":"available",
        "supportsProfiles":true,
        "supportsAuthentication":false,
        "capabilities":["sessions","chat","files","workspaceAccess"],
        "configurationFields":[]
      }]}
    ''');
    final now = DateTime(2026, 7, 18, 18);
    final connections =
        ConnectionSettingsController(catalog, ConnectionProfileStore())
          ..selectedProviderId = 'remote_gateway'
          ..profiles.add(
            ConnectionProfile(
              id: 'pc-home',
              providerId: 'remote_gateway',
              displayName: 'PC Rumah',
              values: const {
                'transportType': 'tailscaleServe',
                'endpoint': 'https://agent-pc.example.ts.net',
              },
              isDefault: true,
              createdAt: now,
              updatedAt: now,
            ),
          );
    final appController = AppController(DemoAgentConnector(), LocalStore());

    await tester.pumpWidget(
      MaterialApp(
        home: app.ConnectionSettingsScreen(connections, appController),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Koneksi Agent Remote'), findsOneWidget);
    expect(find.text('Gateway agent PC'), findsWidgets);
    expect(find.text('Siap digunakan'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('PC Rumah'), 280);
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('PC Rumah'), findsOneWidget);
    expect(find.text('Hubungkan ke PC'), findsOneWidget);
    expect(find.textContaining('deferred'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('security audit shows recent IP access without secrets', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final catalog = ConnectionCatalog.parse(
      '{"schemaVersion":1,"providers":[]}',
    );
    final connections = ConnectionSettingsController(
      catalog,
      ConnectionProfileStore(),
    );
    final controller = AppController(
      _SecurityDemoConnector(),
      _MemoryLocalStore(),
    );

    await tester.pumpWidget(
      MaterialApp(home: app.SettingsPage(controller, connections)),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.scrollUntilVisible(
      find.text('Keamanan API'),
      240,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Akses API terbaru'), findsOneWidget);
    expect(find.text('2 event • 1 ditolak'), findsOneWidget);
    expect(find.text('100.64.0.5'), findsOneWidget);
    expect(find.text('192.168.1.9'), findsOneWidget);
    expect(find.textContaining('Bearer'), findsNothing);
    expect(find.textContaining('admin'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('agent picker clamps single mode on narrow screens', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final remote =
        HermesRemoteConnector(Uri.parse('http://127.0.0.1:8899'), 'token')
          ..availableAgents = const [
            RemoteAgentInfo(
              id: 'codex',
              name: 'Codex',
              description: 'Agent coding utama',
              supportsStreaming: true,
              installed: true,
              command: 'codex.exe',
            ),
            RemoteAgentInfo(
              id: 'claude',
              name: 'Claude Code',
              description: 'Agent coding alternatif',
              supportsStreaming: true,
              installed: true,
              command: 'claude.exe',
            ),
            RemoteAgentInfo(
              id: 'gemini',
              name: 'Gemini CLI',
              description: 'Agent belum terpasang',
              supportsStreaming: false,
              installed: false,
              command: 'gemini',
            ),
          ]
          ..selectedAgentIds = {'codex', 'claude'}
          ..executionMode = RemoteExecutionMode.parallel
          ..coordinatorAgentId = 'claude';
    final controller = AppController(DemoAgentConnector(), LocalStore());

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () => app.showAgentSheet(context, controller, remote),
              child: const Text('Buka agent'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Buka agent'));
    await tester.pumpAndSettle();

    expect(find.text('Pilih agent PC'), findsOneWidget);
    expect(
      find.text('2 agent dipilih • Hanya CLI terpasang yang dapat dijalankan.'),
      findsOneWidget,
    );
    expect(
      find.text('Token bertambah sesuai jumlah agent yang dijalankan.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Satu agent'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(remote.executionMode, RemoteExecutionMode.single);
    expect(remote.selectedAgentIds, {'claude'});
    expect(find.text('Gunakan 1 agent'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('folder picker opens immediately and filters narrowly', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final remote = _FakeFolderConnector();
    final controller = AppController(DemoAgentConnector(), LocalStore())
      ..workspacePath = r'C:\Work';

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () => app.showFolderSheet(context, controller, remote),
              child: const Text('Buka folder'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Buka folder'));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Pilih folder PC'), findsOneWidget);
    expect(find.text('Memuat folder PC...'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text(r'C:\Work'), findsWidgets);
    expect(find.text('Folder aktif terakhir'), findsOneWidget);
    expect(find.text('Apps'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Docs'),
      120,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('Docs'), findsOneWidget);

    await tester.enterText(find.byType(SearchBar), 'apps');
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Apps'), findsOneWidget);
    expect(find.text('Docs'), findsNothing);

    await tester.tap(find.text('Apps'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text(r'C:\Work\Apps'), findsWidgets);
    expect(find.text('Tidak ada subfolder'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tool activity cards show real progress on narrow screens', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final now = DateTime(2026, 7, 18, 19);
    final controller = AppController(DemoAgentConnector(), LocalStore());
    final message = ChatMessage(
      id: 'tool-message',
      sessionId: 'session',
      role: MessageRole.assistant,
      content: 'Sedang memverifikasi perubahan.',
      createdAt: now,
      updatedAt: now,
      status: MessageStatus.streaming,
      toolActivities: [
        ToolActivity(
          id: 'running-tool',
          toolName: 'shell_command',
          displayName: 'Flutter test',
          summary: 'Menjalankan flutter test',
          status: ToolActivityStatus.running,
          startedAt: now,
          progress: .45,
        ),
        ToolActivity(
          id: 'completed-tool',
          toolName: 'test_result',
          displayName: 'Verifikasi akhir',
          summary: 'Test selesai tanpa error',
          status: ToolActivityStatus.success,
          startedAt: now.subtract(const Duration(seconds: 8)),
          completedAt: now,
          outputPreview: 'All tests passed',
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: app.MessageCard(message, controller),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Berjalan'), findsWidgets);
    expect(find.text('45%'), findsOneWidget);
    expect(find.text('Output belum tersedia.'), findsOneWidget);
    expect(find.text('Selesai'), findsOneWidget);
    expect(
      find.textContaining('Simulation; no terminal command runs.'),
      findsNothing,
    );
    expect(find.text('All tests passed'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Verifikasi akhir'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('All tests passed'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'message cards show provenance and copy safely on narrow screens',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      String? copiedText;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copiedText = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final now = DateTime(2026, 7, 18, 20, 30);
      final controller = AppController(DemoAgentConnector(), LocalStore());
      controller.sessions.add(
        AgentSession(
          id: 'message-session',
          title: 'UI message',
          createdAt: now,
          updatedAt: now,
          activeModelName: 'Codex + Claude Code',
        ),
      );
      controller.currentId = 'message-session';
      final message = ChatMessage(
        id: 'assistant-message',
        sessionId: 'message-session',
        role: MessageRole.assistant,
        content: 'Perubahan berhasil diverifikasi.',
        createdAt: now,
        updatedAt: now,
        status: MessageStatus.complete,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: app.MessageCard(message, controller),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('Codex + Claude Code'), findsOneWidget);
      expect(find.text('Selesai'), findsOneWidget);
      expect(find.byTooltip('Salin pesan'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byTooltip('Salin pesan'));
      await tester.pump(const Duration(milliseconds: 100));

      expect(copiedText, 'Perubahan berhasil diverifikasi.');
      expect(find.text('Pesan disalin.'), findsOneWidget);
      expect(tester.takeException(), isNull);

      final streaming = ChatMessage(
        id: 'streaming-message',
        sessionId: 'message-session',
        role: MessageRole.assistant,
        content: '',
        createdAt: now,
        updatedAt: now,
        status: MessageStatus.streaming,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: app.MessageCard(streaming, controller)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('Menunggu respons agent...'), findsOneWidget);
      expect(find.textContaining('Thinking'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('chat preserves reading position and marks new messages', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final now = DateTime(2026, 7, 18, 21);
    final controller = AppController(DemoAgentConnector(), LocalStore());
    final initialMessages = List.generate(
      24,
      (index) => ChatMessage(
        id: 'message-$index',
        sessionId: 'scroll-session',
        role: index.isEven ? MessageRole.user : MessageRole.assistant,
        content: 'Pesan panjang $index ${'isi ' * 12}',
        createdAt: now.add(Duration(minutes: index)),
        updatedAt: now.add(Duration(minutes: index)),
        status: MessageStatus.complete,
      ),
    );
    controller.sessions.add(
      AgentSession(
        id: 'scroll-session',
        title: 'Scroll chat',
        createdAt: now,
        updatedAt: now,
        messages: initialMessages,
      ),
    );
    controller.currentId = 'scroll-session';

    await tester.pumpWidget(
      MaterialApp(
        home: ListenableBuilder(
          listenable: controller,
          builder: (_, _) => app.ChatScreen(controller),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final messageList = find.byKey(const ValueKey('chat-message-list'));
    final position = tester.widget<ListView>(messageList).controller!.position;
    position.jumpTo(300);
    await tester.pump();

    expect(find.text('Ke pesan terbaru'), findsOneWidget);

    final newMessages = List.generate(
      2,
      (index) => ChatMessage(
        id: 'message-new-$index',
        sessionId: 'scroll-session',
        role: MessageRole.assistant,
        content: 'Pesan baru ${index + 1} dari agent.',
        createdAt: now.add(Duration(hours: 1, seconds: index)),
        updatedAt: now.add(Duration(hours: 1, seconds: index)),
        status: MessageStatus.complete,
      ),
    );
    controller.sessions[0] = controller.sessions[0].copyWith(
      messages: [...initialMessages, ...newMessages],
      updatedAt: newMessages.last.updatedAt,
    );
    controller.refresh();
    await tester.pump();
    await tester.pump();

    expect(find.text('2 pesan baru'), findsOneWidget);
    expect(position.pixels, greaterThan(120));

    await tester.tap(find.byKey(const ValueKey('chat-latest-button')));
    await tester.pumpAndSettle();

    expect(position.pixels, closeTo(0, 0.1));
    expect(find.byKey(const ValueKey('chat-latest-button')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('approval and clarification stay safe on narrow screens', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final now = DateTime(2026, 7, 18, 19);
    final controller = AppController(DemoAgentConnector(), LocalStore());
    final approvalMessage = ChatMessage(
      id: 'approval-message',
      sessionId: 'session',
      role: MessageRole.assistant,
      content: '',
      createdAt: now,
      updatedAt: now,
      status: MessageStatus.complete,
      approvalRequest: ApprovalRequest(
        id: 'approval',
        sessionId: 'session',
        correlationId: 'run',
        title: 'Push perubahan ke GitHub',
        description: 'Agent akan mengirim commit lokal ke remote.',
        riskLevel: ApprovalRiskLevel.critical,
        commandPreview: 'git push origin main',
        createdAt: now,
        expiresAt: now.add(const Duration(hours: 1)),
        status: ApprovalStatus.pending,
        isDemo: false,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: app.MessageCard(approvalMessage, controller)),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Risiko kritis'), findsOneWidget);
    expect(find.text('Menunggu keputusan'), findsOneWidget);
    expect(find.text('git push origin main'), findsOneWidget);
    expect(find.textContaining('Demo only'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Setujui sekali'));
    await tester.pumpAndSettle();
    expect(find.text('Setujui aksi berisiko tinggi?'), findsOneWidget);
    await tester.tap(find.text('Batal'));
    await tester.pumpAndSettle();

    final clarificationMessage = ChatMessage(
      id: 'clarification-message',
      sessionId: 'session',
      role: MessageRole.assistant,
      content: '',
      createdAt: now,
      updatedAt: now,
      status: MessageStatus.complete,
      clarificationRequest: ClarificationRequest(
        id: 'clarification',
        sessionId: 'session',
        correlationId: 'run',
        question: 'Strategi mana yang dipakai?',
        choices: const ['Cepat', 'Aman'],
        allowFreeText: true,
        createdAt: now,
        status: ClarificationStatus.pending,
        isDemo: false,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: app.MessageCard(clarificationMessage, controller)),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Menunggu jawaban'), findsOneWidget);
    expect(find.text('Cepat'), findsOneWidget);
    expect(find.text('Aman'), findsOneWidget);
    expect(find.text('Jawaban lain'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Gunakan strategi aman');
    expect(find.text('Gunakan strategi aman'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _FakeFolderConnector extends HermesRemoteConnector {
  _FakeFolderConnector() : super(Uri.parse('http://127.0.0.1:8899'), 'token');

  @override
  Future<PcFolderListing> browsePcFolders([String path = '']) async {
    await Future<void>.delayed(const Duration(milliseconds: 120));
    if (path == r'C:\Work\Apps') {
      return const PcFolderListing(
        path: r'C:\Work\Apps',
        parent: r'C:\Work',
        folders: [],
      );
    }
    if (path.isEmpty) {
      return const PcFolderListing(
        path: '',
        parent: null,
        folders: [
          AgentWorkspace(id: 'c', name: 'C:', path: r'C:\'),
          AgentWorkspace(id: 'd', name: 'D:', path: r'D:\'),
        ],
      );
    }
    return const PcFolderListing(
      path: r'C:\Work',
      parent: r'C:\',
      folders: [
        AgentWorkspace(id: 'apps', name: 'Apps', path: r'C:\Work\Apps'),
        AgentWorkspace(id: 'docs', name: 'Docs', path: r'C:\Work\Docs'),
      ],
    );
  }
}

class _DelayedDemoConnector extends DemoAgentConnector {
  final release = Completer<void>();
  int sendCount = 0;

  @override
  Future<void> sendPrompt({
    required String sessionId,
    required String text,
    required List<AgentAttachment> attachments,
  }) {
    sendCount += 1;
    return release.future;
  }
}

class _MemoryLocalStore extends LocalStore {
  @override
  Future<void> save(List<AgentSession> sessions) async {}
}

class _SecurityDemoConnector extends DemoAgentConnector
    implements SecurityMonitor {
  @override
  Future<SecurityAuditSnapshot> getSecurityAudit({int limit = 50}) async =>
      SecurityAuditSnapshot(
        peerIpOnly: true,
        successWindowSeconds: 900,
        failureWindowSeconds: 10,
        entries: [
          SecurityAuditEntry(
            timestamp: DateTime.utc(2026, 7, 18, 13),
            event: 'access_granted',
            ipAddress: '100.64.0.5',
            method: 'GET',
            path: '/api/status',
            userAgent: 'AgentRemote/0.3.0',
          ),
          SecurityAuditEntry(
            timestamp: DateTime.utc(2026, 7, 18, 12, 59),
            event: 'access_denied',
            ipAddress: '192.168.1.9',
            method: 'POST',
            path: '/api/sessions',
            userAgent: 'unknown-client',
          ),
        ],
      );
}

class _UsageDemoConnector extends DemoAgentConnector
    implements ProviderUsageMonitor {
  String lastRange = '';
  String lastScope = '';

  @override
  Future<ProviderUsageSnapshot> getProviderUsage({
    String range = '24h',
    String provider = '',
    String model = '',
    String scope = 'all',
    int limit = 50,
  }) async {
    lastRange = range;
    lastScope = scope;
    final now = DateTime(2026, 7, 18, 20);
    final active = ProviderUsageEntry(
      timestamp: now,
      provider: 'codex',
      model: 'gpt-5.6-sol',
      endpoint: '/v1/responses',
      inputTokens: 110028,
      outputTokens: 375,
      cachedTokens: 100000,
      cost: .42,
      status: 'ok',
      isActive: true,
    );
    return ProviderUsageSnapshot(
      available: true,
      source: '9router',
      range: range,
      summary: const ProviderUsageSummary(
        requests: 1203,
        inputTokens: 160028505,
        outputTokens: 504719,
        cachedTokens: 154387584,
        estimatedCost: 124.19,
      ),
      active: active,
      providers: const ['codex'],
      models: const ['gpt-5.6-sol'],
      recent: [active],
      attribution: 'all_9router_requests_on_pc',
      scope: scope,
      mobileFilterAvailable: true,
      mobileKeyName: 'Agent Remote Mobile',
      updatedAt: now,
    );
  }
}

class _FileEditorDemoConnector extends DemoAgentConnector
    implements WorkspaceFileEditor {
  String savedContent = '';

  WorkspaceFileDocument document({String content = '# Agent Remote\n'}) =>
      WorkspaceFileDocument(
        path: 'README.md',
        name: 'README.md',
        content: content,
        diff: '+# Agent Remote',
        hash: content.hashCode.toString(),
        size: content.length,
        lineCount: content.split('\n').length,
        exists: true,
        editable: true,
        gitStatus: 'modified',
        maxBytes: 524288,
      );

  @override
  Future<WorkspaceFileDocument> getWorkspaceFile(String path) async =>
      document();

  @override
  Future<WorkspaceFileDocument> saveWorkspaceFile({
    required String path,
    required String content,
    required String baseHash,
  }) async {
    savedContent = content;
    return document(content: content);
  }
}
