enum SessionStatus {
  idle,
  generating,
  waitingApproval,
  waitingClarification,
  stopped,
  failed,
}

enum MessageRole { user, assistant, system }

enum MessageStatus { queued, streaming, complete, stopped, failed }

enum AttachmentKind { image, document, archive, text, unknown }

enum ToolActivityStatus { pending, running, success, failed, cancelled }

enum ApprovalStatus { pending, approved, denied, expired, cancelled }

enum ApprovalRiskLevel { low, medium, high, critical, unknown }

enum ApprovalDecision { approve, deny }

enum ClarificationStatus { pending, answered, cancelled, expired }

T _enum<T extends Enum>(List<T> values, Object? value, T fallback) =>
    values.where((e) => e.name == value).firstOrNull ?? fallback;

class ApprovalRequest {
  const ApprovalRequest({
    required this.id,
    required this.sessionId,
    required this.correlationId,
    required this.title,
    required this.description,
    required this.riskLevel,
    this.commandPreview,
    required this.createdAt,
    this.expiresAt,
    required this.status,
    required this.isDemo,
  });
  final String id, sessionId, correlationId, title, description;
  final ApprovalRiskLevel riskLevel;
  final String? commandPreview;
  final DateTime createdAt;
  final DateTime? expiresAt;
  final ApprovalStatus status;
  final bool isDemo;
  ApprovalRequest copyWith({ApprovalStatus? status}) => ApprovalRequest(
    id: id,
    sessionId: sessionId,
    correlationId: correlationId,
    title: title,
    description: description,
    riskLevel: riskLevel,
    commandPreview: commandPreview,
    createdAt: createdAt,
    expiresAt: expiresAt,
    status: status ?? this.status,
    isDemo: isDemo,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'sessionId': sessionId,
    'correlationId': correlationId,
    'title': title,
    'description': description,
    'riskLevel': riskLevel.name,
    'commandPreview': commandPreview,
    'createdAt': createdAt.toIso8601String(),
    'expiresAt': expiresAt?.toIso8601String(),
    'status': status.name,
    'isDemo': isDemo,
  };
  factory ApprovalRequest.fromJson(Map<String, Object?> j) => ApprovalRequest(
    id: j['id'] as String? ?? '',
    sessionId: j['sessionId'] as String? ?? '',
    correlationId: j['correlationId'] as String? ?? '',
    title: j['title'] as String? ?? '',
    description: j['description'] as String? ?? '',
    riskLevel: _enum(
      ApprovalRiskLevel.values,
      j['riskLevel'],
      ApprovalRiskLevel.unknown,
    ),
    commandPreview: j['commandPreview'] as String?,
    createdAt:
        DateTime.tryParse(j['createdAt'] as String? ?? '') ?? DateTime.now(),
    expiresAt: DateTime.tryParse(j['expiresAt'] as String? ?? ''),
    status: _enum(ApprovalStatus.values, j['status'], ApprovalStatus.pending),
    isDemo: j['isDemo'] as bool? ?? false,
  );
}

class ClarificationRequest {
  const ClarificationRequest({
    required this.id,
    required this.sessionId,
    required this.correlationId,
    required this.question,
    required this.choices,
    required this.allowFreeText,
    required this.createdAt,
    required this.status,
    this.selectedAnswer,
    required this.isDemo,
  });
  final String id, sessionId, correlationId, question;
  final List<String> choices;
  final bool allowFreeText, isDemo;
  final DateTime createdAt;
  final ClarificationStatus status;
  final String? selectedAnswer;
  ClarificationRequest copyWith({
    ClarificationStatus? status,
    String? selectedAnswer,
  }) => ClarificationRequest(
    id: id,
    sessionId: sessionId,
    correlationId: correlationId,
    question: question,
    choices: choices,
    allowFreeText: allowFreeText,
    createdAt: createdAt,
    status: status ?? this.status,
    selectedAnswer: selectedAnswer ?? this.selectedAnswer,
    isDemo: isDemo,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'sessionId': sessionId,
    'correlationId': correlationId,
    'question': question,
    'choices': choices,
    'allowFreeText': allowFreeText,
    'createdAt': createdAt.toIso8601String(),
    'status': status.name,
    'selectedAnswer': selectedAnswer,
    'isDemo': isDemo,
  };
  factory ClarificationRequest.fromJson(Map<String, Object?> j) =>
      ClarificationRequest(
        id: j['id'] as String? ?? '',
        sessionId: j['sessionId'] as String? ?? '',
        correlationId: j['correlationId'] as String? ?? '',
        question: j['question'] as String? ?? '',
        choices: (j['choices'] as List? ?? []).whereType<String>().toList(),
        allowFreeText: j['allowFreeText'] as bool? ?? false,
        createdAt:
            DateTime.tryParse(j['createdAt'] as String? ?? '') ??
            DateTime.now(),
        status: _enum(
          ClarificationStatus.values,
          j['status'],
          ClarificationStatus.pending,
        ),
        selectedAnswer: j['selectedAnswer'] as String?,
        isDemo: j['isDemo'] as bool? ?? false,
      );
}

class AgentAttachment {
  const AgentAttachment({
    required this.id,
    required this.originalName,
    required this.localPath,
    required this.mimeType,
    required this.sizeBytes,
    required this.kind,
    this.thumbnailPath,
    required this.createdAt,
  });
  final String id, originalName, localPath, mimeType;
  final int sizeBytes;
  final AttachmentKind kind;
  final String? thumbnailPath;
  final DateTime createdAt;
  Map<String, Object?> toJson() => {
    'id': id,
    'originalName': originalName,
    'localPath': localPath,
    'mimeType': mimeType,
    'sizeBytes': sizeBytes,
    'kind': kind.name,
    'thumbnailPath': thumbnailPath,
    'createdAt': createdAt.toIso8601String(),
  };
  factory AgentAttachment.fromJson(Map<String, Object?> j) => AgentAttachment(
    id: j['id'] as String? ?? '',
    originalName: j['originalName'] as String? ?? '',
    localPath: j['localPath'] as String? ?? '',
    mimeType: j['mimeType'] as String? ?? 'application/octet-stream',
    sizeBytes: j['sizeBytes'] as int? ?? 0,
    kind: _enum(AttachmentKind.values, j['kind'], AttachmentKind.unknown),
    thumbnailPath: j['thumbnailPath'] as String?,
    createdAt:
        DateTime.tryParse(j['createdAt'] as String? ?? '') ?? DateTime.now(),
  );
}

class ToolActivity {
  const ToolActivity({
    required this.id,
    required this.toolName,
    required this.displayName,
    required this.summary,
    required this.status,
    required this.startedAt,
    this.completedAt,
    this.progress,
    this.outputPreview,
    this.error,
  });
  final String id, toolName, displayName, summary;
  final ToolActivityStatus status;
  final DateTime startedAt;
  final DateTime? completedAt;
  final double? progress;
  final String? outputPreview, error;
  Map<String, Object?> toJson() => {
    'id': id,
    'toolName': toolName,
    'displayName': displayName,
    'summary': summary,
    'status': status.name,
    'startedAt': startedAt.toIso8601String(),
    'completedAt': completedAt?.toIso8601String(),
    'progress': progress,
    'outputPreview': outputPreview,
    'error': error,
  };
  factory ToolActivity.fromJson(Map<String, Object?> j) => ToolActivity(
    id: j['id'] as String? ?? '',
    toolName: j['toolName'] as String? ?? '',
    displayName: j['displayName'] as String? ?? '',
    summary: j['summary'] as String? ?? '',
    status: _enum(
      ToolActivityStatus.values,
      j['status'],
      ToolActivityStatus.failed,
    ),
    startedAt:
        DateTime.tryParse(j['startedAt'] as String? ?? '') ?? DateTime.now(),
    completedAt: DateTime.tryParse(j['completedAt'] as String? ?? ''),
    progress: (j['progress'] as num?)?.toDouble(),
    outputPreview: j['outputPreview'] as String?,
    error: j['error'] as String?,
  );
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.sessionId,
    required this.role,
    required this.content,
    required this.createdAt,
    required this.updatedAt,
    required this.status,
    this.attachments = const [],
    this.toolActivities = const [],
    this.errorMessage,
    this.approvalRequest,
    this.clarificationRequest,
  });
  final String id, sessionId, content;
  final MessageRole role;
  final DateTime createdAt, updatedAt;
  final MessageStatus status;
  final List<AgentAttachment> attachments;
  final List<ToolActivity> toolActivities;
  final String? errorMessage;
  final ApprovalRequest? approvalRequest;
  final ClarificationRequest? clarificationRequest;
  ChatMessage copyWith({
    String? content,
    MessageStatus? status,
    List<ToolActivity>? toolActivities,
    String? errorMessage,
    ApprovalRequest? approvalRequest,
    ClarificationRequest? clarificationRequest,
  }) => ChatMessage(
    id: id,
    sessionId: sessionId,
    role: role,
    content: content ?? this.content,
    createdAt: createdAt,
    updatedAt: DateTime.now(),
    status: status ?? this.status,
    attachments: attachments,
    toolActivities: toolActivities ?? this.toolActivities,
    errorMessage: errorMessage ?? this.errorMessage,
    approvalRequest: approvalRequest ?? this.approvalRequest,
    clarificationRequest: clarificationRequest ?? this.clarificationRequest,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'sessionId': sessionId,
    'role': role.name,
    'content': content,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'status': status.name,
    'attachments': attachments.map((e) => e.toJson()).toList(),
    'toolActivities': toolActivities.map((e) => e.toJson()).toList(),
    'errorMessage': errorMessage,
    'approvalRequest': approvalRequest?.toJson(),
    'clarificationRequest': clarificationRequest?.toJson(),
  };
  factory ChatMessage.fromJson(Map<String, Object?> j) => ChatMessage(
    id: j['id'] as String? ?? '',
    sessionId: j['sessionId'] as String? ?? '',
    role: _enum(MessageRole.values, j['role'], MessageRole.system),
    content: j['content'] as String? ?? '',
    createdAt:
        DateTime.tryParse(j['createdAt'] as String? ?? '') ?? DateTime.now(),
    updatedAt:
        DateTime.tryParse(j['updatedAt'] as String? ?? '') ?? DateTime.now(),
    status: _enum(MessageStatus.values, j['status'], MessageStatus.failed),
    attachments: (j['attachments'] as List? ?? [])
        .whereType<Map>()
        .map((e) => AgentAttachment.fromJson(Map<String, Object?>.from(e)))
        .toList(),
    toolActivities: (j['toolActivities'] as List? ?? [])
        .whereType<Map>()
        .map((e) => ToolActivity.fromJson(Map<String, Object?>.from(e)))
        .toList(),
    errorMessage: j['errorMessage'] as String?,
    approvalRequest: j['approvalRequest'] is Map
        ? ApprovalRequest.fromJson(
            Map<String, Object?>.from(j['approvalRequest'] as Map),
          )
        : null,
    clarificationRequest: j['clarificationRequest'] is Map
        ? ClarificationRequest.fromJson(
            Map<String, Object?>.from(j['clarificationRequest'] as Map),
          )
        : null,
  );
}

class AgentSession {
  const AgentSession({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.isPinned = false,
    this.isArchived = false,
    this.workspaceName = 'Demo workspace',
    this.connectionProfileId,
    this.activeModelName = 'Demo Agent',
    this.messages = const [],
    this.draftText = '',
    this.status = SessionStatus.idle,
  });
  final String id, title, workspaceName, draftText;
  final DateTime createdAt, updatedAt;
  final bool isPinned, isArchived;
  final String? connectionProfileId, activeModelName;
  final List<ChatMessage> messages;
  final SessionStatus status;
  AgentSession copyWith({
    String? title,
    DateTime? updatedAt,
    bool? isPinned,
    List<ChatMessage>? messages,
    String? draftText,
    SessionStatus? status,
  }) => AgentSession(
    id: id,
    title: title ?? this.title,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    isPinned: isPinned ?? this.isPinned,
    isArchived: isArchived,
    workspaceName: workspaceName,
    connectionProfileId: connectionProfileId,
    activeModelName: activeModelName,
    messages: messages ?? this.messages,
    draftText: draftText ?? this.draftText,
    status: status ?? this.status,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'isPinned': isPinned,
    'isArchived': isArchived,
    'workspaceName': workspaceName,
    'connectionProfileId': connectionProfileId,
    'activeModelName': activeModelName,
    'messages': messages.map((e) => e.toJson()).toList(),
    'draftText': draftText,
    'status': status.name,
  };
  factory AgentSession.fromJson(Map<String, Object?> j) => AgentSession(
    id: j['id'] as String? ?? '',
    title: j['title'] as String? ?? 'Untitled',
    createdAt:
        DateTime.tryParse(j['createdAt'] as String? ?? '') ?? DateTime.now(),
    updatedAt:
        DateTime.tryParse(j['updatedAt'] as String? ?? '') ?? DateTime.now(),
    isPinned: j['isPinned'] as bool? ?? false,
    isArchived: j['isArchived'] as bool? ?? false,
    workspaceName: j['workspaceName'] as String? ?? '',
    connectionProfileId: j['connectionProfileId'] as String?,
    activeModelName: j['activeModelName'] as String?,
    messages: (j['messages'] as List? ?? [])
        .whereType<Map>()
        .map((e) => ChatMessage.fromJson(Map<String, Object?>.from(e)))
        .toList(),
    draftText: j['draftText'] as String? ?? '',
    status: _enum(SessionStatus.values, j['status'], SessionStatus.idle),
  );
}

String sanitizeFilename(String value) {
  final name = value
      .replaceAll('\\', '/')
      .split('/')
      .last
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
      .trim();
  return name.isEmpty ? 'attachment' : name;
}

String? validateAttachmentSize(int bytes) =>
    bytes > 15 * 1024 * 1024 ? 'File exceeds 15 MB limit.' : null;
String mimeForFilename(String name) =>
    switch (name.split('.').last.toLowerCase()) {
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'webp' => 'image/webp',
      'gif' => 'image/gif',
      'txt' || 'log' => 'text/plain',
      'md' => 'text/markdown',
      'json' => 'application/json',
      'csv' => 'text/csv',
      'pdf' => 'application/pdf',
      'xml' => 'application/xml',
      'yaml' || 'yml' => 'application/yaml',
      'zip' => 'application/zip',
      'dart' ||
      'kt' ||
      'java' ||
      'cpp' ||
      'h' ||
      'py' ||
      'js' ||
      'ts' => 'text/plain',
      _ => 'application/octet-stream',
    };
const appSchemaVersion = 1;
