class ClipboardItem {
  const ClipboardItem({
    required this.id,
    required this.content,
    required this.contentHash,
    required this.createdAt,
    required this.updatedAt,
    required this.lastUsedAt,
    required this.copyCount,
    required this.favorite,
    required this.deleted,
    required this.deviceId,
    required this.syncState,
    this.sourceApp,
    this.type = 'text',
  });

  final String id;
  final String type;
  final String content;
  final String contentHash;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime lastUsedAt;
  final int copyCount;
  final bool favorite;
  final bool deleted;
  final String deviceId;
  final String syncState;
  final String? sourceApp;

  factory ClipboardItem.fromMap(Map<String, Object?> map) => ClipboardItem(
    id: map['id']! as String,
    type: map['type']! as String,
    content: map['content']! as String,
    contentHash: map['content_hash']! as String,
    createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at']! as int),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(map['updated_at']! as int),
    lastUsedAt: DateTime.fromMillisecondsSinceEpoch(
      map['last_used_at']! as int,
    ),
    copyCount: map['copy_count']! as int,
    favorite: (map['favorite']! as int) == 1,
    deleted: (map['deleted']! as int) == 1,
    deviceId: map['device_id']! as String,
    syncState: map['sync_state']! as String,
    sourceApp: map['source_app'] as String?,
  );
}
