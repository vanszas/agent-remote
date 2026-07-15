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
import 'credential_store.dart';
import 'hermes_gateway_connector.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
  final credentials = profile == null
      ? null
      : await CredentialStore().load(profile.id);
  if (profile != null &&
      endpoint != null &&
      endpoint.isNotEmpty &&
      credentials != null) {
    await c.connect(
      HermesGatewayConnector(
        HermesGatewayConfig(
          baseUrl: Uri.parse(endpoint),
          provider: 'basic',
          username: credentials.username,
          password: credentials.password,
        ),
      ),
    );
    if (!c.isDemo) {
      await c.loadWorkspaces(profile.values['workspacePath'] as String?);
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
      title: 'Hermes Remote',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.deepPurple, useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.deepPurple,
        brightness: Brightness.dark,
        useMaterial3: true,
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

class AppShell extends StatelessWidget {
  const AppShell(this.c, this.connections, {super.key});
  final AppController c;
  final ConnectionSettingsController connections;
  @override
  Widget build(BuildContext context) {
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
        title: const Text('Hermes Remote'),
        actions: [
          Chip(label: Text(c.connectorLabel)),
          IconButton(
            tooltip: 'New chat',
            onPressed: c.newSession,
            icon: const Icon(Icons.add_comment),
          ),
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
  (Icons.chat_bubble_outline, 'Chats'),
  (Icons.task_alt, 'Tasks'),
  (Icons.folder_outlined, 'Files'),
  (Icons.settings_outlined, 'Settings'),
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
          c.isDemo
              ? 'Full local demo. No backend connection.'
              : 'Connected to Hermes gateway.',
        ),
        if (!c.isDemo && c.workspaces.isNotEmpty)
          DropdownButtonFormField<String>(
            initialValue: c.workspacePath,
            decoration: const InputDecoration(labelText: 'Workspace PC'),
            items: c.workspaces
                .map(
                  (w) => DropdownMenuItem(value: w.path, child: Text(w.name)),
                )
                .toList(),
            onChanged: (path) => path == null ? null : c.selectWorkspace(path),
          ),
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
            onRefresh: c.reloadSessions,
            child: c.filtered.isEmpty
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
                    children: [
                      ...c.filtered
                          .where((s) => s.isPinned)
                          .map((s) => SessionTile(c, s)),
                      ...c.filtered
                          .where((s) => !s.isPinned)
                          .map((s) => SessionTile(c, s)),
                      if (c.filtered.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: Center(
                            child: OutlinedButton(
                              onPressed: c.loadMore,
                              child: const Text('Load More History'),
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
        ),
      ],
    ),
  );
}

class SessionTile extends StatelessWidget {
  const SessionTile(this.c, this.s, {super.key});
  final AppController c;
  final AgentSession s;
  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      onTap: () => c.open(s),
      leading: Icon(s.isPinned ? Icons.push_pin : Icons.chat_outlined),
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
  final scroll = ScrollController();
  final pending = <AgentAttachment>[];
  bool didInitialScroll = false;

  @override
  void dispose() {
    text.dispose();
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c, s = c.current!;
    if (!c.loadingSession && !didInitialScroll) {
      didInitialScroll = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (scroll.hasClients) scroll.jumpTo(scroll.position.maxScrollExtent);
      });
    }
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(
          onPressed: () {
            c.currentId = null;
            c.refresh();
          },
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(s.title),
            Text(
              c.isDemo ? 'Demo Mode • local only' : 'Hermes gateway',
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: c.loadingSession
                  ? const Center(child: CircularProgressIndicator())
                  : ListView.builder(
                      controller: scroll,
                      padding: const EdgeInsets.all(12),
                      itemCount: s.messages.length,
                      itemBuilder: (_, i) => MessageCard(s.messages[i], c),
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
            Padding(
              padding: const EdgeInsets.all(8),
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
                      decoration: InputDecoration(
                        hintText: c.isDemo
                            ? 'Message Demo Agent'
                            : 'Message Hermes',
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
          Text('Tasks', style: Theme.of(context).textTheme.headlineSmall),
          if (c.tasks.isEmpty)
            const ListTile(
              leading: Icon(Icons.task_alt),
              title: Text('No active tasks'),
            ),
          ...c.tasks.map(
            (task) => ListTile(
              leading: const CircularProgressIndicator(),
              title: Text(task.title),
              subtitle: Text(task.status),
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
    final files = c.sessions
        .expand(
          (s) => s.messages.expand((m) => m.attachments).map((a) => (s, a)),
        )
        .toList();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Files', style: Theme.of(context).textTheme.headlineSmall),
        if (files.isEmpty)
          const ListTile(
            leading: Icon(Icons.folder_open),
            title: Text('No local attachments'),
          ),
        ...files.map(
          (x) => ListTile(
            onTap: () => c.open(x.$1),
            leading: const Icon(Icons.insert_drive_file),
            title: Text(x.$2.originalName),
            subtitle: Text(x.$1.title),
          ),
        ),
      ],
    );
  }
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
        subtitle: Text(
          'Hermes Remote 0.2.0\ncom.monokotil.hermesremote\nDemo Mode',
        ),
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
    appBar: AppBar(title: const Text('Gateway Connection')),
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
                    HermesGatewayConnector(
                      HermesGatewayConfig(
                        baseUrl: Uri.parse(endpoint),
                        provider: 'basic',
                        username: username.text.trim(),
                        password: password.text,
                      ),
                    ),
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
