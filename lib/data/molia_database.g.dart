// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'molia_database.dart';

// ignore_for_file: type=lint
class $PlayContextsTable extends PlayContexts
    with TableInfo<$PlayContextsTable, PlayContext> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PlayContextsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _contextUriMeta =
      const VerificationMeta('contextUri');
  @override
  late final GeneratedColumn<String> contextUri = GeneratedColumn<String>(
      'contextUri', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _contextTypeMeta =
      const VerificationMeta('contextType');
  @override
  late final GeneratedColumn<String> contextType = GeneratedColumn<String>(
      'contextType', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _contextNameMeta =
      const VerificationMeta('contextName');
  @override
  late final GeneratedColumn<String> contextName = GeneratedColumn<String>(
      'contextName', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _imageUrlMeta =
      const VerificationMeta('imageUrl');
  @override
  late final GeneratedColumn<String> imageUrl = GeneratedColumn<String>(
      'imageUrl', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _lastPlayedAtMeta =
      const VerificationMeta('lastPlayedAt');
  @override
  late final GeneratedColumn<int> lastPlayedAt = GeneratedColumn<int>(
      'lastPlayedAt', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns =>
      [contextUri, contextType, contextName, imageUrl, lastPlayedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'play_contexts';
  @override
  VerificationContext validateIntegrity(Insertable<PlayContext> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('contextUri')) {
      context.handle(
          _contextUriMeta,
          contextUri.isAcceptableOrUnknown(
              data['contextUri']!, _contextUriMeta));
    }
    if (data.containsKey('contextType')) {
      context.handle(
          _contextTypeMeta,
          contextType.isAcceptableOrUnknown(
              data['contextType']!, _contextTypeMeta));
    } else if (isInserting) {
      context.missing(_contextTypeMeta);
    }
    if (data.containsKey('contextName')) {
      context.handle(
          _contextNameMeta,
          contextName.isAcceptableOrUnknown(
              data['contextName']!, _contextNameMeta));
    } else if (isInserting) {
      context.missing(_contextNameMeta);
    }
    if (data.containsKey('imageUrl')) {
      context.handle(_imageUrlMeta,
          imageUrl.isAcceptableOrUnknown(data['imageUrl']!, _imageUrlMeta));
    }
    if (data.containsKey('lastPlayedAt')) {
      context.handle(
          _lastPlayedAtMeta,
          lastPlayedAt.isAcceptableOrUnknown(
              data['lastPlayedAt']!, _lastPlayedAtMeta));
    } else if (isInserting) {
      context.missing(_lastPlayedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {contextUri};
  @override
  PlayContext map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PlayContext(
      contextUri: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}contextUri']),
      contextType: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}contextType'])!,
      contextName: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}contextName'])!,
      imageUrl: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}imageUrl']),
      lastPlayedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}lastPlayedAt'])!,
    );
  }

  @override
  $PlayContextsTable createAlias(String alias) {
    return $PlayContextsTable(attachedDatabase, alias);
  }
}

class PlayContext extends DataClass implements Insertable<PlayContext> {
  final String? contextUri;
  final String contextType;
  final String contextName;
  final String? imageUrl;
  final int lastPlayedAt;
  const PlayContext(
      {this.contextUri,
      required this.contextType,
      required this.contextName,
      this.imageUrl,
      required this.lastPlayedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (!nullToAbsent || contextUri != null) {
      map['contextUri'] = Variable<String>(contextUri);
    }
    map['contextType'] = Variable<String>(contextType);
    map['contextName'] = Variable<String>(contextName);
    if (!nullToAbsent || imageUrl != null) {
      map['imageUrl'] = Variable<String>(imageUrl);
    }
    map['lastPlayedAt'] = Variable<int>(lastPlayedAt);
    return map;
  }

  PlayContextsCompanion toCompanion(bool nullToAbsent) {
    return PlayContextsCompanion(
      contextUri: contextUri == null && nullToAbsent
          ? const Value.absent()
          : Value(contextUri),
      contextType: Value(contextType),
      contextName: Value(contextName),
      imageUrl: imageUrl == null && nullToAbsent
          ? const Value.absent()
          : Value(imageUrl),
      lastPlayedAt: Value(lastPlayedAt),
    );
  }

  factory PlayContext.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PlayContext(
      contextUri: serializer.fromJson<String?>(json['contextUri']),
      contextType: serializer.fromJson<String>(json['contextType']),
      contextName: serializer.fromJson<String>(json['contextName']),
      imageUrl: serializer.fromJson<String?>(json['imageUrl']),
      lastPlayedAt: serializer.fromJson<int>(json['lastPlayedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'contextUri': serializer.toJson<String?>(contextUri),
      'contextType': serializer.toJson<String>(contextType),
      'contextName': serializer.toJson<String>(contextName),
      'imageUrl': serializer.toJson<String?>(imageUrl),
      'lastPlayedAt': serializer.toJson<int>(lastPlayedAt),
    };
  }

  PlayContext copyWith(
          {Value<String?> contextUri = const Value.absent(),
          String? contextType,
          String? contextName,
          Value<String?> imageUrl = const Value.absent(),
          int? lastPlayedAt}) =>
      PlayContext(
        contextUri: contextUri.present ? contextUri.value : this.contextUri,
        contextType: contextType ?? this.contextType,
        contextName: contextName ?? this.contextName,
        imageUrl: imageUrl.present ? imageUrl.value : this.imageUrl,
        lastPlayedAt: lastPlayedAt ?? this.lastPlayedAt,
      );
  PlayContext copyWithCompanion(PlayContextsCompanion data) {
    return PlayContext(
      contextUri:
          data.contextUri.present ? data.contextUri.value : this.contextUri,
      contextType:
          data.contextType.present ? data.contextType.value : this.contextType,
      contextName:
          data.contextName.present ? data.contextName.value : this.contextName,
      imageUrl: data.imageUrl.present ? data.imageUrl.value : this.imageUrl,
      lastPlayedAt: data.lastPlayedAt.present
          ? data.lastPlayedAt.value
          : this.lastPlayedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PlayContext(')
          ..write('contextUri: $contextUri, ')
          ..write('contextType: $contextType, ')
          ..write('contextName: $contextName, ')
          ..write('imageUrl: $imageUrl, ')
          ..write('lastPlayedAt: $lastPlayedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(contextUri, contextType, contextName, imageUrl, lastPlayedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PlayContext &&
          other.contextUri == this.contextUri &&
          other.contextType == this.contextType &&
          other.contextName == this.contextName &&
          other.imageUrl == this.imageUrl &&
          other.lastPlayedAt == this.lastPlayedAt);
}

class PlayContextsCompanion extends UpdateCompanion<PlayContext> {
  final Value<String?> contextUri;
  final Value<String> contextType;
  final Value<String> contextName;
  final Value<String?> imageUrl;
  final Value<int> lastPlayedAt;
  final Value<int> rowid;
  const PlayContextsCompanion({
    this.contextUri = const Value.absent(),
    this.contextType = const Value.absent(),
    this.contextName = const Value.absent(),
    this.imageUrl = const Value.absent(),
    this.lastPlayedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  PlayContextsCompanion.insert({
    this.contextUri = const Value.absent(),
    required String contextType,
    required String contextName,
    this.imageUrl = const Value.absent(),
    required int lastPlayedAt,
    this.rowid = const Value.absent(),
  })  : contextType = Value(contextType),
        contextName = Value(contextName),
        lastPlayedAt = Value(lastPlayedAt);
  static Insertable<PlayContext> custom({
    Expression<String>? contextUri,
    Expression<String>? contextType,
    Expression<String>? contextName,
    Expression<String>? imageUrl,
    Expression<int>? lastPlayedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (contextUri != null) 'contextUri': contextUri,
      if (contextType != null) 'contextType': contextType,
      if (contextName != null) 'contextName': contextName,
      if (imageUrl != null) 'imageUrl': imageUrl,
      if (lastPlayedAt != null) 'lastPlayedAt': lastPlayedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  PlayContextsCompanion copyWith(
      {Value<String?>? contextUri,
      Value<String>? contextType,
      Value<String>? contextName,
      Value<String?>? imageUrl,
      Value<int>? lastPlayedAt,
      Value<int>? rowid}) {
    return PlayContextsCompanion(
      contextUri: contextUri ?? this.contextUri,
      contextType: contextType ?? this.contextType,
      contextName: contextName ?? this.contextName,
      imageUrl: imageUrl ?? this.imageUrl,
      lastPlayedAt: lastPlayedAt ?? this.lastPlayedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (contextUri.present) {
      map['contextUri'] = Variable<String>(contextUri.value);
    }
    if (contextType.present) {
      map['contextType'] = Variable<String>(contextType.value);
    }
    if (contextName.present) {
      map['contextName'] = Variable<String>(contextName.value);
    }
    if (imageUrl.present) {
      map['imageUrl'] = Variable<String>(imageUrl.value);
    }
    if (lastPlayedAt.present) {
      map['lastPlayedAt'] = Variable<int>(lastPlayedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PlayContextsCompanion(')
          ..write('contextUri: $contextUri, ')
          ..write('contextType: $contextType, ')
          ..write('contextName: $contextName, ')
          ..write('imageUrl: $imageUrl, ')
          ..write('lastPlayedAt: $lastPlayedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $PlayHistoryTable extends PlayHistory
    with TableInfo<$PlayHistoryTable, PlayHistoryData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PlayHistoryTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _sourceKeyMeta =
      const VerificationMeta('sourceKey');
  @override
  late final GeneratedColumn<String> sourceKey = GeneratedColumn<String>(
      'sourceKey', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _songIdMeta = const VerificationMeta('songId');
  @override
  late final GeneratedColumn<String> songId = GeneratedColumn<String>(
      'songId', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
      'title', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _artistMeta = const VerificationMeta('artist');
  @override
  late final GeneratedColumn<String> artist = GeneratedColumn<String>(
      'artist', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _albumMeta = const VerificationMeta('album');
  @override
  late final GeneratedColumn<String> album = GeneratedColumn<String>(
      'album', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _coverUrlMeta =
      const VerificationMeta('coverUrl');
  @override
  late final GeneratedColumn<String> coverUrl = GeneratedColumn<String>(
      'coverUrl', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _durationMsMeta =
      const VerificationMeta('durationMs');
  @override
  late final GeneratedColumn<int> durationMs = GeneratedColumn<int>(
      'durationMs', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _rawMeta = const VerificationMeta('raw');
  @override
  late final GeneratedColumn<String> raw = GeneratedColumn<String>(
      'raw', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('{}'));
  static const VerificationMeta _playedAtMeta =
      const VerificationMeta('playedAt');
  @override
  late final GeneratedColumn<int> playedAt = GeneratedColumn<int>(
      'playedAt', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _versionPhysicalMeta =
      const VerificationMeta('versionPhysical');
  @override
  late final GeneratedColumn<int> versionPhysical = GeneratedColumn<int>(
      'versionPhysical', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _versionCounterMeta =
      const VerificationMeta('versionCounter');
  @override
  late final GeneratedColumn<int> versionCounter = GeneratedColumn<int>(
      'versionCounter', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _deviceIdMeta =
      const VerificationMeta('deviceId');
  @override
  late final GeneratedColumn<String> deviceId = GeneratedColumn<String>(
      'deviceId', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  @override
  List<GeneratedColumn> get $columns => [
        sourceKey,
        songId,
        title,
        artist,
        album,
        coverUrl,
        durationMs,
        raw,
        playedAt,
        versionPhysical,
        versionCounter,
        deviceId
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'play_history';
  @override
  VerificationContext validateIntegrity(Insertable<PlayHistoryData> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('sourceKey')) {
      context.handle(_sourceKeyMeta,
          sourceKey.isAcceptableOrUnknown(data['sourceKey']!, _sourceKeyMeta));
    } else if (isInserting) {
      context.missing(_sourceKeyMeta);
    }
    if (data.containsKey('songId')) {
      context.handle(_songIdMeta,
          songId.isAcceptableOrUnknown(data['songId']!, _songIdMeta));
    } else if (isInserting) {
      context.missing(_songIdMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
          _titleMeta, title.isAcceptableOrUnknown(data['title']!, _titleMeta));
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('artist')) {
      context.handle(_artistMeta,
          artist.isAcceptableOrUnknown(data['artist']!, _artistMeta));
    }
    if (data.containsKey('album')) {
      context.handle(
          _albumMeta, album.isAcceptableOrUnknown(data['album']!, _albumMeta));
    }
    if (data.containsKey('coverUrl')) {
      context.handle(_coverUrlMeta,
          coverUrl.isAcceptableOrUnknown(data['coverUrl']!, _coverUrlMeta));
    }
    if (data.containsKey('durationMs')) {
      context.handle(
          _durationMsMeta,
          durationMs.isAcceptableOrUnknown(
              data['durationMs']!, _durationMsMeta));
    }
    if (data.containsKey('raw')) {
      context.handle(
          _rawMeta, raw.isAcceptableOrUnknown(data['raw']!, _rawMeta));
    }
    if (data.containsKey('playedAt')) {
      context.handle(_playedAtMeta,
          playedAt.isAcceptableOrUnknown(data['playedAt']!, _playedAtMeta));
    } else if (isInserting) {
      context.missing(_playedAtMeta);
    }
    if (data.containsKey('versionPhysical')) {
      context.handle(
          _versionPhysicalMeta,
          versionPhysical.isAcceptableOrUnknown(
              data['versionPhysical']!, _versionPhysicalMeta));
    }
    if (data.containsKey('versionCounter')) {
      context.handle(
          _versionCounterMeta,
          versionCounter.isAcceptableOrUnknown(
              data['versionCounter']!, _versionCounterMeta));
    }
    if (data.containsKey('deviceId')) {
      context.handle(_deviceIdMeta,
          deviceId.isAcceptableOrUnknown(data['deviceId']!, _deviceIdMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => const {};
  @override
  PlayHistoryData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PlayHistoryData(
      sourceKey: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}sourceKey'])!,
      songId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}songId'])!,
      title: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}title'])!,
      artist: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}artist'])!,
      album: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}album'])!,
      coverUrl: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}coverUrl']),
      durationMs: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}durationMs']),
      raw: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}raw'])!,
      playedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}playedAt'])!,
      versionPhysical: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}versionPhysical'])!,
      versionCounter: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}versionCounter'])!,
      deviceId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}deviceId'])!,
    );
  }

  @override
  $PlayHistoryTable createAlias(String alias) {
    return $PlayHistoryTable(attachedDatabase, alias);
  }
}

class PlayHistoryData extends DataClass implements Insertable<PlayHistoryData> {
  final String sourceKey;
  final String songId;
  final String title;
  final String artist;
  final String album;
  final String? coverUrl;
  final int? durationMs;
  final String raw;
  final int playedAt;
  final int versionPhysical;
  final int versionCounter;
  final String deviceId;
  const PlayHistoryData(
      {required this.sourceKey,
      required this.songId,
      required this.title,
      required this.artist,
      required this.album,
      this.coverUrl,
      this.durationMs,
      required this.raw,
      required this.playedAt,
      required this.versionPhysical,
      required this.versionCounter,
      required this.deviceId});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['sourceKey'] = Variable<String>(sourceKey);
    map['songId'] = Variable<String>(songId);
    map['title'] = Variable<String>(title);
    map['artist'] = Variable<String>(artist);
    map['album'] = Variable<String>(album);
    if (!nullToAbsent || coverUrl != null) {
      map['coverUrl'] = Variable<String>(coverUrl);
    }
    if (!nullToAbsent || durationMs != null) {
      map['durationMs'] = Variable<int>(durationMs);
    }
    map['raw'] = Variable<String>(raw);
    map['playedAt'] = Variable<int>(playedAt);
    map['versionPhysical'] = Variable<int>(versionPhysical);
    map['versionCounter'] = Variable<int>(versionCounter);
    map['deviceId'] = Variable<String>(deviceId);
    return map;
  }

  PlayHistoryCompanion toCompanion(bool nullToAbsent) {
    return PlayHistoryCompanion(
      sourceKey: Value(sourceKey),
      songId: Value(songId),
      title: Value(title),
      artist: Value(artist),
      album: Value(album),
      coverUrl: coverUrl == null && nullToAbsent
          ? const Value.absent()
          : Value(coverUrl),
      durationMs: durationMs == null && nullToAbsent
          ? const Value.absent()
          : Value(durationMs),
      raw: Value(raw),
      playedAt: Value(playedAt),
      versionPhysical: Value(versionPhysical),
      versionCounter: Value(versionCounter),
      deviceId: Value(deviceId),
    );
  }

  factory PlayHistoryData.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PlayHistoryData(
      sourceKey: serializer.fromJson<String>(json['sourceKey']),
      songId: serializer.fromJson<String>(json['songId']),
      title: serializer.fromJson<String>(json['title']),
      artist: serializer.fromJson<String>(json['artist']),
      album: serializer.fromJson<String>(json['album']),
      coverUrl: serializer.fromJson<String?>(json['coverUrl']),
      durationMs: serializer.fromJson<int?>(json['durationMs']),
      raw: serializer.fromJson<String>(json['raw']),
      playedAt: serializer.fromJson<int>(json['playedAt']),
      versionPhysical: serializer.fromJson<int>(json['versionPhysical']),
      versionCounter: serializer.fromJson<int>(json['versionCounter']),
      deviceId: serializer.fromJson<String>(json['deviceId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'sourceKey': serializer.toJson<String>(sourceKey),
      'songId': serializer.toJson<String>(songId),
      'title': serializer.toJson<String>(title),
      'artist': serializer.toJson<String>(artist),
      'album': serializer.toJson<String>(album),
      'coverUrl': serializer.toJson<String?>(coverUrl),
      'durationMs': serializer.toJson<int?>(durationMs),
      'raw': serializer.toJson<String>(raw),
      'playedAt': serializer.toJson<int>(playedAt),
      'versionPhysical': serializer.toJson<int>(versionPhysical),
      'versionCounter': serializer.toJson<int>(versionCounter),
      'deviceId': serializer.toJson<String>(deviceId),
    };
  }

  PlayHistoryData copyWith(
          {String? sourceKey,
          String? songId,
          String? title,
          String? artist,
          String? album,
          Value<String?> coverUrl = const Value.absent(),
          Value<int?> durationMs = const Value.absent(),
          String? raw,
          int? playedAt,
          int? versionPhysical,
          int? versionCounter,
          String? deviceId}) =>
      PlayHistoryData(
        sourceKey: sourceKey ?? this.sourceKey,
        songId: songId ?? this.songId,
        title: title ?? this.title,
        artist: artist ?? this.artist,
        album: album ?? this.album,
        coverUrl: coverUrl.present ? coverUrl.value : this.coverUrl,
        durationMs: durationMs.present ? durationMs.value : this.durationMs,
        raw: raw ?? this.raw,
        playedAt: playedAt ?? this.playedAt,
        versionPhysical: versionPhysical ?? this.versionPhysical,
        versionCounter: versionCounter ?? this.versionCounter,
        deviceId: deviceId ?? this.deviceId,
      );
  PlayHistoryData copyWithCompanion(PlayHistoryCompanion data) {
    return PlayHistoryData(
      sourceKey: data.sourceKey.present ? data.sourceKey.value : this.sourceKey,
      songId: data.songId.present ? data.songId.value : this.songId,
      title: data.title.present ? data.title.value : this.title,
      artist: data.artist.present ? data.artist.value : this.artist,
      album: data.album.present ? data.album.value : this.album,
      coverUrl: data.coverUrl.present ? data.coverUrl.value : this.coverUrl,
      durationMs:
          data.durationMs.present ? data.durationMs.value : this.durationMs,
      raw: data.raw.present ? data.raw.value : this.raw,
      playedAt: data.playedAt.present ? data.playedAt.value : this.playedAt,
      versionPhysical: data.versionPhysical.present
          ? data.versionPhysical.value
          : this.versionPhysical,
      versionCounter: data.versionCounter.present
          ? data.versionCounter.value
          : this.versionCounter,
      deviceId: data.deviceId.present ? data.deviceId.value : this.deviceId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PlayHistoryData(')
          ..write('sourceKey: $sourceKey, ')
          ..write('songId: $songId, ')
          ..write('title: $title, ')
          ..write('artist: $artist, ')
          ..write('album: $album, ')
          ..write('coverUrl: $coverUrl, ')
          ..write('durationMs: $durationMs, ')
          ..write('raw: $raw, ')
          ..write('playedAt: $playedAt, ')
          ..write('versionPhysical: $versionPhysical, ')
          ..write('versionCounter: $versionCounter, ')
          ..write('deviceId: $deviceId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      sourceKey,
      songId,
      title,
      artist,
      album,
      coverUrl,
      durationMs,
      raw,
      playedAt,
      versionPhysical,
      versionCounter,
      deviceId);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PlayHistoryData &&
          other.sourceKey == this.sourceKey &&
          other.songId == this.songId &&
          other.title == this.title &&
          other.artist == this.artist &&
          other.album == this.album &&
          other.coverUrl == this.coverUrl &&
          other.durationMs == this.durationMs &&
          other.raw == this.raw &&
          other.playedAt == this.playedAt &&
          other.versionPhysical == this.versionPhysical &&
          other.versionCounter == this.versionCounter &&
          other.deviceId == this.deviceId);
}

class PlayHistoryCompanion extends UpdateCompanion<PlayHistoryData> {
  final Value<String> sourceKey;
  final Value<String> songId;
  final Value<String> title;
  final Value<String> artist;
  final Value<String> album;
  final Value<String?> coverUrl;
  final Value<int?> durationMs;
  final Value<String> raw;
  final Value<int> playedAt;
  final Value<int> versionPhysical;
  final Value<int> versionCounter;
  final Value<String> deviceId;
  final Value<int> rowid;
  const PlayHistoryCompanion({
    this.sourceKey = const Value.absent(),
    this.songId = const Value.absent(),
    this.title = const Value.absent(),
    this.artist = const Value.absent(),
    this.album = const Value.absent(),
    this.coverUrl = const Value.absent(),
    this.durationMs = const Value.absent(),
    this.raw = const Value.absent(),
    this.playedAt = const Value.absent(),
    this.versionPhysical = const Value.absent(),
    this.versionCounter = const Value.absent(),
    this.deviceId = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  PlayHistoryCompanion.insert({
    required String sourceKey,
    required String songId,
    required String title,
    this.artist = const Value.absent(),
    this.album = const Value.absent(),
    this.coverUrl = const Value.absent(),
    this.durationMs = const Value.absent(),
    this.raw = const Value.absent(),
    required int playedAt,
    this.versionPhysical = const Value.absent(),
    this.versionCounter = const Value.absent(),
    this.deviceId = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : sourceKey = Value(sourceKey),
        songId = Value(songId),
        title = Value(title),
        playedAt = Value(playedAt);
  static Insertable<PlayHistoryData> custom({
    Expression<String>? sourceKey,
    Expression<String>? songId,
    Expression<String>? title,
    Expression<String>? artist,
    Expression<String>? album,
    Expression<String>? coverUrl,
    Expression<int>? durationMs,
    Expression<String>? raw,
    Expression<int>? playedAt,
    Expression<int>? versionPhysical,
    Expression<int>? versionCounter,
    Expression<String>? deviceId,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (sourceKey != null) 'sourceKey': sourceKey,
      if (songId != null) 'songId': songId,
      if (title != null) 'title': title,
      if (artist != null) 'artist': artist,
      if (album != null) 'album': album,
      if (coverUrl != null) 'coverUrl': coverUrl,
      if (durationMs != null) 'durationMs': durationMs,
      if (raw != null) 'raw': raw,
      if (playedAt != null) 'playedAt': playedAt,
      if (versionPhysical != null) 'versionPhysical': versionPhysical,
      if (versionCounter != null) 'versionCounter': versionCounter,
      if (deviceId != null) 'deviceId': deviceId,
      if (rowid != null) 'rowid': rowid,
    });
  }

  PlayHistoryCompanion copyWith(
      {Value<String>? sourceKey,
      Value<String>? songId,
      Value<String>? title,
      Value<String>? artist,
      Value<String>? album,
      Value<String?>? coverUrl,
      Value<int?>? durationMs,
      Value<String>? raw,
      Value<int>? playedAt,
      Value<int>? versionPhysical,
      Value<int>? versionCounter,
      Value<String>? deviceId,
      Value<int>? rowid}) {
    return PlayHistoryCompanion(
      sourceKey: sourceKey ?? this.sourceKey,
      songId: songId ?? this.songId,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      coverUrl: coverUrl ?? this.coverUrl,
      durationMs: durationMs ?? this.durationMs,
      raw: raw ?? this.raw,
      playedAt: playedAt ?? this.playedAt,
      versionPhysical: versionPhysical ?? this.versionPhysical,
      versionCounter: versionCounter ?? this.versionCounter,
      deviceId: deviceId ?? this.deviceId,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (sourceKey.present) {
      map['sourceKey'] = Variable<String>(sourceKey.value);
    }
    if (songId.present) {
      map['songId'] = Variable<String>(songId.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (artist.present) {
      map['artist'] = Variable<String>(artist.value);
    }
    if (album.present) {
      map['album'] = Variable<String>(album.value);
    }
    if (coverUrl.present) {
      map['coverUrl'] = Variable<String>(coverUrl.value);
    }
    if (durationMs.present) {
      map['durationMs'] = Variable<int>(durationMs.value);
    }
    if (raw.present) {
      map['raw'] = Variable<String>(raw.value);
    }
    if (playedAt.present) {
      map['playedAt'] = Variable<int>(playedAt.value);
    }
    if (versionPhysical.present) {
      map['versionPhysical'] = Variable<int>(versionPhysical.value);
    }
    if (versionCounter.present) {
      map['versionCounter'] = Variable<int>(versionCounter.value);
    }
    if (deviceId.present) {
      map['deviceId'] = Variable<String>(deviceId.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PlayHistoryCompanion(')
          ..write('sourceKey: $sourceKey, ')
          ..write('songId: $songId, ')
          ..write('title: $title, ')
          ..write('artist: $artist, ')
          ..write('album: $album, ')
          ..write('coverUrl: $coverUrl, ')
          ..write('durationMs: $durationMs, ')
          ..write('raw: $raw, ')
          ..write('playedAt: $playedAt, ')
          ..write('versionPhysical: $versionPhysical, ')
          ..write('versionCounter: $versionCounter, ')
          ..write('deviceId: $deviceId, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $PlaylistsTable extends Playlists
    with TableInfo<$PlaylistsTable, Playlist> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PlaylistsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
      'name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
      'createdAt', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _syncIdMeta = const VerificationMeta('syncId');
  @override
  late final GeneratedColumn<String> syncId = GeneratedColumn<String>(
      'syncId', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _versionPhysicalMeta =
      const VerificationMeta('versionPhysical');
  @override
  late final GeneratedColumn<int> versionPhysical = GeneratedColumn<int>(
      'versionPhysical', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _versionCounterMeta =
      const VerificationMeta('versionCounter');
  @override
  late final GeneratedColumn<int> versionCounter = GeneratedColumn<int>(
      'versionCounter', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _deviceIdMeta =
      const VerificationMeta('deviceId');
  @override
  late final GeneratedColumn<String> deviceId = GeneratedColumn<String>(
      'deviceId', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  @override
  List<GeneratedColumn> get $columns =>
      [id, name, createdAt, syncId, versionPhysical, versionCounter, deviceId];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'playlists';
  @override
  VerificationContext validateIntegrity(Insertable<Playlist> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('name')) {
      context.handle(
          _nameMeta, name.isAcceptableOrUnknown(data['name']!, _nameMeta));
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('createdAt')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['createdAt']!, _createdAtMeta));
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('syncId')) {
      context.handle(_syncIdMeta,
          syncId.isAcceptableOrUnknown(data['syncId']!, _syncIdMeta));
    }
    if (data.containsKey('versionPhysical')) {
      context.handle(
          _versionPhysicalMeta,
          versionPhysical.isAcceptableOrUnknown(
              data['versionPhysical']!, _versionPhysicalMeta));
    }
    if (data.containsKey('versionCounter')) {
      context.handle(
          _versionCounterMeta,
          versionCounter.isAcceptableOrUnknown(
              data['versionCounter']!, _versionCounterMeta));
    }
    if (data.containsKey('deviceId')) {
      context.handle(_deviceIdMeta,
          deviceId.isAcceptableOrUnknown(data['deviceId']!, _deviceIdMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Playlist map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Playlist(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      name: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}name'])!,
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}createdAt'])!,
      syncId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}syncId']),
      versionPhysical: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}versionPhysical'])!,
      versionCounter: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}versionCounter'])!,
      deviceId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}deviceId'])!,
    );
  }

  @override
  $PlaylistsTable createAlias(String alias) {
    return $PlaylistsTable(attachedDatabase, alias);
  }
}

class Playlist extends DataClass implements Insertable<Playlist> {
  final int id;
  final String name;
  final int createdAt;
  final String? syncId;
  final int versionPhysical;
  final int versionCounter;
  final String deviceId;
  const Playlist(
      {required this.id,
      required this.name,
      required this.createdAt,
      this.syncId,
      required this.versionPhysical,
      required this.versionCounter,
      required this.deviceId});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['name'] = Variable<String>(name);
    map['createdAt'] = Variable<int>(createdAt);
    if (!nullToAbsent || syncId != null) {
      map['syncId'] = Variable<String>(syncId);
    }
    map['versionPhysical'] = Variable<int>(versionPhysical);
    map['versionCounter'] = Variable<int>(versionCounter);
    map['deviceId'] = Variable<String>(deviceId);
    return map;
  }

  PlaylistsCompanion toCompanion(bool nullToAbsent) {
    return PlaylistsCompanion(
      id: Value(id),
      name: Value(name),
      createdAt: Value(createdAt),
      syncId:
          syncId == null && nullToAbsent ? const Value.absent() : Value(syncId),
      versionPhysical: Value(versionPhysical),
      versionCounter: Value(versionCounter),
      deviceId: Value(deviceId),
    );
  }

  factory Playlist.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Playlist(
      id: serializer.fromJson<int>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      syncId: serializer.fromJson<String?>(json['syncId']),
      versionPhysical: serializer.fromJson<int>(json['versionPhysical']),
      versionCounter: serializer.fromJson<int>(json['versionCounter']),
      deviceId: serializer.fromJson<String>(json['deviceId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'name': serializer.toJson<String>(name),
      'createdAt': serializer.toJson<int>(createdAt),
      'syncId': serializer.toJson<String?>(syncId),
      'versionPhysical': serializer.toJson<int>(versionPhysical),
      'versionCounter': serializer.toJson<int>(versionCounter),
      'deviceId': serializer.toJson<String>(deviceId),
    };
  }

  Playlist copyWith(
          {int? id,
          String? name,
          int? createdAt,
          Value<String?> syncId = const Value.absent(),
          int? versionPhysical,
          int? versionCounter,
          String? deviceId}) =>
      Playlist(
        id: id ?? this.id,
        name: name ?? this.name,
        createdAt: createdAt ?? this.createdAt,
        syncId: syncId.present ? syncId.value : this.syncId,
        versionPhysical: versionPhysical ?? this.versionPhysical,
        versionCounter: versionCounter ?? this.versionCounter,
        deviceId: deviceId ?? this.deviceId,
      );
  Playlist copyWithCompanion(PlaylistsCompanion data) {
    return Playlist(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      syncId: data.syncId.present ? data.syncId.value : this.syncId,
      versionPhysical: data.versionPhysical.present
          ? data.versionPhysical.value
          : this.versionPhysical,
      versionCounter: data.versionCounter.present
          ? data.versionCounter.value
          : this.versionCounter,
      deviceId: data.deviceId.present ? data.deviceId.value : this.deviceId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Playlist(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('createdAt: $createdAt, ')
          ..write('syncId: $syncId, ')
          ..write('versionPhysical: $versionPhysical, ')
          ..write('versionCounter: $versionCounter, ')
          ..write('deviceId: $deviceId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id, name, createdAt, syncId, versionPhysical, versionCounter, deviceId);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Playlist &&
          other.id == this.id &&
          other.name == this.name &&
          other.createdAt == this.createdAt &&
          other.syncId == this.syncId &&
          other.versionPhysical == this.versionPhysical &&
          other.versionCounter == this.versionCounter &&
          other.deviceId == this.deviceId);
}

class PlaylistsCompanion extends UpdateCompanion<Playlist> {
  final Value<int> id;
  final Value<String> name;
  final Value<int> createdAt;
  final Value<String?> syncId;
  final Value<int> versionPhysical;
  final Value<int> versionCounter;
  final Value<String> deviceId;
  const PlaylistsCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.syncId = const Value.absent(),
    this.versionPhysical = const Value.absent(),
    this.versionCounter = const Value.absent(),
    this.deviceId = const Value.absent(),
  });
  PlaylistsCompanion.insert({
    this.id = const Value.absent(),
    required String name,
    required int createdAt,
    this.syncId = const Value.absent(),
    this.versionPhysical = const Value.absent(),
    this.versionCounter = const Value.absent(),
    this.deviceId = const Value.absent(),
  })  : name = Value(name),
        createdAt = Value(createdAt);
  static Insertable<Playlist> custom({
    Expression<int>? id,
    Expression<String>? name,
    Expression<int>? createdAt,
    Expression<String>? syncId,
    Expression<int>? versionPhysical,
    Expression<int>? versionCounter,
    Expression<String>? deviceId,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (createdAt != null) 'createdAt': createdAt,
      if (syncId != null) 'syncId': syncId,
      if (versionPhysical != null) 'versionPhysical': versionPhysical,
      if (versionCounter != null) 'versionCounter': versionCounter,
      if (deviceId != null) 'deviceId': deviceId,
    });
  }

  PlaylistsCompanion copyWith(
      {Value<int>? id,
      Value<String>? name,
      Value<int>? createdAt,
      Value<String?>? syncId,
      Value<int>? versionPhysical,
      Value<int>? versionCounter,
      Value<String>? deviceId}) {
    return PlaylistsCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      createdAt: createdAt ?? this.createdAt,
      syncId: syncId ?? this.syncId,
      versionPhysical: versionPhysical ?? this.versionPhysical,
      versionCounter: versionCounter ?? this.versionCounter,
      deviceId: deviceId ?? this.deviceId,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (createdAt.present) {
      map['createdAt'] = Variable<int>(createdAt.value);
    }
    if (syncId.present) {
      map['syncId'] = Variable<String>(syncId.value);
    }
    if (versionPhysical.present) {
      map['versionPhysical'] = Variable<int>(versionPhysical.value);
    }
    if (versionCounter.present) {
      map['versionCounter'] = Variable<int>(versionCounter.value);
    }
    if (deviceId.present) {
      map['deviceId'] = Variable<String>(deviceId.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PlaylistsCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('createdAt: $createdAt, ')
          ..write('syncId: $syncId, ')
          ..write('versionPhysical: $versionPhysical, ')
          ..write('versionCounter: $versionCounter, ')
          ..write('deviceId: $deviceId')
          ..write(')'))
        .toString();
  }
}

class $PlaylistTracksTable extends PlaylistTracks
    with TableInfo<$PlaylistTracksTable, PlaylistTrackRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PlaylistTracksTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _playlistIdMeta =
      const VerificationMeta('playlistId');
  @override
  late final GeneratedColumn<int> playlistId = GeneratedColumn<int>(
      'playlistId', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _sourceKeyMeta =
      const VerificationMeta('sourceKey');
  @override
  late final GeneratedColumn<String> sourceKey = GeneratedColumn<String>(
      'sourceKey', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _songIdMeta = const VerificationMeta('songId');
  @override
  late final GeneratedColumn<String> songId = GeneratedColumn<String>(
      'songId', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
      'title', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _artistMeta = const VerificationMeta('artist');
  @override
  late final GeneratedColumn<String> artist = GeneratedColumn<String>(
      'artist', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _albumMeta = const VerificationMeta('album');
  @override
  late final GeneratedColumn<String> album = GeneratedColumn<String>(
      'album', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _coverUrlMeta =
      const VerificationMeta('coverUrl');
  @override
  late final GeneratedColumn<String> coverUrl = GeneratedColumn<String>(
      'coverUrl', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _durationMsMeta =
      const VerificationMeta('durationMs');
  @override
  late final GeneratedColumn<int> durationMs = GeneratedColumn<int>(
      'durationMs', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _rawMeta = const VerificationMeta('raw');
  @override
  late final GeneratedColumn<String> raw = GeneratedColumn<String>(
      'raw', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('{}'));
  static const VerificationMeta _addedAtMeta =
      const VerificationMeta('addedAt');
  @override
  late final GeneratedColumn<int> addedAt = GeneratedColumn<int>(
      'addedAt', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _sortOrderMeta =
      const VerificationMeta('sortOrder');
  @override
  late final GeneratedColumn<int> sortOrder = GeneratedColumn<int>(
      'sortOrder', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _versionPhysicalMeta =
      const VerificationMeta('versionPhysical');
  @override
  late final GeneratedColumn<int> versionPhysical = GeneratedColumn<int>(
      'versionPhysical', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _versionCounterMeta =
      const VerificationMeta('versionCounter');
  @override
  late final GeneratedColumn<int> versionCounter = GeneratedColumn<int>(
      'versionCounter', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _deviceIdMeta =
      const VerificationMeta('deviceId');
  @override
  late final GeneratedColumn<String> deviceId = GeneratedColumn<String>(
      'deviceId', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  @override
  List<GeneratedColumn> get $columns => [
        id,
        playlistId,
        sourceKey,
        songId,
        title,
        artist,
        album,
        coverUrl,
        durationMs,
        raw,
        addedAt,
        sortOrder,
        versionPhysical,
        versionCounter,
        deviceId
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'playlist_tracks';
  @override
  VerificationContext validateIntegrity(Insertable<PlaylistTrackRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('playlistId')) {
      context.handle(
          _playlistIdMeta,
          playlistId.isAcceptableOrUnknown(
              data['playlistId']!, _playlistIdMeta));
    } else if (isInserting) {
      context.missing(_playlistIdMeta);
    }
    if (data.containsKey('sourceKey')) {
      context.handle(_sourceKeyMeta,
          sourceKey.isAcceptableOrUnknown(data['sourceKey']!, _sourceKeyMeta));
    } else if (isInserting) {
      context.missing(_sourceKeyMeta);
    }
    if (data.containsKey('songId')) {
      context.handle(_songIdMeta,
          songId.isAcceptableOrUnknown(data['songId']!, _songIdMeta));
    } else if (isInserting) {
      context.missing(_songIdMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
          _titleMeta, title.isAcceptableOrUnknown(data['title']!, _titleMeta));
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('artist')) {
      context.handle(_artistMeta,
          artist.isAcceptableOrUnknown(data['artist']!, _artistMeta));
    }
    if (data.containsKey('album')) {
      context.handle(
          _albumMeta, album.isAcceptableOrUnknown(data['album']!, _albumMeta));
    }
    if (data.containsKey('coverUrl')) {
      context.handle(_coverUrlMeta,
          coverUrl.isAcceptableOrUnknown(data['coverUrl']!, _coverUrlMeta));
    }
    if (data.containsKey('durationMs')) {
      context.handle(
          _durationMsMeta,
          durationMs.isAcceptableOrUnknown(
              data['durationMs']!, _durationMsMeta));
    }
    if (data.containsKey('raw')) {
      context.handle(
          _rawMeta, raw.isAcceptableOrUnknown(data['raw']!, _rawMeta));
    }
    if (data.containsKey('addedAt')) {
      context.handle(_addedAtMeta,
          addedAt.isAcceptableOrUnknown(data['addedAt']!, _addedAtMeta));
    } else if (isInserting) {
      context.missing(_addedAtMeta);
    }
    if (data.containsKey('sortOrder')) {
      context.handle(_sortOrderMeta,
          sortOrder.isAcceptableOrUnknown(data['sortOrder']!, _sortOrderMeta));
    }
    if (data.containsKey('versionPhysical')) {
      context.handle(
          _versionPhysicalMeta,
          versionPhysical.isAcceptableOrUnknown(
              data['versionPhysical']!, _versionPhysicalMeta));
    }
    if (data.containsKey('versionCounter')) {
      context.handle(
          _versionCounterMeta,
          versionCounter.isAcceptableOrUnknown(
              data['versionCounter']!, _versionCounterMeta));
    }
    if (data.containsKey('deviceId')) {
      context.handle(_deviceIdMeta,
          deviceId.isAcceptableOrUnknown(data['deviceId']!, _deviceIdMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  PlaylistTrackRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PlaylistTrackRow(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      playlistId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}playlistId'])!,
      sourceKey: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}sourceKey'])!,
      songId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}songId'])!,
      title: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}title'])!,
      artist: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}artist'])!,
      album: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}album'])!,
      coverUrl: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}coverUrl']),
      durationMs: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}durationMs']),
      raw: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}raw'])!,
      addedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}addedAt'])!,
      sortOrder: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}sortOrder'])!,
      versionPhysical: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}versionPhysical'])!,
      versionCounter: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}versionCounter'])!,
      deviceId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}deviceId'])!,
    );
  }

  @override
  $PlaylistTracksTable createAlias(String alias) {
    return $PlaylistTracksTable(attachedDatabase, alias);
  }
}

class PlaylistTrackRow extends DataClass
    implements Insertable<PlaylistTrackRow> {
  final int id;
  final int playlistId;
  final String sourceKey;
  final String songId;
  final String title;
  final String artist;
  final String album;
  final String? coverUrl;
  final int? durationMs;
  final String raw;
  final int addedAt;
  final int sortOrder;
  final int versionPhysical;
  final int versionCounter;
  final String deviceId;
  const PlaylistTrackRow(
      {required this.id,
      required this.playlistId,
      required this.sourceKey,
      required this.songId,
      required this.title,
      required this.artist,
      required this.album,
      this.coverUrl,
      this.durationMs,
      required this.raw,
      required this.addedAt,
      required this.sortOrder,
      required this.versionPhysical,
      required this.versionCounter,
      required this.deviceId});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['playlistId'] = Variable<int>(playlistId);
    map['sourceKey'] = Variable<String>(sourceKey);
    map['songId'] = Variable<String>(songId);
    map['title'] = Variable<String>(title);
    map['artist'] = Variable<String>(artist);
    map['album'] = Variable<String>(album);
    if (!nullToAbsent || coverUrl != null) {
      map['coverUrl'] = Variable<String>(coverUrl);
    }
    if (!nullToAbsent || durationMs != null) {
      map['durationMs'] = Variable<int>(durationMs);
    }
    map['raw'] = Variable<String>(raw);
    map['addedAt'] = Variable<int>(addedAt);
    map['sortOrder'] = Variable<int>(sortOrder);
    map['versionPhysical'] = Variable<int>(versionPhysical);
    map['versionCounter'] = Variable<int>(versionCounter);
    map['deviceId'] = Variable<String>(deviceId);
    return map;
  }

  PlaylistTracksCompanion toCompanion(bool nullToAbsent) {
    return PlaylistTracksCompanion(
      id: Value(id),
      playlistId: Value(playlistId),
      sourceKey: Value(sourceKey),
      songId: Value(songId),
      title: Value(title),
      artist: Value(artist),
      album: Value(album),
      coverUrl: coverUrl == null && nullToAbsent
          ? const Value.absent()
          : Value(coverUrl),
      durationMs: durationMs == null && nullToAbsent
          ? const Value.absent()
          : Value(durationMs),
      raw: Value(raw),
      addedAt: Value(addedAt),
      sortOrder: Value(sortOrder),
      versionPhysical: Value(versionPhysical),
      versionCounter: Value(versionCounter),
      deviceId: Value(deviceId),
    );
  }

  factory PlaylistTrackRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PlaylistTrackRow(
      id: serializer.fromJson<int>(json['id']),
      playlistId: serializer.fromJson<int>(json['playlistId']),
      sourceKey: serializer.fromJson<String>(json['sourceKey']),
      songId: serializer.fromJson<String>(json['songId']),
      title: serializer.fromJson<String>(json['title']),
      artist: serializer.fromJson<String>(json['artist']),
      album: serializer.fromJson<String>(json['album']),
      coverUrl: serializer.fromJson<String?>(json['coverUrl']),
      durationMs: serializer.fromJson<int?>(json['durationMs']),
      raw: serializer.fromJson<String>(json['raw']),
      addedAt: serializer.fromJson<int>(json['addedAt']),
      sortOrder: serializer.fromJson<int>(json['sortOrder']),
      versionPhysical: serializer.fromJson<int>(json['versionPhysical']),
      versionCounter: serializer.fromJson<int>(json['versionCounter']),
      deviceId: serializer.fromJson<String>(json['deviceId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'playlistId': serializer.toJson<int>(playlistId),
      'sourceKey': serializer.toJson<String>(sourceKey),
      'songId': serializer.toJson<String>(songId),
      'title': serializer.toJson<String>(title),
      'artist': serializer.toJson<String>(artist),
      'album': serializer.toJson<String>(album),
      'coverUrl': serializer.toJson<String?>(coverUrl),
      'durationMs': serializer.toJson<int?>(durationMs),
      'raw': serializer.toJson<String>(raw),
      'addedAt': serializer.toJson<int>(addedAt),
      'sortOrder': serializer.toJson<int>(sortOrder),
      'versionPhysical': serializer.toJson<int>(versionPhysical),
      'versionCounter': serializer.toJson<int>(versionCounter),
      'deviceId': serializer.toJson<String>(deviceId),
    };
  }

  PlaylistTrackRow copyWith(
          {int? id,
          int? playlistId,
          String? sourceKey,
          String? songId,
          String? title,
          String? artist,
          String? album,
          Value<String?> coverUrl = const Value.absent(),
          Value<int?> durationMs = const Value.absent(),
          String? raw,
          int? addedAt,
          int? sortOrder,
          int? versionPhysical,
          int? versionCounter,
          String? deviceId}) =>
      PlaylistTrackRow(
        id: id ?? this.id,
        playlistId: playlistId ?? this.playlistId,
        sourceKey: sourceKey ?? this.sourceKey,
        songId: songId ?? this.songId,
        title: title ?? this.title,
        artist: artist ?? this.artist,
        album: album ?? this.album,
        coverUrl: coverUrl.present ? coverUrl.value : this.coverUrl,
        durationMs: durationMs.present ? durationMs.value : this.durationMs,
        raw: raw ?? this.raw,
        addedAt: addedAt ?? this.addedAt,
        sortOrder: sortOrder ?? this.sortOrder,
        versionPhysical: versionPhysical ?? this.versionPhysical,
        versionCounter: versionCounter ?? this.versionCounter,
        deviceId: deviceId ?? this.deviceId,
      );
  PlaylistTrackRow copyWithCompanion(PlaylistTracksCompanion data) {
    return PlaylistTrackRow(
      id: data.id.present ? data.id.value : this.id,
      playlistId:
          data.playlistId.present ? data.playlistId.value : this.playlistId,
      sourceKey: data.sourceKey.present ? data.sourceKey.value : this.sourceKey,
      songId: data.songId.present ? data.songId.value : this.songId,
      title: data.title.present ? data.title.value : this.title,
      artist: data.artist.present ? data.artist.value : this.artist,
      album: data.album.present ? data.album.value : this.album,
      coverUrl: data.coverUrl.present ? data.coverUrl.value : this.coverUrl,
      durationMs:
          data.durationMs.present ? data.durationMs.value : this.durationMs,
      raw: data.raw.present ? data.raw.value : this.raw,
      addedAt: data.addedAt.present ? data.addedAt.value : this.addedAt,
      sortOrder: data.sortOrder.present ? data.sortOrder.value : this.sortOrder,
      versionPhysical: data.versionPhysical.present
          ? data.versionPhysical.value
          : this.versionPhysical,
      versionCounter: data.versionCounter.present
          ? data.versionCounter.value
          : this.versionCounter,
      deviceId: data.deviceId.present ? data.deviceId.value : this.deviceId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PlaylistTrackRow(')
          ..write('id: $id, ')
          ..write('playlistId: $playlistId, ')
          ..write('sourceKey: $sourceKey, ')
          ..write('songId: $songId, ')
          ..write('title: $title, ')
          ..write('artist: $artist, ')
          ..write('album: $album, ')
          ..write('coverUrl: $coverUrl, ')
          ..write('durationMs: $durationMs, ')
          ..write('raw: $raw, ')
          ..write('addedAt: $addedAt, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('versionPhysical: $versionPhysical, ')
          ..write('versionCounter: $versionCounter, ')
          ..write('deviceId: $deviceId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id,
      playlistId,
      sourceKey,
      songId,
      title,
      artist,
      album,
      coverUrl,
      durationMs,
      raw,
      addedAt,
      sortOrder,
      versionPhysical,
      versionCounter,
      deviceId);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PlaylistTrackRow &&
          other.id == this.id &&
          other.playlistId == this.playlistId &&
          other.sourceKey == this.sourceKey &&
          other.songId == this.songId &&
          other.title == this.title &&
          other.artist == this.artist &&
          other.album == this.album &&
          other.coverUrl == this.coverUrl &&
          other.durationMs == this.durationMs &&
          other.raw == this.raw &&
          other.addedAt == this.addedAt &&
          other.sortOrder == this.sortOrder &&
          other.versionPhysical == this.versionPhysical &&
          other.versionCounter == this.versionCounter &&
          other.deviceId == this.deviceId);
}

class PlaylistTracksCompanion extends UpdateCompanion<PlaylistTrackRow> {
  final Value<int> id;
  final Value<int> playlistId;
  final Value<String> sourceKey;
  final Value<String> songId;
  final Value<String> title;
  final Value<String> artist;
  final Value<String> album;
  final Value<String?> coverUrl;
  final Value<int?> durationMs;
  final Value<String> raw;
  final Value<int> addedAt;
  final Value<int> sortOrder;
  final Value<int> versionPhysical;
  final Value<int> versionCounter;
  final Value<String> deviceId;
  const PlaylistTracksCompanion({
    this.id = const Value.absent(),
    this.playlistId = const Value.absent(),
    this.sourceKey = const Value.absent(),
    this.songId = const Value.absent(),
    this.title = const Value.absent(),
    this.artist = const Value.absent(),
    this.album = const Value.absent(),
    this.coverUrl = const Value.absent(),
    this.durationMs = const Value.absent(),
    this.raw = const Value.absent(),
    this.addedAt = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.versionPhysical = const Value.absent(),
    this.versionCounter = const Value.absent(),
    this.deviceId = const Value.absent(),
  });
  PlaylistTracksCompanion.insert({
    this.id = const Value.absent(),
    required int playlistId,
    required String sourceKey,
    required String songId,
    required String title,
    this.artist = const Value.absent(),
    this.album = const Value.absent(),
    this.coverUrl = const Value.absent(),
    this.durationMs = const Value.absent(),
    this.raw = const Value.absent(),
    required int addedAt,
    this.sortOrder = const Value.absent(),
    this.versionPhysical = const Value.absent(),
    this.versionCounter = const Value.absent(),
    this.deviceId = const Value.absent(),
  })  : playlistId = Value(playlistId),
        sourceKey = Value(sourceKey),
        songId = Value(songId),
        title = Value(title),
        addedAt = Value(addedAt);
  static Insertable<PlaylistTrackRow> custom({
    Expression<int>? id,
    Expression<int>? playlistId,
    Expression<String>? sourceKey,
    Expression<String>? songId,
    Expression<String>? title,
    Expression<String>? artist,
    Expression<String>? album,
    Expression<String>? coverUrl,
    Expression<int>? durationMs,
    Expression<String>? raw,
    Expression<int>? addedAt,
    Expression<int>? sortOrder,
    Expression<int>? versionPhysical,
    Expression<int>? versionCounter,
    Expression<String>? deviceId,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (playlistId != null) 'playlistId': playlistId,
      if (sourceKey != null) 'sourceKey': sourceKey,
      if (songId != null) 'songId': songId,
      if (title != null) 'title': title,
      if (artist != null) 'artist': artist,
      if (album != null) 'album': album,
      if (coverUrl != null) 'coverUrl': coverUrl,
      if (durationMs != null) 'durationMs': durationMs,
      if (raw != null) 'raw': raw,
      if (addedAt != null) 'addedAt': addedAt,
      if (sortOrder != null) 'sortOrder': sortOrder,
      if (versionPhysical != null) 'versionPhysical': versionPhysical,
      if (versionCounter != null) 'versionCounter': versionCounter,
      if (deviceId != null) 'deviceId': deviceId,
    });
  }

  PlaylistTracksCompanion copyWith(
      {Value<int>? id,
      Value<int>? playlistId,
      Value<String>? sourceKey,
      Value<String>? songId,
      Value<String>? title,
      Value<String>? artist,
      Value<String>? album,
      Value<String?>? coverUrl,
      Value<int?>? durationMs,
      Value<String>? raw,
      Value<int>? addedAt,
      Value<int>? sortOrder,
      Value<int>? versionPhysical,
      Value<int>? versionCounter,
      Value<String>? deviceId}) {
    return PlaylistTracksCompanion(
      id: id ?? this.id,
      playlistId: playlistId ?? this.playlistId,
      sourceKey: sourceKey ?? this.sourceKey,
      songId: songId ?? this.songId,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      coverUrl: coverUrl ?? this.coverUrl,
      durationMs: durationMs ?? this.durationMs,
      raw: raw ?? this.raw,
      addedAt: addedAt ?? this.addedAt,
      sortOrder: sortOrder ?? this.sortOrder,
      versionPhysical: versionPhysical ?? this.versionPhysical,
      versionCounter: versionCounter ?? this.versionCounter,
      deviceId: deviceId ?? this.deviceId,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (playlistId.present) {
      map['playlistId'] = Variable<int>(playlistId.value);
    }
    if (sourceKey.present) {
      map['sourceKey'] = Variable<String>(sourceKey.value);
    }
    if (songId.present) {
      map['songId'] = Variable<String>(songId.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (artist.present) {
      map['artist'] = Variable<String>(artist.value);
    }
    if (album.present) {
      map['album'] = Variable<String>(album.value);
    }
    if (coverUrl.present) {
      map['coverUrl'] = Variable<String>(coverUrl.value);
    }
    if (durationMs.present) {
      map['durationMs'] = Variable<int>(durationMs.value);
    }
    if (raw.present) {
      map['raw'] = Variable<String>(raw.value);
    }
    if (addedAt.present) {
      map['addedAt'] = Variable<int>(addedAt.value);
    }
    if (sortOrder.present) {
      map['sortOrder'] = Variable<int>(sortOrder.value);
    }
    if (versionPhysical.present) {
      map['versionPhysical'] = Variable<int>(versionPhysical.value);
    }
    if (versionCounter.present) {
      map['versionCounter'] = Variable<int>(versionCounter.value);
    }
    if (deviceId.present) {
      map['deviceId'] = Variable<String>(deviceId.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PlaylistTracksCompanion(')
          ..write('id: $id, ')
          ..write('playlistId: $playlistId, ')
          ..write('sourceKey: $sourceKey, ')
          ..write('songId: $songId, ')
          ..write('title: $title, ')
          ..write('artist: $artist, ')
          ..write('album: $album, ')
          ..write('coverUrl: $coverUrl, ')
          ..write('durationMs: $durationMs, ')
          ..write('raw: $raw, ')
          ..write('addedAt: $addedAt, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('versionPhysical: $versionPhysical, ')
          ..write('versionCounter: $versionCounter, ')
          ..write('deviceId: $deviceId')
          ..write(')'))
        .toString();
  }
}

class $SyncTombstonesTable extends SyncTombstones
    with TableInfo<$SyncTombstonesTable, SyncTombstone> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncTombstonesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _categoryMeta =
      const VerificationMeta('category');
  @override
  late final GeneratedColumn<String> category = GeneratedColumn<String>(
      'category', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
      'key', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _versionPhysicalMeta =
      const VerificationMeta('versionPhysical');
  @override
  late final GeneratedColumn<int> versionPhysical = GeneratedColumn<int>(
      'versionPhysical', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _versionCounterMeta =
      const VerificationMeta('versionCounter');
  @override
  late final GeneratedColumn<int> versionCounter = GeneratedColumn<int>(
      'versionCounter', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _deviceIdMeta =
      const VerificationMeta('deviceId');
  @override
  late final GeneratedColumn<String> deviceId = GeneratedColumn<String>(
      'deviceId', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _deletedAtMeta =
      const VerificationMeta('deletedAt');
  @override
  late final GeneratedColumn<int> deletedAt = GeneratedColumn<int>(
      'deletedAt', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  @override
  List<GeneratedColumn> get $columns =>
      [category, key, versionPhysical, versionCounter, deviceId, deletedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_tombstones';
  @override
  VerificationContext validateIntegrity(Insertable<SyncTombstone> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('category')) {
      context.handle(_categoryMeta,
          category.isAcceptableOrUnknown(data['category']!, _categoryMeta));
    } else if (isInserting) {
      context.missing(_categoryMeta);
    }
    if (data.containsKey('key')) {
      context.handle(
          _keyMeta, key.isAcceptableOrUnknown(data['key']!, _keyMeta));
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('versionPhysical')) {
      context.handle(
          _versionPhysicalMeta,
          versionPhysical.isAcceptableOrUnknown(
              data['versionPhysical']!, _versionPhysicalMeta));
    } else if (isInserting) {
      context.missing(_versionPhysicalMeta);
    }
    if (data.containsKey('versionCounter')) {
      context.handle(
          _versionCounterMeta,
          versionCounter.isAcceptableOrUnknown(
              data['versionCounter']!, _versionCounterMeta));
    }
    if (data.containsKey('deviceId')) {
      context.handle(_deviceIdMeta,
          deviceId.isAcceptableOrUnknown(data['deviceId']!, _deviceIdMeta));
    }
    if (data.containsKey('deletedAt')) {
      context.handle(_deletedAtMeta,
          deletedAt.isAcceptableOrUnknown(data['deletedAt']!, _deletedAtMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {category, key};
  @override
  SyncTombstone map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SyncTombstone(
      category: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}category'])!,
      key: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}key'])!,
      versionPhysical: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}versionPhysical'])!,
      versionCounter: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}versionCounter'])!,
      deviceId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}deviceId'])!,
      deletedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}deletedAt'])!,
    );
  }

  @override
  $SyncTombstonesTable createAlias(String alias) {
    return $SyncTombstonesTable(attachedDatabase, alias);
  }
}

class SyncTombstone extends DataClass implements Insertable<SyncTombstone> {
  final String category;
  final String key;
  final int versionPhysical;
  final int versionCounter;
  final String deviceId;
  final int deletedAt;
  const SyncTombstone(
      {required this.category,
      required this.key,
      required this.versionPhysical,
      required this.versionCounter,
      required this.deviceId,
      required this.deletedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['category'] = Variable<String>(category);
    map['key'] = Variable<String>(key);
    map['versionPhysical'] = Variable<int>(versionPhysical);
    map['versionCounter'] = Variable<int>(versionCounter);
    map['deviceId'] = Variable<String>(deviceId);
    map['deletedAt'] = Variable<int>(deletedAt);
    return map;
  }

  SyncTombstonesCompanion toCompanion(bool nullToAbsent) {
    return SyncTombstonesCompanion(
      category: Value(category),
      key: Value(key),
      versionPhysical: Value(versionPhysical),
      versionCounter: Value(versionCounter),
      deviceId: Value(deviceId),
      deletedAt: Value(deletedAt),
    );
  }

  factory SyncTombstone.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SyncTombstone(
      category: serializer.fromJson<String>(json['category']),
      key: serializer.fromJson<String>(json['key']),
      versionPhysical: serializer.fromJson<int>(json['versionPhysical']),
      versionCounter: serializer.fromJson<int>(json['versionCounter']),
      deviceId: serializer.fromJson<String>(json['deviceId']),
      deletedAt: serializer.fromJson<int>(json['deletedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'category': serializer.toJson<String>(category),
      'key': serializer.toJson<String>(key),
      'versionPhysical': serializer.toJson<int>(versionPhysical),
      'versionCounter': serializer.toJson<int>(versionCounter),
      'deviceId': serializer.toJson<String>(deviceId),
      'deletedAt': serializer.toJson<int>(deletedAt),
    };
  }

  SyncTombstone copyWith(
          {String? category,
          String? key,
          int? versionPhysical,
          int? versionCounter,
          String? deviceId,
          int? deletedAt}) =>
      SyncTombstone(
        category: category ?? this.category,
        key: key ?? this.key,
        versionPhysical: versionPhysical ?? this.versionPhysical,
        versionCounter: versionCounter ?? this.versionCounter,
        deviceId: deviceId ?? this.deviceId,
        deletedAt: deletedAt ?? this.deletedAt,
      );
  SyncTombstone copyWithCompanion(SyncTombstonesCompanion data) {
    return SyncTombstone(
      category: data.category.present ? data.category.value : this.category,
      key: data.key.present ? data.key.value : this.key,
      versionPhysical: data.versionPhysical.present
          ? data.versionPhysical.value
          : this.versionPhysical,
      versionCounter: data.versionCounter.present
          ? data.versionCounter.value
          : this.versionCounter,
      deviceId: data.deviceId.present ? data.deviceId.value : this.deviceId,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SyncTombstone(')
          ..write('category: $category, ')
          ..write('key: $key, ')
          ..write('versionPhysical: $versionPhysical, ')
          ..write('versionCounter: $versionCounter, ')
          ..write('deviceId: $deviceId, ')
          ..write('deletedAt: $deletedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      category, key, versionPhysical, versionCounter, deviceId, deletedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncTombstone &&
          other.category == this.category &&
          other.key == this.key &&
          other.versionPhysical == this.versionPhysical &&
          other.versionCounter == this.versionCounter &&
          other.deviceId == this.deviceId &&
          other.deletedAt == this.deletedAt);
}

class SyncTombstonesCompanion extends UpdateCompanion<SyncTombstone> {
  final Value<String> category;
  final Value<String> key;
  final Value<int> versionPhysical;
  final Value<int> versionCounter;
  final Value<String> deviceId;
  final Value<int> deletedAt;
  final Value<int> rowid;
  const SyncTombstonesCompanion({
    this.category = const Value.absent(),
    this.key = const Value.absent(),
    this.versionPhysical = const Value.absent(),
    this.versionCounter = const Value.absent(),
    this.deviceId = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SyncTombstonesCompanion.insert({
    required String category,
    required String key,
    required int versionPhysical,
    this.versionCounter = const Value.absent(),
    this.deviceId = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : category = Value(category),
        key = Value(key),
        versionPhysical = Value(versionPhysical);
  static Insertable<SyncTombstone> custom({
    Expression<String>? category,
    Expression<String>? key,
    Expression<int>? versionPhysical,
    Expression<int>? versionCounter,
    Expression<String>? deviceId,
    Expression<int>? deletedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (category != null) 'category': category,
      if (key != null) 'key': key,
      if (versionPhysical != null) 'versionPhysical': versionPhysical,
      if (versionCounter != null) 'versionCounter': versionCounter,
      if (deviceId != null) 'deviceId': deviceId,
      if (deletedAt != null) 'deletedAt': deletedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SyncTombstonesCompanion copyWith(
      {Value<String>? category,
      Value<String>? key,
      Value<int>? versionPhysical,
      Value<int>? versionCounter,
      Value<String>? deviceId,
      Value<int>? deletedAt,
      Value<int>? rowid}) {
    return SyncTombstonesCompanion(
      category: category ?? this.category,
      key: key ?? this.key,
      versionPhysical: versionPhysical ?? this.versionPhysical,
      versionCounter: versionCounter ?? this.versionCounter,
      deviceId: deviceId ?? this.deviceId,
      deletedAt: deletedAt ?? this.deletedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (category.present) {
      map['category'] = Variable<String>(category.value);
    }
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (versionPhysical.present) {
      map['versionPhysical'] = Variable<int>(versionPhysical.value);
    }
    if (versionCounter.present) {
      map['versionCounter'] = Variable<int>(versionCounter.value);
    }
    if (deviceId.present) {
      map['deviceId'] = Variable<String>(deviceId.value);
    }
    if (deletedAt.present) {
      map['deletedAt'] = Variable<int>(deletedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncTombstonesCompanion(')
          ..write('category: $category, ')
          ..write('key: $key, ')
          ..write('versionPhysical: $versionPhysical, ')
          ..write('versionCounter: $versionCounter, ')
          ..write('deviceId: $deviceId, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SyncKnownTable extends SyncKnown
    with TableInfo<$SyncKnownTable, SyncKnownData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncKnownTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _categoryMeta =
      const VerificationMeta('category');
  @override
  late final GeneratedColumn<String> category = GeneratedColumn<String>(
      'category', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
      'key', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _versionPhysicalMeta =
      const VerificationMeta('versionPhysical');
  @override
  late final GeneratedColumn<int> versionPhysical = GeneratedColumn<int>(
      'versionPhysical', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _versionCounterMeta =
      const VerificationMeta('versionCounter');
  @override
  late final GeneratedColumn<int> versionCounter = GeneratedColumn<int>(
      'versionCounter', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _deviceIdMeta =
      const VerificationMeta('deviceId');
  @override
  late final GeneratedColumn<String> deviceId = GeneratedColumn<String>(
      'deviceId', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  @override
  List<GeneratedColumn> get $columns =>
      [category, key, versionPhysical, versionCounter, deviceId];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_known';
  @override
  VerificationContext validateIntegrity(Insertable<SyncKnownData> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('category')) {
      context.handle(_categoryMeta,
          category.isAcceptableOrUnknown(data['category']!, _categoryMeta));
    } else if (isInserting) {
      context.missing(_categoryMeta);
    }
    if (data.containsKey('key')) {
      context.handle(
          _keyMeta, key.isAcceptableOrUnknown(data['key']!, _keyMeta));
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('versionPhysical')) {
      context.handle(
          _versionPhysicalMeta,
          versionPhysical.isAcceptableOrUnknown(
              data['versionPhysical']!, _versionPhysicalMeta));
    } else if (isInserting) {
      context.missing(_versionPhysicalMeta);
    }
    if (data.containsKey('versionCounter')) {
      context.handle(
          _versionCounterMeta,
          versionCounter.isAcceptableOrUnknown(
              data['versionCounter']!, _versionCounterMeta));
    }
    if (data.containsKey('deviceId')) {
      context.handle(_deviceIdMeta,
          deviceId.isAcceptableOrUnknown(data['deviceId']!, _deviceIdMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {category, key};
  @override
  SyncKnownData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SyncKnownData(
      category: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}category'])!,
      key: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}key'])!,
      versionPhysical: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}versionPhysical'])!,
      versionCounter: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}versionCounter'])!,
      deviceId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}deviceId'])!,
    );
  }

  @override
  $SyncKnownTable createAlias(String alias) {
    return $SyncKnownTable(attachedDatabase, alias);
  }
}

class SyncKnownData extends DataClass implements Insertable<SyncKnownData> {
  final String category;
  final String key;
  final int versionPhysical;
  final int versionCounter;
  final String deviceId;
  const SyncKnownData(
      {required this.category,
      required this.key,
      required this.versionPhysical,
      required this.versionCounter,
      required this.deviceId});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['category'] = Variable<String>(category);
    map['key'] = Variable<String>(key);
    map['versionPhysical'] = Variable<int>(versionPhysical);
    map['versionCounter'] = Variable<int>(versionCounter);
    map['deviceId'] = Variable<String>(deviceId);
    return map;
  }

  SyncKnownCompanion toCompanion(bool nullToAbsent) {
    return SyncKnownCompanion(
      category: Value(category),
      key: Value(key),
      versionPhysical: Value(versionPhysical),
      versionCounter: Value(versionCounter),
      deviceId: Value(deviceId),
    );
  }

  factory SyncKnownData.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SyncKnownData(
      category: serializer.fromJson<String>(json['category']),
      key: serializer.fromJson<String>(json['key']),
      versionPhysical: serializer.fromJson<int>(json['versionPhysical']),
      versionCounter: serializer.fromJson<int>(json['versionCounter']),
      deviceId: serializer.fromJson<String>(json['deviceId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'category': serializer.toJson<String>(category),
      'key': serializer.toJson<String>(key),
      'versionPhysical': serializer.toJson<int>(versionPhysical),
      'versionCounter': serializer.toJson<int>(versionCounter),
      'deviceId': serializer.toJson<String>(deviceId),
    };
  }

  SyncKnownData copyWith(
          {String? category,
          String? key,
          int? versionPhysical,
          int? versionCounter,
          String? deviceId}) =>
      SyncKnownData(
        category: category ?? this.category,
        key: key ?? this.key,
        versionPhysical: versionPhysical ?? this.versionPhysical,
        versionCounter: versionCounter ?? this.versionCounter,
        deviceId: deviceId ?? this.deviceId,
      );
  SyncKnownData copyWithCompanion(SyncKnownCompanion data) {
    return SyncKnownData(
      category: data.category.present ? data.category.value : this.category,
      key: data.key.present ? data.key.value : this.key,
      versionPhysical: data.versionPhysical.present
          ? data.versionPhysical.value
          : this.versionPhysical,
      versionCounter: data.versionCounter.present
          ? data.versionCounter.value
          : this.versionCounter,
      deviceId: data.deviceId.present ? data.deviceId.value : this.deviceId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SyncKnownData(')
          ..write('category: $category, ')
          ..write('key: $key, ')
          ..write('versionPhysical: $versionPhysical, ')
          ..write('versionCounter: $versionCounter, ')
          ..write('deviceId: $deviceId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(category, key, versionPhysical, versionCounter, deviceId);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncKnownData &&
          other.category == this.category &&
          other.key == this.key &&
          other.versionPhysical == this.versionPhysical &&
          other.versionCounter == this.versionCounter &&
          other.deviceId == this.deviceId);
}

class SyncKnownCompanion extends UpdateCompanion<SyncKnownData> {
  final Value<String> category;
  final Value<String> key;
  final Value<int> versionPhysical;
  final Value<int> versionCounter;
  final Value<String> deviceId;
  final Value<int> rowid;
  const SyncKnownCompanion({
    this.category = const Value.absent(),
    this.key = const Value.absent(),
    this.versionPhysical = const Value.absent(),
    this.versionCounter = const Value.absent(),
    this.deviceId = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SyncKnownCompanion.insert({
    required String category,
    required String key,
    required int versionPhysical,
    this.versionCounter = const Value.absent(),
    this.deviceId = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : category = Value(category),
        key = Value(key),
        versionPhysical = Value(versionPhysical);
  static Insertable<SyncKnownData> custom({
    Expression<String>? category,
    Expression<String>? key,
    Expression<int>? versionPhysical,
    Expression<int>? versionCounter,
    Expression<String>? deviceId,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (category != null) 'category': category,
      if (key != null) 'key': key,
      if (versionPhysical != null) 'versionPhysical': versionPhysical,
      if (versionCounter != null) 'versionCounter': versionCounter,
      if (deviceId != null) 'deviceId': deviceId,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SyncKnownCompanion copyWith(
      {Value<String>? category,
      Value<String>? key,
      Value<int>? versionPhysical,
      Value<int>? versionCounter,
      Value<String>? deviceId,
      Value<int>? rowid}) {
    return SyncKnownCompanion(
      category: category ?? this.category,
      key: key ?? this.key,
      versionPhysical: versionPhysical ?? this.versionPhysical,
      versionCounter: versionCounter ?? this.versionCounter,
      deviceId: deviceId ?? this.deviceId,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (category.present) {
      map['category'] = Variable<String>(category.value);
    }
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (versionPhysical.present) {
      map['versionPhysical'] = Variable<int>(versionPhysical.value);
    }
    if (versionCounter.present) {
      map['versionCounter'] = Variable<int>(versionCounter.value);
    }
    if (deviceId.present) {
      map['deviceId'] = Variable<String>(deviceId.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncKnownCompanion(')
          ..write('category: $category, ')
          ..write('key: $key, ')
          ..write('versionPhysical: $versionPhysical, ')
          ..write('versionCounter: $versionCounter, ')
          ..write('deviceId: $deviceId, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SyncJournalTable extends SyncJournal
    with TableInfo<$SyncJournalTable, SyncJournalData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncJournalTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _seqMeta = const VerificationMeta('seq');
  @override
  late final GeneratedColumn<int> seq = GeneratedColumn<int>(
      'seq', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _categoryMeta =
      const VerificationMeta('category');
  @override
  late final GeneratedColumn<String> category = GeneratedColumn<String>(
      'category', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
      'key', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _versionPhysicalMeta =
      const VerificationMeta('versionPhysical');
  @override
  late final GeneratedColumn<int> versionPhysical = GeneratedColumn<int>(
      'versionPhysical', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _versionCounterMeta =
      const VerificationMeta('versionCounter');
  @override
  late final GeneratedColumn<int> versionCounter = GeneratedColumn<int>(
      'versionCounter', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _deviceIdMeta =
      const VerificationMeta('deviceId');
  @override
  late final GeneratedColumn<String> deviceId = GeneratedColumn<String>(
      'deviceId', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _deletedMeta =
      const VerificationMeta('deleted');
  @override
  late final GeneratedColumn<bool> deleted = GeneratedColumn<bool>(
      'deleted', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("deleted" IN (0, 1))'),
      defaultValue: const Constant(false));
  static const VerificationMeta _dataMeta = const VerificationMeta('data');
  @override
  late final GeneratedColumn<String> data = GeneratedColumn<String>(
      'data', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _atMeta = const VerificationMeta('at');
  @override
  late final GeneratedColumn<int> at = GeneratedColumn<int>(
      'at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [
        seq,
        category,
        key,
        versionPhysical,
        versionCounter,
        deviceId,
        deleted,
        data,
        at
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_journal';
  @override
  VerificationContext validateIntegrity(Insertable<SyncJournalData> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('seq')) {
      context.handle(
          _seqMeta, seq.isAcceptableOrUnknown(data['seq']!, _seqMeta));
    }
    if (data.containsKey('category')) {
      context.handle(_categoryMeta,
          category.isAcceptableOrUnknown(data['category']!, _categoryMeta));
    } else if (isInserting) {
      context.missing(_categoryMeta);
    }
    if (data.containsKey('key')) {
      context.handle(
          _keyMeta, key.isAcceptableOrUnknown(data['key']!, _keyMeta));
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('versionPhysical')) {
      context.handle(
          _versionPhysicalMeta,
          versionPhysical.isAcceptableOrUnknown(
              data['versionPhysical']!, _versionPhysicalMeta));
    } else if (isInserting) {
      context.missing(_versionPhysicalMeta);
    }
    if (data.containsKey('versionCounter')) {
      context.handle(
          _versionCounterMeta,
          versionCounter.isAcceptableOrUnknown(
              data['versionCounter']!, _versionCounterMeta));
    }
    if (data.containsKey('deviceId')) {
      context.handle(_deviceIdMeta,
          deviceId.isAcceptableOrUnknown(data['deviceId']!, _deviceIdMeta));
    }
    if (data.containsKey('deleted')) {
      context.handle(_deletedMeta,
          deleted.isAcceptableOrUnknown(data['deleted']!, _deletedMeta));
    }
    if (data.containsKey('data')) {
      context.handle(
          _dataMeta, this.data.isAcceptableOrUnknown(data['data']!, _dataMeta));
    }
    if (data.containsKey('at')) {
      context.handle(_atMeta, at.isAcceptableOrUnknown(data['at']!, _atMeta));
    } else if (isInserting) {
      context.missing(_atMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {seq};
  @override
  SyncJournalData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SyncJournalData(
      seq: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}seq'])!,
      category: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}category'])!,
      key: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}key'])!,
      versionPhysical: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}versionPhysical'])!,
      versionCounter: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}versionCounter'])!,
      deviceId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}deviceId'])!,
      deleted: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}deleted'])!,
      data: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}data']),
      at: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}at'])!,
    );
  }

  @override
  $SyncJournalTable createAlias(String alias) {
    return $SyncJournalTable(attachedDatabase, alias);
  }
}

class SyncJournalData extends DataClass implements Insertable<SyncJournalData> {
  final int seq;
  final String category;
  final String key;
  final int versionPhysical;
  final int versionCounter;
  final String deviceId;
  final bool deleted;
  final String? data;

  /// 追加时间（时间硬上限的判据；与 seq 同序推进）。
  final int at;
  const SyncJournalData(
      {required this.seq,
      required this.category,
      required this.key,
      required this.versionPhysical,
      required this.versionCounter,
      required this.deviceId,
      required this.deleted,
      this.data,
      required this.at});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['seq'] = Variable<int>(seq);
    map['category'] = Variable<String>(category);
    map['key'] = Variable<String>(key);
    map['versionPhysical'] = Variable<int>(versionPhysical);
    map['versionCounter'] = Variable<int>(versionCounter);
    map['deviceId'] = Variable<String>(deviceId);
    map['deleted'] = Variable<bool>(deleted);
    if (!nullToAbsent || data != null) {
      map['data'] = Variable<String>(data);
    }
    map['at'] = Variable<int>(at);
    return map;
  }

  SyncJournalCompanion toCompanion(bool nullToAbsent) {
    return SyncJournalCompanion(
      seq: Value(seq),
      category: Value(category),
      key: Value(key),
      versionPhysical: Value(versionPhysical),
      versionCounter: Value(versionCounter),
      deviceId: Value(deviceId),
      deleted: Value(deleted),
      data: data == null && nullToAbsent ? const Value.absent() : Value(data),
      at: Value(at),
    );
  }

  factory SyncJournalData.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SyncJournalData(
      seq: serializer.fromJson<int>(json['seq']),
      category: serializer.fromJson<String>(json['category']),
      key: serializer.fromJson<String>(json['key']),
      versionPhysical: serializer.fromJson<int>(json['versionPhysical']),
      versionCounter: serializer.fromJson<int>(json['versionCounter']),
      deviceId: serializer.fromJson<String>(json['deviceId']),
      deleted: serializer.fromJson<bool>(json['deleted']),
      data: serializer.fromJson<String?>(json['data']),
      at: serializer.fromJson<int>(json['at']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'seq': serializer.toJson<int>(seq),
      'category': serializer.toJson<String>(category),
      'key': serializer.toJson<String>(key),
      'versionPhysical': serializer.toJson<int>(versionPhysical),
      'versionCounter': serializer.toJson<int>(versionCounter),
      'deviceId': serializer.toJson<String>(deviceId),
      'deleted': serializer.toJson<bool>(deleted),
      'data': serializer.toJson<String?>(data),
      'at': serializer.toJson<int>(at),
    };
  }

  SyncJournalData copyWith(
          {int? seq,
          String? category,
          String? key,
          int? versionPhysical,
          int? versionCounter,
          String? deviceId,
          bool? deleted,
          Value<String?> data = const Value.absent(),
          int? at}) =>
      SyncJournalData(
        seq: seq ?? this.seq,
        category: category ?? this.category,
        key: key ?? this.key,
        versionPhysical: versionPhysical ?? this.versionPhysical,
        versionCounter: versionCounter ?? this.versionCounter,
        deviceId: deviceId ?? this.deviceId,
        deleted: deleted ?? this.deleted,
        data: data.present ? data.value : this.data,
        at: at ?? this.at,
      );
  SyncJournalData copyWithCompanion(SyncJournalCompanion data) {
    return SyncJournalData(
      seq: data.seq.present ? data.seq.value : this.seq,
      category: data.category.present ? data.category.value : this.category,
      key: data.key.present ? data.key.value : this.key,
      versionPhysical: data.versionPhysical.present
          ? data.versionPhysical.value
          : this.versionPhysical,
      versionCounter: data.versionCounter.present
          ? data.versionCounter.value
          : this.versionCounter,
      deviceId: data.deviceId.present ? data.deviceId.value : this.deviceId,
      deleted: data.deleted.present ? data.deleted.value : this.deleted,
      data: data.data.present ? data.data.value : this.data,
      at: data.at.present ? data.at.value : this.at,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SyncJournalData(')
          ..write('seq: $seq, ')
          ..write('category: $category, ')
          ..write('key: $key, ')
          ..write('versionPhysical: $versionPhysical, ')
          ..write('versionCounter: $versionCounter, ')
          ..write('deviceId: $deviceId, ')
          ..write('deleted: $deleted, ')
          ..write('data: $data, ')
          ..write('at: $at')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(seq, category, key, versionPhysical,
      versionCounter, deviceId, deleted, data, at);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncJournalData &&
          other.seq == this.seq &&
          other.category == this.category &&
          other.key == this.key &&
          other.versionPhysical == this.versionPhysical &&
          other.versionCounter == this.versionCounter &&
          other.deviceId == this.deviceId &&
          other.deleted == this.deleted &&
          other.data == this.data &&
          other.at == this.at);
}

class SyncJournalCompanion extends UpdateCompanion<SyncJournalData> {
  final Value<int> seq;
  final Value<String> category;
  final Value<String> key;
  final Value<int> versionPhysical;
  final Value<int> versionCounter;
  final Value<String> deviceId;
  final Value<bool> deleted;
  final Value<String?> data;
  final Value<int> at;
  const SyncJournalCompanion({
    this.seq = const Value.absent(),
    this.category = const Value.absent(),
    this.key = const Value.absent(),
    this.versionPhysical = const Value.absent(),
    this.versionCounter = const Value.absent(),
    this.deviceId = const Value.absent(),
    this.deleted = const Value.absent(),
    this.data = const Value.absent(),
    this.at = const Value.absent(),
  });
  SyncJournalCompanion.insert({
    this.seq = const Value.absent(),
    required String category,
    required String key,
    required int versionPhysical,
    this.versionCounter = const Value.absent(),
    this.deviceId = const Value.absent(),
    this.deleted = const Value.absent(),
    this.data = const Value.absent(),
    required int at,
  })  : category = Value(category),
        key = Value(key),
        versionPhysical = Value(versionPhysical),
        at = Value(at);
  static Insertable<SyncJournalData> custom({
    Expression<int>? seq,
    Expression<String>? category,
    Expression<String>? key,
    Expression<int>? versionPhysical,
    Expression<int>? versionCounter,
    Expression<String>? deviceId,
    Expression<bool>? deleted,
    Expression<String>? data,
    Expression<int>? at,
  }) {
    return RawValuesInsertable({
      if (seq != null) 'seq': seq,
      if (category != null) 'category': category,
      if (key != null) 'key': key,
      if (versionPhysical != null) 'versionPhysical': versionPhysical,
      if (versionCounter != null) 'versionCounter': versionCounter,
      if (deviceId != null) 'deviceId': deviceId,
      if (deleted != null) 'deleted': deleted,
      if (data != null) 'data': data,
      if (at != null) 'at': at,
    });
  }

  SyncJournalCompanion copyWith(
      {Value<int>? seq,
      Value<String>? category,
      Value<String>? key,
      Value<int>? versionPhysical,
      Value<int>? versionCounter,
      Value<String>? deviceId,
      Value<bool>? deleted,
      Value<String?>? data,
      Value<int>? at}) {
    return SyncJournalCompanion(
      seq: seq ?? this.seq,
      category: category ?? this.category,
      key: key ?? this.key,
      versionPhysical: versionPhysical ?? this.versionPhysical,
      versionCounter: versionCounter ?? this.versionCounter,
      deviceId: deviceId ?? this.deviceId,
      deleted: deleted ?? this.deleted,
      data: data ?? this.data,
      at: at ?? this.at,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (seq.present) {
      map['seq'] = Variable<int>(seq.value);
    }
    if (category.present) {
      map['category'] = Variable<String>(category.value);
    }
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (versionPhysical.present) {
      map['versionPhysical'] = Variable<int>(versionPhysical.value);
    }
    if (versionCounter.present) {
      map['versionCounter'] = Variable<int>(versionCounter.value);
    }
    if (deviceId.present) {
      map['deviceId'] = Variable<String>(deviceId.value);
    }
    if (deleted.present) {
      map['deleted'] = Variable<bool>(deleted.value);
    }
    if (data.present) {
      map['data'] = Variable<String>(data.value);
    }
    if (at.present) {
      map['at'] = Variable<int>(at.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncJournalCompanion(')
          ..write('seq: $seq, ')
          ..write('category: $category, ')
          ..write('key: $key, ')
          ..write('versionPhysical: $versionPhysical, ')
          ..write('versionCounter: $versionCounter, ')
          ..write('deviceId: $deviceId, ')
          ..write('deleted: $deleted, ')
          ..write('data: $data, ')
          ..write('at: $at')
          ..write(')'))
        .toString();
  }
}

class $SyncJournalStatesTable extends SyncJournalStates
    with TableInfo<$SyncJournalStatesTable, SyncJournalState> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncJournalStatesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _baseSeqMeta =
      const VerificationMeta('baseSeq');
  @override
  late final GeneratedColumn<int> baseSeq = GeneratedColumn<int>(
      'baseSeq', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _snapshotSeqMeta =
      const VerificationMeta('snapshotSeq');
  @override
  late final GeneratedColumn<int> snapshotSeq = GeneratedColumn<int>(
      'snapshotSeq', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(-1));
  @override
  List<GeneratedColumn> get $columns => [id, baseSeq, snapshotSeq];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_journal_state';
  @override
  VerificationContext validateIntegrity(Insertable<SyncJournalState> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('baseSeq')) {
      context.handle(_baseSeqMeta,
          baseSeq.isAcceptableOrUnknown(data['baseSeq']!, _baseSeqMeta));
    }
    if (data.containsKey('snapshotSeq')) {
      context.handle(
          _snapshotSeqMeta,
          snapshotSeq.isAcceptableOrUnknown(
              data['snapshotSeq']!, _snapshotSeqMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  SyncJournalState map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SyncJournalState(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      baseSeq: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}baseSeq'])!,
      snapshotSeq: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}snapshotSeq'])!,
    );
  }

  @override
  $SyncJournalStatesTable createAlias(String alias) {
    return $SyncJournalStatesTable(attachedDatabase, alias);
  }
}

class SyncJournalState extends DataClass
    implements Insertable<SyncJournalState> {
  final int id;
  final int baseSeq;
  final int snapshotSeq;
  const SyncJournalState(
      {required this.id, required this.baseSeq, required this.snapshotSeq});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['baseSeq'] = Variable<int>(baseSeq);
    map['snapshotSeq'] = Variable<int>(snapshotSeq);
    return map;
  }

  SyncJournalStatesCompanion toCompanion(bool nullToAbsent) {
    return SyncJournalStatesCompanion(
      id: Value(id),
      baseSeq: Value(baseSeq),
      snapshotSeq: Value(snapshotSeq),
    );
  }

  factory SyncJournalState.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SyncJournalState(
      id: serializer.fromJson<int>(json['id']),
      baseSeq: serializer.fromJson<int>(json['baseSeq']),
      snapshotSeq: serializer.fromJson<int>(json['snapshotSeq']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'baseSeq': serializer.toJson<int>(baseSeq),
      'snapshotSeq': serializer.toJson<int>(snapshotSeq),
    };
  }

  SyncJournalState copyWith({int? id, int? baseSeq, int? snapshotSeq}) =>
      SyncJournalState(
        id: id ?? this.id,
        baseSeq: baseSeq ?? this.baseSeq,
        snapshotSeq: snapshotSeq ?? this.snapshotSeq,
      );
  SyncJournalState copyWithCompanion(SyncJournalStatesCompanion data) {
    return SyncJournalState(
      id: data.id.present ? data.id.value : this.id,
      baseSeq: data.baseSeq.present ? data.baseSeq.value : this.baseSeq,
      snapshotSeq:
          data.snapshotSeq.present ? data.snapshotSeq.value : this.snapshotSeq,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SyncJournalState(')
          ..write('id: $id, ')
          ..write('baseSeq: $baseSeq, ')
          ..write('snapshotSeq: $snapshotSeq')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, baseSeq, snapshotSeq);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncJournalState &&
          other.id == this.id &&
          other.baseSeq == this.baseSeq &&
          other.snapshotSeq == this.snapshotSeq);
}

class SyncJournalStatesCompanion extends UpdateCompanion<SyncJournalState> {
  final Value<int> id;
  final Value<int> baseSeq;
  final Value<int> snapshotSeq;
  const SyncJournalStatesCompanion({
    this.id = const Value.absent(),
    this.baseSeq = const Value.absent(),
    this.snapshotSeq = const Value.absent(),
  });
  SyncJournalStatesCompanion.insert({
    this.id = const Value.absent(),
    this.baseSeq = const Value.absent(),
    this.snapshotSeq = const Value.absent(),
  });
  static Insertable<SyncJournalState> custom({
    Expression<int>? id,
    Expression<int>? baseSeq,
    Expression<int>? snapshotSeq,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (baseSeq != null) 'baseSeq': baseSeq,
      if (snapshotSeq != null) 'snapshotSeq': snapshotSeq,
    });
  }

  SyncJournalStatesCompanion copyWith(
      {Value<int>? id, Value<int>? baseSeq, Value<int>? snapshotSeq}) {
    return SyncJournalStatesCompanion(
      id: id ?? this.id,
      baseSeq: baseSeq ?? this.baseSeq,
      snapshotSeq: snapshotSeq ?? this.snapshotSeq,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (baseSeq.present) {
      map['baseSeq'] = Variable<int>(baseSeq.value);
    }
    if (snapshotSeq.present) {
      map['snapshotSeq'] = Variable<int>(snapshotSeq.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncJournalStatesCompanion(')
          ..write('id: $id, ')
          ..write('baseSeq: $baseSeq, ')
          ..write('snapshotSeq: $snapshotSeq')
          ..write(')'))
        .toString();
  }
}

class $PlayEventsTable extends PlayEvents
    with TableInfo<$PlayEventsTable, PlayEventRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PlayEventsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _sourceKeyMeta =
      const VerificationMeta('sourceKey');
  @override
  late final GeneratedColumn<String> sourceKey = GeneratedColumn<String>(
      'sourceKey', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _songIdMeta = const VerificationMeta('songId');
  @override
  late final GeneratedColumn<String> songId = GeneratedColumn<String>(
      'songId', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
      'title', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _artistMeta = const VerificationMeta('artist');
  @override
  late final GeneratedColumn<String> artist = GeneratedColumn<String>(
      'artist', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _albumMeta = const VerificationMeta('album');
  @override
  late final GeneratedColumn<String> album = GeneratedColumn<String>(
      'album', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _coverUrlMeta =
      const VerificationMeta('coverUrl');
  @override
  late final GeneratedColumn<String> coverUrl = GeneratedColumn<String>(
      'coverUrl', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _durationMsMeta =
      const VerificationMeta('durationMs');
  @override
  late final GeneratedColumn<int> durationMs = GeneratedColumn<int>(
      'durationMs', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _rawMeta = const VerificationMeta('raw');
  @override
  late final GeneratedColumn<String> raw = GeneratedColumn<String>(
      'raw', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('{}'));
  static const VerificationMeta _startedAtMeta =
      const VerificationMeta('startedAt');
  @override
  late final GeneratedColumn<int> startedAt = GeneratedColumn<int>(
      'startedAt', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _endedAtMeta =
      const VerificationMeta('endedAt');
  @override
  late final GeneratedColumn<int> endedAt = GeneratedColumn<int>(
      'endedAt', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _listenedMsMeta =
      const VerificationMeta('listenedMs');
  @override
  late final GeneratedColumn<int> listenedMs = GeneratedColumn<int>(
      'listenedMs', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _maxPositionMsMeta =
      const VerificationMeta('maxPositionMs');
  @override
  late final GeneratedColumn<int> maxPositionMs = GeneratedColumn<int>(
      'maxPositionMs', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _endReasonMeta =
      const VerificationMeta('endReason');
  @override
  late final GeneratedColumn<String> endReason = GeneratedColumn<String>(
      'endReason', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _syncKeyMeta =
      const VerificationMeta('syncKey');
  @override
  late final GeneratedColumn<String> syncKey = GeneratedColumn<String>(
      'syncKey', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _originDeviceIdMeta =
      const VerificationMeta('originDeviceId');
  @override
  late final GeneratedColumn<String> originDeviceId = GeneratedColumn<String>(
      'originDeviceId', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _versionPhysicalMeta =
      const VerificationMeta('versionPhysical');
  @override
  late final GeneratedColumn<int> versionPhysical = GeneratedColumn<int>(
      'versionPhysical', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _versionCounterMeta =
      const VerificationMeta('versionCounter');
  @override
  late final GeneratedColumn<int> versionCounter = GeneratedColumn<int>(
      'versionCounter', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  @override
  List<GeneratedColumn> get $columns => [
        id,
        sourceKey,
        songId,
        title,
        artist,
        album,
        coverUrl,
        durationMs,
        raw,
        startedAt,
        endedAt,
        listenedMs,
        maxPositionMs,
        endReason,
        syncKey,
        originDeviceId,
        versionPhysical,
        versionCounter
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'play_events';
  @override
  VerificationContext validateIntegrity(Insertable<PlayEventRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('sourceKey')) {
      context.handle(_sourceKeyMeta,
          sourceKey.isAcceptableOrUnknown(data['sourceKey']!, _sourceKeyMeta));
    } else if (isInserting) {
      context.missing(_sourceKeyMeta);
    }
    if (data.containsKey('songId')) {
      context.handle(_songIdMeta,
          songId.isAcceptableOrUnknown(data['songId']!, _songIdMeta));
    } else if (isInserting) {
      context.missing(_songIdMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
          _titleMeta, title.isAcceptableOrUnknown(data['title']!, _titleMeta));
    }
    if (data.containsKey('artist')) {
      context.handle(_artistMeta,
          artist.isAcceptableOrUnknown(data['artist']!, _artistMeta));
    }
    if (data.containsKey('album')) {
      context.handle(
          _albumMeta, album.isAcceptableOrUnknown(data['album']!, _albumMeta));
    }
    if (data.containsKey('coverUrl')) {
      context.handle(_coverUrlMeta,
          coverUrl.isAcceptableOrUnknown(data['coverUrl']!, _coverUrlMeta));
    }
    if (data.containsKey('durationMs')) {
      context.handle(
          _durationMsMeta,
          durationMs.isAcceptableOrUnknown(
              data['durationMs']!, _durationMsMeta));
    }
    if (data.containsKey('raw')) {
      context.handle(
          _rawMeta, raw.isAcceptableOrUnknown(data['raw']!, _rawMeta));
    }
    if (data.containsKey('startedAt')) {
      context.handle(_startedAtMeta,
          startedAt.isAcceptableOrUnknown(data['startedAt']!, _startedAtMeta));
    } else if (isInserting) {
      context.missing(_startedAtMeta);
    }
    if (data.containsKey('endedAt')) {
      context.handle(_endedAtMeta,
          endedAt.isAcceptableOrUnknown(data['endedAt']!, _endedAtMeta));
    }
    if (data.containsKey('listenedMs')) {
      context.handle(
          _listenedMsMeta,
          listenedMs.isAcceptableOrUnknown(
              data['listenedMs']!, _listenedMsMeta));
    }
    if (data.containsKey('maxPositionMs')) {
      context.handle(
          _maxPositionMsMeta,
          maxPositionMs.isAcceptableOrUnknown(
              data['maxPositionMs']!, _maxPositionMsMeta));
    }
    if (data.containsKey('endReason')) {
      context.handle(_endReasonMeta,
          endReason.isAcceptableOrUnknown(data['endReason']!, _endReasonMeta));
    }
    if (data.containsKey('syncKey')) {
      context.handle(_syncKeyMeta,
          syncKey.isAcceptableOrUnknown(data['syncKey']!, _syncKeyMeta));
    }
    if (data.containsKey('originDeviceId')) {
      context.handle(
          _originDeviceIdMeta,
          originDeviceId.isAcceptableOrUnknown(
              data['originDeviceId']!, _originDeviceIdMeta));
    }
    if (data.containsKey('versionPhysical')) {
      context.handle(
          _versionPhysicalMeta,
          versionPhysical.isAcceptableOrUnknown(
              data['versionPhysical']!, _versionPhysicalMeta));
    }
    if (data.containsKey('versionCounter')) {
      context.handle(
          _versionCounterMeta,
          versionCounter.isAcceptableOrUnknown(
              data['versionCounter']!, _versionCounterMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  PlayEventRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PlayEventRow(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      sourceKey: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}sourceKey'])!,
      songId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}songId'])!,
      title: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}title'])!,
      artist: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}artist'])!,
      album: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}album'])!,
      coverUrl: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}coverUrl']),
      durationMs: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}durationMs']),
      raw: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}raw'])!,
      startedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}startedAt'])!,
      endedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}endedAt']),
      listenedMs: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}listenedMs'])!,
      maxPositionMs: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}maxPositionMs'])!,
      endReason: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}endReason']),
      syncKey: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}syncKey']),
      originDeviceId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}originDeviceId'])!,
      versionPhysical: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}versionPhysical'])!,
      versionCounter: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}versionCounter'])!,
    );
  }

  @override
  $PlayEventsTable createAlias(String alias) {
    return $PlayEventsTable(attachedDatabase, alias);
  }
}

class PlayEventRow extends DataClass implements Insertable<PlayEventRow> {
  final int id;
  final String sourceKey;
  final String songId;
  final String title;
  final String artist;
  final String album;
  final String? coverUrl;
  final int? durationMs;
  final String raw;
  final int startedAt;
  final int? endedAt;
  final int listenedMs;
  final int maxPositionMs;
  final String? endReason;
  final String? syncKey;
  final String originDeviceId;
  final int versionPhysical;
  final int versionCounter;
  const PlayEventRow(
      {required this.id,
      required this.sourceKey,
      required this.songId,
      required this.title,
      required this.artist,
      required this.album,
      this.coverUrl,
      this.durationMs,
      required this.raw,
      required this.startedAt,
      this.endedAt,
      required this.listenedMs,
      required this.maxPositionMs,
      this.endReason,
      this.syncKey,
      required this.originDeviceId,
      required this.versionPhysical,
      required this.versionCounter});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['sourceKey'] = Variable<String>(sourceKey);
    map['songId'] = Variable<String>(songId);
    map['title'] = Variable<String>(title);
    map['artist'] = Variable<String>(artist);
    map['album'] = Variable<String>(album);
    if (!nullToAbsent || coverUrl != null) {
      map['coverUrl'] = Variable<String>(coverUrl);
    }
    if (!nullToAbsent || durationMs != null) {
      map['durationMs'] = Variable<int>(durationMs);
    }
    map['raw'] = Variable<String>(raw);
    map['startedAt'] = Variable<int>(startedAt);
    if (!nullToAbsent || endedAt != null) {
      map['endedAt'] = Variable<int>(endedAt);
    }
    map['listenedMs'] = Variable<int>(listenedMs);
    map['maxPositionMs'] = Variable<int>(maxPositionMs);
    if (!nullToAbsent || endReason != null) {
      map['endReason'] = Variable<String>(endReason);
    }
    if (!nullToAbsent || syncKey != null) {
      map['syncKey'] = Variable<String>(syncKey);
    }
    map['originDeviceId'] = Variable<String>(originDeviceId);
    map['versionPhysical'] = Variable<int>(versionPhysical);
    map['versionCounter'] = Variable<int>(versionCounter);
    return map;
  }

  PlayEventsCompanion toCompanion(bool nullToAbsent) {
    return PlayEventsCompanion(
      id: Value(id),
      sourceKey: Value(sourceKey),
      songId: Value(songId),
      title: Value(title),
      artist: Value(artist),
      album: Value(album),
      coverUrl: coverUrl == null && nullToAbsent
          ? const Value.absent()
          : Value(coverUrl),
      durationMs: durationMs == null && nullToAbsent
          ? const Value.absent()
          : Value(durationMs),
      raw: Value(raw),
      startedAt: Value(startedAt),
      endedAt: endedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(endedAt),
      listenedMs: Value(listenedMs),
      maxPositionMs: Value(maxPositionMs),
      endReason: endReason == null && nullToAbsent
          ? const Value.absent()
          : Value(endReason),
      syncKey: syncKey == null && nullToAbsent
          ? const Value.absent()
          : Value(syncKey),
      originDeviceId: Value(originDeviceId),
      versionPhysical: Value(versionPhysical),
      versionCounter: Value(versionCounter),
    );
  }

  factory PlayEventRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PlayEventRow(
      id: serializer.fromJson<int>(json['id']),
      sourceKey: serializer.fromJson<String>(json['sourceKey']),
      songId: serializer.fromJson<String>(json['songId']),
      title: serializer.fromJson<String>(json['title']),
      artist: serializer.fromJson<String>(json['artist']),
      album: serializer.fromJson<String>(json['album']),
      coverUrl: serializer.fromJson<String?>(json['coverUrl']),
      durationMs: serializer.fromJson<int?>(json['durationMs']),
      raw: serializer.fromJson<String>(json['raw']),
      startedAt: serializer.fromJson<int>(json['startedAt']),
      endedAt: serializer.fromJson<int?>(json['endedAt']),
      listenedMs: serializer.fromJson<int>(json['listenedMs']),
      maxPositionMs: serializer.fromJson<int>(json['maxPositionMs']),
      endReason: serializer.fromJson<String?>(json['endReason']),
      syncKey: serializer.fromJson<String?>(json['syncKey']),
      originDeviceId: serializer.fromJson<String>(json['originDeviceId']),
      versionPhysical: serializer.fromJson<int>(json['versionPhysical']),
      versionCounter: serializer.fromJson<int>(json['versionCounter']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'sourceKey': serializer.toJson<String>(sourceKey),
      'songId': serializer.toJson<String>(songId),
      'title': serializer.toJson<String>(title),
      'artist': serializer.toJson<String>(artist),
      'album': serializer.toJson<String>(album),
      'coverUrl': serializer.toJson<String?>(coverUrl),
      'durationMs': serializer.toJson<int?>(durationMs),
      'raw': serializer.toJson<String>(raw),
      'startedAt': serializer.toJson<int>(startedAt),
      'endedAt': serializer.toJson<int?>(endedAt),
      'listenedMs': serializer.toJson<int>(listenedMs),
      'maxPositionMs': serializer.toJson<int>(maxPositionMs),
      'endReason': serializer.toJson<String?>(endReason),
      'syncKey': serializer.toJson<String?>(syncKey),
      'originDeviceId': serializer.toJson<String>(originDeviceId),
      'versionPhysical': serializer.toJson<int>(versionPhysical),
      'versionCounter': serializer.toJson<int>(versionCounter),
    };
  }

  PlayEventRow copyWith(
          {int? id,
          String? sourceKey,
          String? songId,
          String? title,
          String? artist,
          String? album,
          Value<String?> coverUrl = const Value.absent(),
          Value<int?> durationMs = const Value.absent(),
          String? raw,
          int? startedAt,
          Value<int?> endedAt = const Value.absent(),
          int? listenedMs,
          int? maxPositionMs,
          Value<String?> endReason = const Value.absent(),
          Value<String?> syncKey = const Value.absent(),
          String? originDeviceId,
          int? versionPhysical,
          int? versionCounter}) =>
      PlayEventRow(
        id: id ?? this.id,
        sourceKey: sourceKey ?? this.sourceKey,
        songId: songId ?? this.songId,
        title: title ?? this.title,
        artist: artist ?? this.artist,
        album: album ?? this.album,
        coverUrl: coverUrl.present ? coverUrl.value : this.coverUrl,
        durationMs: durationMs.present ? durationMs.value : this.durationMs,
        raw: raw ?? this.raw,
        startedAt: startedAt ?? this.startedAt,
        endedAt: endedAt.present ? endedAt.value : this.endedAt,
        listenedMs: listenedMs ?? this.listenedMs,
        maxPositionMs: maxPositionMs ?? this.maxPositionMs,
        endReason: endReason.present ? endReason.value : this.endReason,
        syncKey: syncKey.present ? syncKey.value : this.syncKey,
        originDeviceId: originDeviceId ?? this.originDeviceId,
        versionPhysical: versionPhysical ?? this.versionPhysical,
        versionCounter: versionCounter ?? this.versionCounter,
      );
  PlayEventRow copyWithCompanion(PlayEventsCompanion data) {
    return PlayEventRow(
      id: data.id.present ? data.id.value : this.id,
      sourceKey: data.sourceKey.present ? data.sourceKey.value : this.sourceKey,
      songId: data.songId.present ? data.songId.value : this.songId,
      title: data.title.present ? data.title.value : this.title,
      artist: data.artist.present ? data.artist.value : this.artist,
      album: data.album.present ? data.album.value : this.album,
      coverUrl: data.coverUrl.present ? data.coverUrl.value : this.coverUrl,
      durationMs:
          data.durationMs.present ? data.durationMs.value : this.durationMs,
      raw: data.raw.present ? data.raw.value : this.raw,
      startedAt: data.startedAt.present ? data.startedAt.value : this.startedAt,
      endedAt: data.endedAt.present ? data.endedAt.value : this.endedAt,
      listenedMs:
          data.listenedMs.present ? data.listenedMs.value : this.listenedMs,
      maxPositionMs: data.maxPositionMs.present
          ? data.maxPositionMs.value
          : this.maxPositionMs,
      endReason: data.endReason.present ? data.endReason.value : this.endReason,
      syncKey: data.syncKey.present ? data.syncKey.value : this.syncKey,
      originDeviceId: data.originDeviceId.present
          ? data.originDeviceId.value
          : this.originDeviceId,
      versionPhysical: data.versionPhysical.present
          ? data.versionPhysical.value
          : this.versionPhysical,
      versionCounter: data.versionCounter.present
          ? data.versionCounter.value
          : this.versionCounter,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PlayEventRow(')
          ..write('id: $id, ')
          ..write('sourceKey: $sourceKey, ')
          ..write('songId: $songId, ')
          ..write('title: $title, ')
          ..write('artist: $artist, ')
          ..write('album: $album, ')
          ..write('coverUrl: $coverUrl, ')
          ..write('durationMs: $durationMs, ')
          ..write('raw: $raw, ')
          ..write('startedAt: $startedAt, ')
          ..write('endedAt: $endedAt, ')
          ..write('listenedMs: $listenedMs, ')
          ..write('maxPositionMs: $maxPositionMs, ')
          ..write('endReason: $endReason, ')
          ..write('syncKey: $syncKey, ')
          ..write('originDeviceId: $originDeviceId, ')
          ..write('versionPhysical: $versionPhysical, ')
          ..write('versionCounter: $versionCounter')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id,
      sourceKey,
      songId,
      title,
      artist,
      album,
      coverUrl,
      durationMs,
      raw,
      startedAt,
      endedAt,
      listenedMs,
      maxPositionMs,
      endReason,
      syncKey,
      originDeviceId,
      versionPhysical,
      versionCounter);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PlayEventRow &&
          other.id == this.id &&
          other.sourceKey == this.sourceKey &&
          other.songId == this.songId &&
          other.title == this.title &&
          other.artist == this.artist &&
          other.album == this.album &&
          other.coverUrl == this.coverUrl &&
          other.durationMs == this.durationMs &&
          other.raw == this.raw &&
          other.startedAt == this.startedAt &&
          other.endedAt == this.endedAt &&
          other.listenedMs == this.listenedMs &&
          other.maxPositionMs == this.maxPositionMs &&
          other.endReason == this.endReason &&
          other.syncKey == this.syncKey &&
          other.originDeviceId == this.originDeviceId &&
          other.versionPhysical == this.versionPhysical &&
          other.versionCounter == this.versionCounter);
}

class PlayEventsCompanion extends UpdateCompanion<PlayEventRow> {
  final Value<int> id;
  final Value<String> sourceKey;
  final Value<String> songId;
  final Value<String> title;
  final Value<String> artist;
  final Value<String> album;
  final Value<String?> coverUrl;
  final Value<int?> durationMs;
  final Value<String> raw;
  final Value<int> startedAt;
  final Value<int?> endedAt;
  final Value<int> listenedMs;
  final Value<int> maxPositionMs;
  final Value<String?> endReason;
  final Value<String?> syncKey;
  final Value<String> originDeviceId;
  final Value<int> versionPhysical;
  final Value<int> versionCounter;
  const PlayEventsCompanion({
    this.id = const Value.absent(),
    this.sourceKey = const Value.absent(),
    this.songId = const Value.absent(),
    this.title = const Value.absent(),
    this.artist = const Value.absent(),
    this.album = const Value.absent(),
    this.coverUrl = const Value.absent(),
    this.durationMs = const Value.absent(),
    this.raw = const Value.absent(),
    this.startedAt = const Value.absent(),
    this.endedAt = const Value.absent(),
    this.listenedMs = const Value.absent(),
    this.maxPositionMs = const Value.absent(),
    this.endReason = const Value.absent(),
    this.syncKey = const Value.absent(),
    this.originDeviceId = const Value.absent(),
    this.versionPhysical = const Value.absent(),
    this.versionCounter = const Value.absent(),
  });
  PlayEventsCompanion.insert({
    this.id = const Value.absent(),
    required String sourceKey,
    required String songId,
    this.title = const Value.absent(),
    this.artist = const Value.absent(),
    this.album = const Value.absent(),
    this.coverUrl = const Value.absent(),
    this.durationMs = const Value.absent(),
    this.raw = const Value.absent(),
    required int startedAt,
    this.endedAt = const Value.absent(),
    this.listenedMs = const Value.absent(),
    this.maxPositionMs = const Value.absent(),
    this.endReason = const Value.absent(),
    this.syncKey = const Value.absent(),
    this.originDeviceId = const Value.absent(),
    this.versionPhysical = const Value.absent(),
    this.versionCounter = const Value.absent(),
  })  : sourceKey = Value(sourceKey),
        songId = Value(songId),
        startedAt = Value(startedAt);
  static Insertable<PlayEventRow> custom({
    Expression<int>? id,
    Expression<String>? sourceKey,
    Expression<String>? songId,
    Expression<String>? title,
    Expression<String>? artist,
    Expression<String>? album,
    Expression<String>? coverUrl,
    Expression<int>? durationMs,
    Expression<String>? raw,
    Expression<int>? startedAt,
    Expression<int>? endedAt,
    Expression<int>? listenedMs,
    Expression<int>? maxPositionMs,
    Expression<String>? endReason,
    Expression<String>? syncKey,
    Expression<String>? originDeviceId,
    Expression<int>? versionPhysical,
    Expression<int>? versionCounter,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (sourceKey != null) 'sourceKey': sourceKey,
      if (songId != null) 'songId': songId,
      if (title != null) 'title': title,
      if (artist != null) 'artist': artist,
      if (album != null) 'album': album,
      if (coverUrl != null) 'coverUrl': coverUrl,
      if (durationMs != null) 'durationMs': durationMs,
      if (raw != null) 'raw': raw,
      if (startedAt != null) 'startedAt': startedAt,
      if (endedAt != null) 'endedAt': endedAt,
      if (listenedMs != null) 'listenedMs': listenedMs,
      if (maxPositionMs != null) 'maxPositionMs': maxPositionMs,
      if (endReason != null) 'endReason': endReason,
      if (syncKey != null) 'syncKey': syncKey,
      if (originDeviceId != null) 'originDeviceId': originDeviceId,
      if (versionPhysical != null) 'versionPhysical': versionPhysical,
      if (versionCounter != null) 'versionCounter': versionCounter,
    });
  }

  PlayEventsCompanion copyWith(
      {Value<int>? id,
      Value<String>? sourceKey,
      Value<String>? songId,
      Value<String>? title,
      Value<String>? artist,
      Value<String>? album,
      Value<String?>? coverUrl,
      Value<int?>? durationMs,
      Value<String>? raw,
      Value<int>? startedAt,
      Value<int?>? endedAt,
      Value<int>? listenedMs,
      Value<int>? maxPositionMs,
      Value<String?>? endReason,
      Value<String?>? syncKey,
      Value<String>? originDeviceId,
      Value<int>? versionPhysical,
      Value<int>? versionCounter}) {
    return PlayEventsCompanion(
      id: id ?? this.id,
      sourceKey: sourceKey ?? this.sourceKey,
      songId: songId ?? this.songId,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      coverUrl: coverUrl ?? this.coverUrl,
      durationMs: durationMs ?? this.durationMs,
      raw: raw ?? this.raw,
      startedAt: startedAt ?? this.startedAt,
      endedAt: endedAt ?? this.endedAt,
      listenedMs: listenedMs ?? this.listenedMs,
      maxPositionMs: maxPositionMs ?? this.maxPositionMs,
      endReason: endReason ?? this.endReason,
      syncKey: syncKey ?? this.syncKey,
      originDeviceId: originDeviceId ?? this.originDeviceId,
      versionPhysical: versionPhysical ?? this.versionPhysical,
      versionCounter: versionCounter ?? this.versionCounter,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (sourceKey.present) {
      map['sourceKey'] = Variable<String>(sourceKey.value);
    }
    if (songId.present) {
      map['songId'] = Variable<String>(songId.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (artist.present) {
      map['artist'] = Variable<String>(artist.value);
    }
    if (album.present) {
      map['album'] = Variable<String>(album.value);
    }
    if (coverUrl.present) {
      map['coverUrl'] = Variable<String>(coverUrl.value);
    }
    if (durationMs.present) {
      map['durationMs'] = Variable<int>(durationMs.value);
    }
    if (raw.present) {
      map['raw'] = Variable<String>(raw.value);
    }
    if (startedAt.present) {
      map['startedAt'] = Variable<int>(startedAt.value);
    }
    if (endedAt.present) {
      map['endedAt'] = Variable<int>(endedAt.value);
    }
    if (listenedMs.present) {
      map['listenedMs'] = Variable<int>(listenedMs.value);
    }
    if (maxPositionMs.present) {
      map['maxPositionMs'] = Variable<int>(maxPositionMs.value);
    }
    if (endReason.present) {
      map['endReason'] = Variable<String>(endReason.value);
    }
    if (syncKey.present) {
      map['syncKey'] = Variable<String>(syncKey.value);
    }
    if (originDeviceId.present) {
      map['originDeviceId'] = Variable<String>(originDeviceId.value);
    }
    if (versionPhysical.present) {
      map['versionPhysical'] = Variable<int>(versionPhysical.value);
    }
    if (versionCounter.present) {
      map['versionCounter'] = Variable<int>(versionCounter.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PlayEventsCompanion(')
          ..write('id: $id, ')
          ..write('sourceKey: $sourceKey, ')
          ..write('songId: $songId, ')
          ..write('title: $title, ')
          ..write('artist: $artist, ')
          ..write('album: $album, ')
          ..write('coverUrl: $coverUrl, ')
          ..write('durationMs: $durationMs, ')
          ..write('raw: $raw, ')
          ..write('startedAt: $startedAt, ')
          ..write('endedAt: $endedAt, ')
          ..write('listenedMs: $listenedMs, ')
          ..write('maxPositionMs: $maxPositionMs, ')
          ..write('endReason: $endReason, ')
          ..write('syncKey: $syncKey, ')
          ..write('originDeviceId: $originDeviceId, ')
          ..write('versionPhysical: $versionPhysical, ')
          ..write('versionCounter: $versionCounter')
          ..write(')'))
        .toString();
  }
}

class $DownloadsTable extends Downloads
    with TableInfo<$DownloadsTable, DownloadRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $DownloadsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _originSourceKeyMeta =
      const VerificationMeta('originSourceKey');
  @override
  late final GeneratedColumn<String> originSourceKey = GeneratedColumn<String>(
      'originSourceKey', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _originSongIdMeta =
      const VerificationMeta('originSongId');
  @override
  late final GeneratedColumn<String> originSongId = GeneratedColumn<String>(
      'originSongId', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
      'title', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _artistMeta = const VerificationMeta('artist');
  @override
  late final GeneratedColumn<String> artist = GeneratedColumn<String>(
      'artist', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _albumMeta = const VerificationMeta('album');
  @override
  late final GeneratedColumn<String> album = GeneratedColumn<String>(
      'album', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _coverUrlMeta =
      const VerificationMeta('coverUrl');
  @override
  late final GeneratedColumn<String> coverUrl = GeneratedColumn<String>(
      'coverUrl', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _durationMsMeta =
      const VerificationMeta('durationMs');
  @override
  late final GeneratedColumn<int> durationMs = GeneratedColumn<int>(
      'durationMs', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _rawMeta = const VerificationMeta('raw');
  @override
  late final GeneratedColumn<String> raw = GeneratedColumn<String>(
      'raw', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('{}'));
  static const VerificationMeta _qualityMeta =
      const VerificationMeta('quality');
  @override
  late final GeneratedColumn<String> quality = GeneratedColumn<String>(
      'quality', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _filePathMeta =
      const VerificationMeta('filePath');
  @override
  late final GeneratedColumn<String> filePath = GeneratedColumn<String>(
      'filePath', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _sizeBytesMeta =
      const VerificationMeta('sizeBytes');
  @override
  late final GeneratedColumn<int> sizeBytes = GeneratedColumn<int>(
      'sizeBytes', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _lyricPathMeta =
      const VerificationMeta('lyricPath');
  @override
  late final GeneratedColumn<String> lyricPath = GeneratedColumn<String>(
      'lyricPath', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _coverPathMeta =
      const VerificationMeta('coverPath');
  @override
  late final GeneratedColumn<String> coverPath = GeneratedColumn<String>(
      'coverPath', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _publicUriMeta =
      const VerificationMeta('publicUri');
  @override
  late final GeneratedColumn<String> publicUri = GeneratedColumn<String>(
      'publicUri', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _importedMeta =
      const VerificationMeta('imported');
  @override
  late final GeneratedColumn<bool> imported = GeneratedColumn<bool>(
      'imported', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("imported" IN (0, 1))'),
      defaultValue: const Constant(false));
  static const VerificationMeta _downloadedAtMeta =
      const VerificationMeta('downloadedAt');
  @override
  late final GeneratedColumn<int> downloadedAt = GeneratedColumn<int>(
      'downloadedAt', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        originSourceKey,
        originSongId,
        title,
        artist,
        album,
        coverUrl,
        durationMs,
        raw,
        quality,
        filePath,
        sizeBytes,
        lyricPath,
        coverPath,
        publicUri,
        imported,
        downloadedAt
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'downloads';
  @override
  VerificationContext validateIntegrity(Insertable<DownloadRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('originSourceKey')) {
      context.handle(
          _originSourceKeyMeta,
          originSourceKey.isAcceptableOrUnknown(
              data['originSourceKey']!, _originSourceKeyMeta));
    } else if (isInserting) {
      context.missing(_originSourceKeyMeta);
    }
    if (data.containsKey('originSongId')) {
      context.handle(
          _originSongIdMeta,
          originSongId.isAcceptableOrUnknown(
              data['originSongId']!, _originSongIdMeta));
    } else if (isInserting) {
      context.missing(_originSongIdMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
          _titleMeta, title.isAcceptableOrUnknown(data['title']!, _titleMeta));
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('artist')) {
      context.handle(_artistMeta,
          artist.isAcceptableOrUnknown(data['artist']!, _artistMeta));
    }
    if (data.containsKey('album')) {
      context.handle(
          _albumMeta, album.isAcceptableOrUnknown(data['album']!, _albumMeta));
    }
    if (data.containsKey('coverUrl')) {
      context.handle(_coverUrlMeta,
          coverUrl.isAcceptableOrUnknown(data['coverUrl']!, _coverUrlMeta));
    }
    if (data.containsKey('durationMs')) {
      context.handle(
          _durationMsMeta,
          durationMs.isAcceptableOrUnknown(
              data['durationMs']!, _durationMsMeta));
    }
    if (data.containsKey('raw')) {
      context.handle(
          _rawMeta, raw.isAcceptableOrUnknown(data['raw']!, _rawMeta));
    }
    if (data.containsKey('quality')) {
      context.handle(_qualityMeta,
          quality.isAcceptableOrUnknown(data['quality']!, _qualityMeta));
    }
    if (data.containsKey('filePath')) {
      context.handle(_filePathMeta,
          filePath.isAcceptableOrUnknown(data['filePath']!, _filePathMeta));
    }
    if (data.containsKey('sizeBytes')) {
      context.handle(_sizeBytesMeta,
          sizeBytes.isAcceptableOrUnknown(data['sizeBytes']!, _sizeBytesMeta));
    }
    if (data.containsKey('lyricPath')) {
      context.handle(_lyricPathMeta,
          lyricPath.isAcceptableOrUnknown(data['lyricPath']!, _lyricPathMeta));
    }
    if (data.containsKey('coverPath')) {
      context.handle(_coverPathMeta,
          coverPath.isAcceptableOrUnknown(data['coverPath']!, _coverPathMeta));
    }
    if (data.containsKey('publicUri')) {
      context.handle(_publicUriMeta,
          publicUri.isAcceptableOrUnknown(data['publicUri']!, _publicUriMeta));
    }
    if (data.containsKey('imported')) {
      context.handle(_importedMeta,
          imported.isAcceptableOrUnknown(data['imported']!, _importedMeta));
    }
    if (data.containsKey('downloadedAt')) {
      context.handle(
          _downloadedAtMeta,
          downloadedAt.isAcceptableOrUnknown(
              data['downloadedAt']!, _downloadedAtMeta));
    } else if (isInserting) {
      context.missing(_downloadedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  DownloadRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DownloadRow(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      originSourceKey: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}originSourceKey'])!,
      originSongId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}originSongId'])!,
      title: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}title'])!,
      artist: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}artist'])!,
      album: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}album'])!,
      coverUrl: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}coverUrl']),
      durationMs: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}durationMs']),
      raw: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}raw'])!,
      quality: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}quality'])!,
      filePath: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}filePath']),
      sizeBytes: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}sizeBytes'])!,
      lyricPath: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}lyricPath']),
      coverPath: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}coverPath']),
      publicUri: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}publicUri']),
      imported: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}imported'])!,
      downloadedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}downloadedAt'])!,
    );
  }

  @override
  $DownloadsTable createAlias(String alias) {
    return $DownloadsTable(attachedDatabase, alias);
  }
}

class DownloadRow extends DataClass implements Insertable<DownloadRow> {
  final int id;
  final String originSourceKey;
  final String originSongId;
  final String title;
  final String artist;
  final String album;
  final String? coverUrl;
  final int? durationMs;
  final String raw;
  final String quality;
  final String? filePath;
  final int sizeBytes;
  final String? lyricPath;
  final String? coverPath;
  final String? publicUri;
  final bool imported;
  final int downloadedAt;
  const DownloadRow(
      {required this.id,
      required this.originSourceKey,
      required this.originSongId,
      required this.title,
      required this.artist,
      required this.album,
      this.coverUrl,
      this.durationMs,
      required this.raw,
      required this.quality,
      this.filePath,
      required this.sizeBytes,
      this.lyricPath,
      this.coverPath,
      this.publicUri,
      required this.imported,
      required this.downloadedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['originSourceKey'] = Variable<String>(originSourceKey);
    map['originSongId'] = Variable<String>(originSongId);
    map['title'] = Variable<String>(title);
    map['artist'] = Variable<String>(artist);
    map['album'] = Variable<String>(album);
    if (!nullToAbsent || coverUrl != null) {
      map['coverUrl'] = Variable<String>(coverUrl);
    }
    if (!nullToAbsent || durationMs != null) {
      map['durationMs'] = Variable<int>(durationMs);
    }
    map['raw'] = Variable<String>(raw);
    map['quality'] = Variable<String>(quality);
    if (!nullToAbsent || filePath != null) {
      map['filePath'] = Variable<String>(filePath);
    }
    map['sizeBytes'] = Variable<int>(sizeBytes);
    if (!nullToAbsent || lyricPath != null) {
      map['lyricPath'] = Variable<String>(lyricPath);
    }
    if (!nullToAbsent || coverPath != null) {
      map['coverPath'] = Variable<String>(coverPath);
    }
    if (!nullToAbsent || publicUri != null) {
      map['publicUri'] = Variable<String>(publicUri);
    }
    map['imported'] = Variable<bool>(imported);
    map['downloadedAt'] = Variable<int>(downloadedAt);
    return map;
  }

  DownloadsCompanion toCompanion(bool nullToAbsent) {
    return DownloadsCompanion(
      id: Value(id),
      originSourceKey: Value(originSourceKey),
      originSongId: Value(originSongId),
      title: Value(title),
      artist: Value(artist),
      album: Value(album),
      coverUrl: coverUrl == null && nullToAbsent
          ? const Value.absent()
          : Value(coverUrl),
      durationMs: durationMs == null && nullToAbsent
          ? const Value.absent()
          : Value(durationMs),
      raw: Value(raw),
      quality: Value(quality),
      filePath: filePath == null && nullToAbsent
          ? const Value.absent()
          : Value(filePath),
      sizeBytes: Value(sizeBytes),
      lyricPath: lyricPath == null && nullToAbsent
          ? const Value.absent()
          : Value(lyricPath),
      coverPath: coverPath == null && nullToAbsent
          ? const Value.absent()
          : Value(coverPath),
      publicUri: publicUri == null && nullToAbsent
          ? const Value.absent()
          : Value(publicUri),
      imported: Value(imported),
      downloadedAt: Value(downloadedAt),
    );
  }

  factory DownloadRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DownloadRow(
      id: serializer.fromJson<int>(json['id']),
      originSourceKey: serializer.fromJson<String>(json['originSourceKey']),
      originSongId: serializer.fromJson<String>(json['originSongId']),
      title: serializer.fromJson<String>(json['title']),
      artist: serializer.fromJson<String>(json['artist']),
      album: serializer.fromJson<String>(json['album']),
      coverUrl: serializer.fromJson<String?>(json['coverUrl']),
      durationMs: serializer.fromJson<int?>(json['durationMs']),
      raw: serializer.fromJson<String>(json['raw']),
      quality: serializer.fromJson<String>(json['quality']),
      filePath: serializer.fromJson<String?>(json['filePath']),
      sizeBytes: serializer.fromJson<int>(json['sizeBytes']),
      lyricPath: serializer.fromJson<String?>(json['lyricPath']),
      coverPath: serializer.fromJson<String?>(json['coverPath']),
      publicUri: serializer.fromJson<String?>(json['publicUri']),
      imported: serializer.fromJson<bool>(json['imported']),
      downloadedAt: serializer.fromJson<int>(json['downloadedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'originSourceKey': serializer.toJson<String>(originSourceKey),
      'originSongId': serializer.toJson<String>(originSongId),
      'title': serializer.toJson<String>(title),
      'artist': serializer.toJson<String>(artist),
      'album': serializer.toJson<String>(album),
      'coverUrl': serializer.toJson<String?>(coverUrl),
      'durationMs': serializer.toJson<int?>(durationMs),
      'raw': serializer.toJson<String>(raw),
      'quality': serializer.toJson<String>(quality),
      'filePath': serializer.toJson<String?>(filePath),
      'sizeBytes': serializer.toJson<int>(sizeBytes),
      'lyricPath': serializer.toJson<String?>(lyricPath),
      'coverPath': serializer.toJson<String?>(coverPath),
      'publicUri': serializer.toJson<String?>(publicUri),
      'imported': serializer.toJson<bool>(imported),
      'downloadedAt': serializer.toJson<int>(downloadedAt),
    };
  }

  DownloadRow copyWith(
          {int? id,
          String? originSourceKey,
          String? originSongId,
          String? title,
          String? artist,
          String? album,
          Value<String?> coverUrl = const Value.absent(),
          Value<int?> durationMs = const Value.absent(),
          String? raw,
          String? quality,
          Value<String?> filePath = const Value.absent(),
          int? sizeBytes,
          Value<String?> lyricPath = const Value.absent(),
          Value<String?> coverPath = const Value.absent(),
          Value<String?> publicUri = const Value.absent(),
          bool? imported,
          int? downloadedAt}) =>
      DownloadRow(
        id: id ?? this.id,
        originSourceKey: originSourceKey ?? this.originSourceKey,
        originSongId: originSongId ?? this.originSongId,
        title: title ?? this.title,
        artist: artist ?? this.artist,
        album: album ?? this.album,
        coverUrl: coverUrl.present ? coverUrl.value : this.coverUrl,
        durationMs: durationMs.present ? durationMs.value : this.durationMs,
        raw: raw ?? this.raw,
        quality: quality ?? this.quality,
        filePath: filePath.present ? filePath.value : this.filePath,
        sizeBytes: sizeBytes ?? this.sizeBytes,
        lyricPath: lyricPath.present ? lyricPath.value : this.lyricPath,
        coverPath: coverPath.present ? coverPath.value : this.coverPath,
        publicUri: publicUri.present ? publicUri.value : this.publicUri,
        imported: imported ?? this.imported,
        downloadedAt: downloadedAt ?? this.downloadedAt,
      );
  DownloadRow copyWithCompanion(DownloadsCompanion data) {
    return DownloadRow(
      id: data.id.present ? data.id.value : this.id,
      originSourceKey: data.originSourceKey.present
          ? data.originSourceKey.value
          : this.originSourceKey,
      originSongId: data.originSongId.present
          ? data.originSongId.value
          : this.originSongId,
      title: data.title.present ? data.title.value : this.title,
      artist: data.artist.present ? data.artist.value : this.artist,
      album: data.album.present ? data.album.value : this.album,
      coverUrl: data.coverUrl.present ? data.coverUrl.value : this.coverUrl,
      durationMs:
          data.durationMs.present ? data.durationMs.value : this.durationMs,
      raw: data.raw.present ? data.raw.value : this.raw,
      quality: data.quality.present ? data.quality.value : this.quality,
      filePath: data.filePath.present ? data.filePath.value : this.filePath,
      sizeBytes: data.sizeBytes.present ? data.sizeBytes.value : this.sizeBytes,
      lyricPath: data.lyricPath.present ? data.lyricPath.value : this.lyricPath,
      coverPath: data.coverPath.present ? data.coverPath.value : this.coverPath,
      publicUri: data.publicUri.present ? data.publicUri.value : this.publicUri,
      imported: data.imported.present ? data.imported.value : this.imported,
      downloadedAt: data.downloadedAt.present
          ? data.downloadedAt.value
          : this.downloadedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DownloadRow(')
          ..write('id: $id, ')
          ..write('originSourceKey: $originSourceKey, ')
          ..write('originSongId: $originSongId, ')
          ..write('title: $title, ')
          ..write('artist: $artist, ')
          ..write('album: $album, ')
          ..write('coverUrl: $coverUrl, ')
          ..write('durationMs: $durationMs, ')
          ..write('raw: $raw, ')
          ..write('quality: $quality, ')
          ..write('filePath: $filePath, ')
          ..write('sizeBytes: $sizeBytes, ')
          ..write('lyricPath: $lyricPath, ')
          ..write('coverPath: $coverPath, ')
          ..write('publicUri: $publicUri, ')
          ..write('imported: $imported, ')
          ..write('downloadedAt: $downloadedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id,
      originSourceKey,
      originSongId,
      title,
      artist,
      album,
      coverUrl,
      durationMs,
      raw,
      quality,
      filePath,
      sizeBytes,
      lyricPath,
      coverPath,
      publicUri,
      imported,
      downloadedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DownloadRow &&
          other.id == this.id &&
          other.originSourceKey == this.originSourceKey &&
          other.originSongId == this.originSongId &&
          other.title == this.title &&
          other.artist == this.artist &&
          other.album == this.album &&
          other.coverUrl == this.coverUrl &&
          other.durationMs == this.durationMs &&
          other.raw == this.raw &&
          other.quality == this.quality &&
          other.filePath == this.filePath &&
          other.sizeBytes == this.sizeBytes &&
          other.lyricPath == this.lyricPath &&
          other.coverPath == this.coverPath &&
          other.publicUri == this.publicUri &&
          other.imported == this.imported &&
          other.downloadedAt == this.downloadedAt);
}

class DownloadsCompanion extends UpdateCompanion<DownloadRow> {
  final Value<int> id;
  final Value<String> originSourceKey;
  final Value<String> originSongId;
  final Value<String> title;
  final Value<String> artist;
  final Value<String> album;
  final Value<String?> coverUrl;
  final Value<int?> durationMs;
  final Value<String> raw;
  final Value<String> quality;
  final Value<String?> filePath;
  final Value<int> sizeBytes;
  final Value<String?> lyricPath;
  final Value<String?> coverPath;
  final Value<String?> publicUri;
  final Value<bool> imported;
  final Value<int> downloadedAt;
  const DownloadsCompanion({
    this.id = const Value.absent(),
    this.originSourceKey = const Value.absent(),
    this.originSongId = const Value.absent(),
    this.title = const Value.absent(),
    this.artist = const Value.absent(),
    this.album = const Value.absent(),
    this.coverUrl = const Value.absent(),
    this.durationMs = const Value.absent(),
    this.raw = const Value.absent(),
    this.quality = const Value.absent(),
    this.filePath = const Value.absent(),
    this.sizeBytes = const Value.absent(),
    this.lyricPath = const Value.absent(),
    this.coverPath = const Value.absent(),
    this.publicUri = const Value.absent(),
    this.imported = const Value.absent(),
    this.downloadedAt = const Value.absent(),
  });
  DownloadsCompanion.insert({
    this.id = const Value.absent(),
    required String originSourceKey,
    required String originSongId,
    required String title,
    this.artist = const Value.absent(),
    this.album = const Value.absent(),
    this.coverUrl = const Value.absent(),
    this.durationMs = const Value.absent(),
    this.raw = const Value.absent(),
    this.quality = const Value.absent(),
    this.filePath = const Value.absent(),
    this.sizeBytes = const Value.absent(),
    this.lyricPath = const Value.absent(),
    this.coverPath = const Value.absent(),
    this.publicUri = const Value.absent(),
    this.imported = const Value.absent(),
    required int downloadedAt,
  })  : originSourceKey = Value(originSourceKey),
        originSongId = Value(originSongId),
        title = Value(title),
        downloadedAt = Value(downloadedAt);
  static Insertable<DownloadRow> custom({
    Expression<int>? id,
    Expression<String>? originSourceKey,
    Expression<String>? originSongId,
    Expression<String>? title,
    Expression<String>? artist,
    Expression<String>? album,
    Expression<String>? coverUrl,
    Expression<int>? durationMs,
    Expression<String>? raw,
    Expression<String>? quality,
    Expression<String>? filePath,
    Expression<int>? sizeBytes,
    Expression<String>? lyricPath,
    Expression<String>? coverPath,
    Expression<String>? publicUri,
    Expression<bool>? imported,
    Expression<int>? downloadedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (originSourceKey != null) 'originSourceKey': originSourceKey,
      if (originSongId != null) 'originSongId': originSongId,
      if (title != null) 'title': title,
      if (artist != null) 'artist': artist,
      if (album != null) 'album': album,
      if (coverUrl != null) 'coverUrl': coverUrl,
      if (durationMs != null) 'durationMs': durationMs,
      if (raw != null) 'raw': raw,
      if (quality != null) 'quality': quality,
      if (filePath != null) 'filePath': filePath,
      if (sizeBytes != null) 'sizeBytes': sizeBytes,
      if (lyricPath != null) 'lyricPath': lyricPath,
      if (coverPath != null) 'coverPath': coverPath,
      if (publicUri != null) 'publicUri': publicUri,
      if (imported != null) 'imported': imported,
      if (downloadedAt != null) 'downloadedAt': downloadedAt,
    });
  }

  DownloadsCompanion copyWith(
      {Value<int>? id,
      Value<String>? originSourceKey,
      Value<String>? originSongId,
      Value<String>? title,
      Value<String>? artist,
      Value<String>? album,
      Value<String?>? coverUrl,
      Value<int?>? durationMs,
      Value<String>? raw,
      Value<String>? quality,
      Value<String?>? filePath,
      Value<int>? sizeBytes,
      Value<String?>? lyricPath,
      Value<String?>? coverPath,
      Value<String?>? publicUri,
      Value<bool>? imported,
      Value<int>? downloadedAt}) {
    return DownloadsCompanion(
      id: id ?? this.id,
      originSourceKey: originSourceKey ?? this.originSourceKey,
      originSongId: originSongId ?? this.originSongId,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      coverUrl: coverUrl ?? this.coverUrl,
      durationMs: durationMs ?? this.durationMs,
      raw: raw ?? this.raw,
      quality: quality ?? this.quality,
      filePath: filePath ?? this.filePath,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      lyricPath: lyricPath ?? this.lyricPath,
      coverPath: coverPath ?? this.coverPath,
      publicUri: publicUri ?? this.publicUri,
      imported: imported ?? this.imported,
      downloadedAt: downloadedAt ?? this.downloadedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (originSourceKey.present) {
      map['originSourceKey'] = Variable<String>(originSourceKey.value);
    }
    if (originSongId.present) {
      map['originSongId'] = Variable<String>(originSongId.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (artist.present) {
      map['artist'] = Variable<String>(artist.value);
    }
    if (album.present) {
      map['album'] = Variable<String>(album.value);
    }
    if (coverUrl.present) {
      map['coverUrl'] = Variable<String>(coverUrl.value);
    }
    if (durationMs.present) {
      map['durationMs'] = Variable<int>(durationMs.value);
    }
    if (raw.present) {
      map['raw'] = Variable<String>(raw.value);
    }
    if (quality.present) {
      map['quality'] = Variable<String>(quality.value);
    }
    if (filePath.present) {
      map['filePath'] = Variable<String>(filePath.value);
    }
    if (sizeBytes.present) {
      map['sizeBytes'] = Variable<int>(sizeBytes.value);
    }
    if (lyricPath.present) {
      map['lyricPath'] = Variable<String>(lyricPath.value);
    }
    if (coverPath.present) {
      map['coverPath'] = Variable<String>(coverPath.value);
    }
    if (publicUri.present) {
      map['publicUri'] = Variable<String>(publicUri.value);
    }
    if (imported.present) {
      map['imported'] = Variable<bool>(imported.value);
    }
    if (downloadedAt.present) {
      map['downloadedAt'] = Variable<int>(downloadedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('DownloadsCompanion(')
          ..write('id: $id, ')
          ..write('originSourceKey: $originSourceKey, ')
          ..write('originSongId: $originSongId, ')
          ..write('title: $title, ')
          ..write('artist: $artist, ')
          ..write('album: $album, ')
          ..write('coverUrl: $coverUrl, ')
          ..write('durationMs: $durationMs, ')
          ..write('raw: $raw, ')
          ..write('quality: $quality, ')
          ..write('filePath: $filePath, ')
          ..write('sizeBytes: $sizeBytes, ')
          ..write('lyricPath: $lyricPath, ')
          ..write('coverPath: $coverPath, ')
          ..write('publicUri: $publicUri, ')
          ..write('imported: $imported, ')
          ..write('downloadedAt: $downloadedAt')
          ..write(')'))
        .toString();
  }
}

abstract class _$MoliaDatabase extends GeneratedDatabase {
  _$MoliaDatabase(QueryExecutor e) : super(e);
  $MoliaDatabaseManager get managers => $MoliaDatabaseManager(this);
  late final $PlayContextsTable playContexts = $PlayContextsTable(this);
  late final $PlayHistoryTable playHistory = $PlayHistoryTable(this);
  late final $PlaylistsTable playlists = $PlaylistsTable(this);
  late final $PlaylistTracksTable playlistTracks = $PlaylistTracksTable(this);
  late final $SyncTombstonesTable syncTombstones = $SyncTombstonesTable(this);
  late final $SyncKnownTable syncKnown = $SyncKnownTable(this);
  late final $SyncJournalTable syncJournal = $SyncJournalTable(this);
  late final $SyncJournalStatesTable syncJournalStates =
      $SyncJournalStatesTable(this);
  late final $PlayEventsTable playEvents = $PlayEventsTable(this);
  late final $DownloadsTable downloads = $DownloadsTable(this);
  late final Index idxPlayContextsLastPlayedAt = Index(
      'idx_play_contexts_lastPlayedAt',
      'CREATE INDEX idx_play_contexts_lastPlayedAt ON play_contexts (lastPlayedAt)');
  late final Index idxPlayHistoryPlayedAt = Index('idx_play_history_playedAt',
      'CREATE INDEX idx_play_history_playedAt ON play_history (playedAt)');
  late final Index idxPlaylistsSyncId = Index('idx_playlists_syncId',
      'CREATE UNIQUE INDEX idx_playlists_syncId ON playlists (syncId) WHERE syncId IS NOT NULL');
  late final Index idxPlaylistTracksOrder = Index('idx_playlist_tracks_order',
      'CREATE INDEX idx_playlist_tracks_order ON playlist_tracks (playlistId, sortOrder, addedAt)');
  late final Index idxSyncJournalAt = Index('idx_sync_journal_at',
      'CREATE INDEX idx_sync_journal_at ON sync_journal (at)');
  late final Index idxPlayEventsStartedAt = Index('idx_play_events_startedAt',
      'CREATE INDEX idx_play_events_startedAt ON play_events (startedAt)');
  late final Index idxPlayEventsTrack = Index('idx_play_events_track',
      'CREATE INDEX idx_play_events_track ON play_events (sourceKey, songId)');
  late final Index idxPlayEventsEndedAt = Index('idx_play_events_endedAt',
      'CREATE INDEX idx_play_events_endedAt ON play_events (endedAt)');
  late final Index idxPlayEventsSyncKey = Index('idx_play_events_syncKey',
      'CREATE UNIQUE INDEX idx_play_events_syncKey ON play_events (syncKey) WHERE syncKey IS NOT NULL');
  late final Index idxDownloadsDownloadedAt = Index(
      'idx_downloads_downloadedAt',
      'CREATE INDEX idx_downloads_downloadedAt ON downloads (downloadedAt)');
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
        playContexts,
        playHistory,
        playlists,
        playlistTracks,
        syncTombstones,
        syncKnown,
        syncJournal,
        syncJournalStates,
        playEvents,
        downloads,
        idxPlayContextsLastPlayedAt,
        idxPlayHistoryPlayedAt,
        idxPlaylistsSyncId,
        idxPlaylistTracksOrder,
        idxSyncJournalAt,
        idxPlayEventsStartedAt,
        idxPlayEventsTrack,
        idxPlayEventsEndedAt,
        idxPlayEventsSyncKey,
        idxDownloadsDownloadedAt
      ];
}

typedef $$PlayContextsTableCreateCompanionBuilder = PlayContextsCompanion
    Function({
  Value<String?> contextUri,
  required String contextType,
  required String contextName,
  Value<String?> imageUrl,
  required int lastPlayedAt,
  Value<int> rowid,
});
typedef $$PlayContextsTableUpdateCompanionBuilder = PlayContextsCompanion
    Function({
  Value<String?> contextUri,
  Value<String> contextType,
  Value<String> contextName,
  Value<String?> imageUrl,
  Value<int> lastPlayedAt,
  Value<int> rowid,
});

class $$PlayContextsTableFilterComposer
    extends Composer<_$MoliaDatabase, $PlayContextsTable> {
  $$PlayContextsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get contextUri => $composableBuilder(
      column: $table.contextUri, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get contextType => $composableBuilder(
      column: $table.contextType, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get contextName => $composableBuilder(
      column: $table.contextName, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get imageUrl => $composableBuilder(
      column: $table.imageUrl, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get lastPlayedAt => $composableBuilder(
      column: $table.lastPlayedAt, builder: (column) => ColumnFilters(column));
}

class $$PlayContextsTableOrderingComposer
    extends Composer<_$MoliaDatabase, $PlayContextsTable> {
  $$PlayContextsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get contextUri => $composableBuilder(
      column: $table.contextUri, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get contextType => $composableBuilder(
      column: $table.contextType, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get contextName => $composableBuilder(
      column: $table.contextName, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get imageUrl => $composableBuilder(
      column: $table.imageUrl, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get lastPlayedAt => $composableBuilder(
      column: $table.lastPlayedAt,
      builder: (column) => ColumnOrderings(column));
}

class $$PlayContextsTableAnnotationComposer
    extends Composer<_$MoliaDatabase, $PlayContextsTable> {
  $$PlayContextsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get contextUri => $composableBuilder(
      column: $table.contextUri, builder: (column) => column);

  GeneratedColumn<String> get contextType => $composableBuilder(
      column: $table.contextType, builder: (column) => column);

  GeneratedColumn<String> get contextName => $composableBuilder(
      column: $table.contextName, builder: (column) => column);

  GeneratedColumn<String> get imageUrl =>
      $composableBuilder(column: $table.imageUrl, builder: (column) => column);

  GeneratedColumn<int> get lastPlayedAt => $composableBuilder(
      column: $table.lastPlayedAt, builder: (column) => column);
}

class $$PlayContextsTableTableManager extends RootTableManager<
    _$MoliaDatabase,
    $PlayContextsTable,
    PlayContext,
    $$PlayContextsTableFilterComposer,
    $$PlayContextsTableOrderingComposer,
    $$PlayContextsTableAnnotationComposer,
    $$PlayContextsTableCreateCompanionBuilder,
    $$PlayContextsTableUpdateCompanionBuilder,
    (
      PlayContext,
      BaseReferences<_$MoliaDatabase, $PlayContextsTable, PlayContext>
    ),
    PlayContext,
    PrefetchHooks Function()> {
  $$PlayContextsTableTableManager(_$MoliaDatabase db, $PlayContextsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PlayContextsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PlayContextsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PlayContextsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String?> contextUri = const Value.absent(),
            Value<String> contextType = const Value.absent(),
            Value<String> contextName = const Value.absent(),
            Value<String?> imageUrl = const Value.absent(),
            Value<int> lastPlayedAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              PlayContextsCompanion(
            contextUri: contextUri,
            contextType: contextType,
            contextName: contextName,
            imageUrl: imageUrl,
            lastPlayedAt: lastPlayedAt,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            Value<String?> contextUri = const Value.absent(),
            required String contextType,
            required String contextName,
            Value<String?> imageUrl = const Value.absent(),
            required int lastPlayedAt,
            Value<int> rowid = const Value.absent(),
          }) =>
              PlayContextsCompanion.insert(
            contextUri: contextUri,
            contextType: contextType,
            contextName: contextName,
            imageUrl: imageUrl,
            lastPlayedAt: lastPlayedAt,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$PlayContextsTable, PlayContext>(table),
                    BaseReferences<_$MoliaDatabase, $PlayContextsTable,
                        PlayContext>(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$PlayContextsTableProcessedTableManager = ProcessedTableManager<
    _$MoliaDatabase,
    $PlayContextsTable,
    PlayContext,
    $$PlayContextsTableFilterComposer,
    $$PlayContextsTableOrderingComposer,
    $$PlayContextsTableAnnotationComposer,
    $$PlayContextsTableCreateCompanionBuilder,
    $$PlayContextsTableUpdateCompanionBuilder,
    (
      PlayContext,
      BaseReferences<_$MoliaDatabase, $PlayContextsTable, PlayContext>
    ),
    PlayContext,
    PrefetchHooks Function()>;
typedef $$PlayHistoryTableCreateCompanionBuilder = PlayHistoryCompanion
    Function({
  required String sourceKey,
  required String songId,
  required String title,
  Value<String> artist,
  Value<String> album,
  Value<String?> coverUrl,
  Value<int?> durationMs,
  Value<String> raw,
  required int playedAt,
  Value<int> versionPhysical,
  Value<int> versionCounter,
  Value<String> deviceId,
  Value<int> rowid,
});
typedef $$PlayHistoryTableUpdateCompanionBuilder = PlayHistoryCompanion
    Function({
  Value<String> sourceKey,
  Value<String> songId,
  Value<String> title,
  Value<String> artist,
  Value<String> album,
  Value<String?> coverUrl,
  Value<int?> durationMs,
  Value<String> raw,
  Value<int> playedAt,
  Value<int> versionPhysical,
  Value<int> versionCounter,
  Value<String> deviceId,
  Value<int> rowid,
});

class $$PlayHistoryTableFilterComposer
    extends Composer<_$MoliaDatabase, $PlayHistoryTable> {
  $$PlayHistoryTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get sourceKey => $composableBuilder(
      column: $table.sourceKey, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get songId => $composableBuilder(
      column: $table.songId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get title => $composableBuilder(
      column: $table.title, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get artist => $composableBuilder(
      column: $table.artist, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get album => $composableBuilder(
      column: $table.album, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get coverUrl => $composableBuilder(
      column: $table.coverUrl, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get durationMs => $composableBuilder(
      column: $table.durationMs, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get raw => $composableBuilder(
      column: $table.raw, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get playedAt => $composableBuilder(
      column: $table.playedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get versionPhysical => $composableBuilder(
      column: $table.versionPhysical,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get versionCounter => $composableBuilder(
      column: $table.versionCounter,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get deviceId => $composableBuilder(
      column: $table.deviceId, builder: (column) => ColumnFilters(column));
}

class $$PlayHistoryTableOrderingComposer
    extends Composer<_$MoliaDatabase, $PlayHistoryTable> {
  $$PlayHistoryTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get sourceKey => $composableBuilder(
      column: $table.sourceKey, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get songId => $composableBuilder(
      column: $table.songId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get title => $composableBuilder(
      column: $table.title, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get artist => $composableBuilder(
      column: $table.artist, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get album => $composableBuilder(
      column: $table.album, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get coverUrl => $composableBuilder(
      column: $table.coverUrl, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get durationMs => $composableBuilder(
      column: $table.durationMs, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get raw => $composableBuilder(
      column: $table.raw, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get playedAt => $composableBuilder(
      column: $table.playedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get versionPhysical => $composableBuilder(
      column: $table.versionPhysical,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get versionCounter => $composableBuilder(
      column: $table.versionCounter,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get deviceId => $composableBuilder(
      column: $table.deviceId, builder: (column) => ColumnOrderings(column));
}

class $$PlayHistoryTableAnnotationComposer
    extends Composer<_$MoliaDatabase, $PlayHistoryTable> {
  $$PlayHistoryTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get sourceKey =>
      $composableBuilder(column: $table.sourceKey, builder: (column) => column);

  GeneratedColumn<String> get songId =>
      $composableBuilder(column: $table.songId, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get artist =>
      $composableBuilder(column: $table.artist, builder: (column) => column);

  GeneratedColumn<String> get album =>
      $composableBuilder(column: $table.album, builder: (column) => column);

  GeneratedColumn<String> get coverUrl =>
      $composableBuilder(column: $table.coverUrl, builder: (column) => column);

  GeneratedColumn<int> get durationMs => $composableBuilder(
      column: $table.durationMs, builder: (column) => column);

  GeneratedColumn<String> get raw =>
      $composableBuilder(column: $table.raw, builder: (column) => column);

  GeneratedColumn<int> get playedAt =>
      $composableBuilder(column: $table.playedAt, builder: (column) => column);

  GeneratedColumn<int> get versionPhysical => $composableBuilder(
      column: $table.versionPhysical, builder: (column) => column);

  GeneratedColumn<int> get versionCounter => $composableBuilder(
      column: $table.versionCounter, builder: (column) => column);

  GeneratedColumn<String> get deviceId =>
      $composableBuilder(column: $table.deviceId, builder: (column) => column);
}

class $$PlayHistoryTableTableManager extends RootTableManager<
    _$MoliaDatabase,
    $PlayHistoryTable,
    PlayHistoryData,
    $$PlayHistoryTableFilterComposer,
    $$PlayHistoryTableOrderingComposer,
    $$PlayHistoryTableAnnotationComposer,
    $$PlayHistoryTableCreateCompanionBuilder,
    $$PlayHistoryTableUpdateCompanionBuilder,
    (
      PlayHistoryData,
      BaseReferences<_$MoliaDatabase, $PlayHistoryTable, PlayHistoryData>
    ),
    PlayHistoryData,
    PrefetchHooks Function()> {
  $$PlayHistoryTableTableManager(_$MoliaDatabase db, $PlayHistoryTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PlayHistoryTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PlayHistoryTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PlayHistoryTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> sourceKey = const Value.absent(),
            Value<String> songId = const Value.absent(),
            Value<String> title = const Value.absent(),
            Value<String> artist = const Value.absent(),
            Value<String> album = const Value.absent(),
            Value<String?> coverUrl = const Value.absent(),
            Value<int?> durationMs = const Value.absent(),
            Value<String> raw = const Value.absent(),
            Value<int> playedAt = const Value.absent(),
            Value<int> versionPhysical = const Value.absent(),
            Value<int> versionCounter = const Value.absent(),
            Value<String> deviceId = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              PlayHistoryCompanion(
            sourceKey: sourceKey,
            songId: songId,
            title: title,
            artist: artist,
            album: album,
            coverUrl: coverUrl,
            durationMs: durationMs,
            raw: raw,
            playedAt: playedAt,
            versionPhysical: versionPhysical,
            versionCounter: versionCounter,
            deviceId: deviceId,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String sourceKey,
            required String songId,
            required String title,
            Value<String> artist = const Value.absent(),
            Value<String> album = const Value.absent(),
            Value<String?> coverUrl = const Value.absent(),
            Value<int?> durationMs = const Value.absent(),
            Value<String> raw = const Value.absent(),
            required int playedAt,
            Value<int> versionPhysical = const Value.absent(),
            Value<int> versionCounter = const Value.absent(),
            Value<String> deviceId = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              PlayHistoryCompanion.insert(
            sourceKey: sourceKey,
            songId: songId,
            title: title,
            artist: artist,
            album: album,
            coverUrl: coverUrl,
            durationMs: durationMs,
            raw: raw,
            playedAt: playedAt,
            versionPhysical: versionPhysical,
            versionCounter: versionCounter,
            deviceId: deviceId,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$PlayHistoryTable, PlayHistoryData>(table),
                    BaseReferences<_$MoliaDatabase, $PlayHistoryTable,
                        PlayHistoryData>(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$PlayHistoryTableProcessedTableManager = ProcessedTableManager<
    _$MoliaDatabase,
    $PlayHistoryTable,
    PlayHistoryData,
    $$PlayHistoryTableFilterComposer,
    $$PlayHistoryTableOrderingComposer,
    $$PlayHistoryTableAnnotationComposer,
    $$PlayHistoryTableCreateCompanionBuilder,
    $$PlayHistoryTableUpdateCompanionBuilder,
    (
      PlayHistoryData,
      BaseReferences<_$MoliaDatabase, $PlayHistoryTable, PlayHistoryData>
    ),
    PlayHistoryData,
    PrefetchHooks Function()>;
typedef $$PlaylistsTableCreateCompanionBuilder = PlaylistsCompanion Function({
  Value<int> id,
  required String name,
  required int createdAt,
  Value<String?> syncId,
  Value<int> versionPhysical,
  Value<int> versionCounter,
  Value<String> deviceId,
});
typedef $$PlaylistsTableUpdateCompanionBuilder = PlaylistsCompanion Function({
  Value<int> id,
  Value<String> name,
  Value<int> createdAt,
  Value<String?> syncId,
  Value<int> versionPhysical,
  Value<int> versionCounter,
  Value<String> deviceId,
});

class $$PlaylistsTableFilterComposer
    extends Composer<_$MoliaDatabase, $PlaylistsTable> {
  $$PlaylistsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get syncId => $composableBuilder(
      column: $table.syncId, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get versionPhysical => $composableBuilder(
      column: $table.versionPhysical,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get versionCounter => $composableBuilder(
      column: $table.versionCounter,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get deviceId => $composableBuilder(
      column: $table.deviceId, builder: (column) => ColumnFilters(column));
}

class $$PlaylistsTableOrderingComposer
    extends Composer<_$MoliaDatabase, $PlaylistsTable> {
  $$PlaylistsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get syncId => $composableBuilder(
      column: $table.syncId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get versionPhysical => $composableBuilder(
      column: $table.versionPhysical,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get versionCounter => $composableBuilder(
      column: $table.versionCounter,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get deviceId => $composableBuilder(
      column: $table.deviceId, builder: (column) => ColumnOrderings(column));
}

class $$PlaylistsTableAnnotationComposer
    extends Composer<_$MoliaDatabase, $PlaylistsTable> {
  $$PlaylistsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<String> get syncId =>
      $composableBuilder(column: $table.syncId, builder: (column) => column);

  GeneratedColumn<int> get versionPhysical => $composableBuilder(
      column: $table.versionPhysical, builder: (column) => column);

  GeneratedColumn<int> get versionCounter => $composableBuilder(
      column: $table.versionCounter, builder: (column) => column);

  GeneratedColumn<String> get deviceId =>
      $composableBuilder(column: $table.deviceId, builder: (column) => column);
}

class $$PlaylistsTableTableManager extends RootTableManager<
    _$MoliaDatabase,
    $PlaylistsTable,
    Playlist,
    $$PlaylistsTableFilterComposer,
    $$PlaylistsTableOrderingComposer,
    $$PlaylistsTableAnnotationComposer,
    $$PlaylistsTableCreateCompanionBuilder,
    $$PlaylistsTableUpdateCompanionBuilder,
    (Playlist, BaseReferences<_$MoliaDatabase, $PlaylistsTable, Playlist>),
    Playlist,
    PrefetchHooks Function()> {
  $$PlaylistsTableTableManager(_$MoliaDatabase db, $PlaylistsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PlaylistsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PlaylistsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PlaylistsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> name = const Value.absent(),
            Value<int> createdAt = const Value.absent(),
            Value<String?> syncId = const Value.absent(),
            Value<int> versionPhysical = const Value.absent(),
            Value<int> versionCounter = const Value.absent(),
            Value<String> deviceId = const Value.absent(),
          }) =>
              PlaylistsCompanion(
            id: id,
            name: name,
            createdAt: createdAt,
            syncId: syncId,
            versionPhysical: versionPhysical,
            versionCounter: versionCounter,
            deviceId: deviceId,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required String name,
            required int createdAt,
            Value<String?> syncId = const Value.absent(),
            Value<int> versionPhysical = const Value.absent(),
            Value<int> versionCounter = const Value.absent(),
            Value<String> deviceId = const Value.absent(),
          }) =>
              PlaylistsCompanion.insert(
            id: id,
            name: name,
            createdAt: createdAt,
            syncId: syncId,
            versionPhysical: versionPhysical,
            versionCounter: versionCounter,
            deviceId: deviceId,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$PlaylistsTable, Playlist>(table),
                    BaseReferences<_$MoliaDatabase, $PlaylistsTable, Playlist>(
                        db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$PlaylistsTableProcessedTableManager = ProcessedTableManager<
    _$MoliaDatabase,
    $PlaylistsTable,
    Playlist,
    $$PlaylistsTableFilterComposer,
    $$PlaylistsTableOrderingComposer,
    $$PlaylistsTableAnnotationComposer,
    $$PlaylistsTableCreateCompanionBuilder,
    $$PlaylistsTableUpdateCompanionBuilder,
    (Playlist, BaseReferences<_$MoliaDatabase, $PlaylistsTable, Playlist>),
    Playlist,
    PrefetchHooks Function()>;
typedef $$PlaylistTracksTableCreateCompanionBuilder = PlaylistTracksCompanion
    Function({
  Value<int> id,
  required int playlistId,
  required String sourceKey,
  required String songId,
  required String title,
  Value<String> artist,
  Value<String> album,
  Value<String?> coverUrl,
  Value<int?> durationMs,
  Value<String> raw,
  required int addedAt,
  Value<int> sortOrder,
  Value<int> versionPhysical,
  Value<int> versionCounter,
  Value<String> deviceId,
});
typedef $$PlaylistTracksTableUpdateCompanionBuilder = PlaylistTracksCompanion
    Function({
  Value<int> id,
  Value<int> playlistId,
  Value<String> sourceKey,
  Value<String> songId,
  Value<String> title,
  Value<String> artist,
  Value<String> album,
  Value<String?> coverUrl,
  Value<int?> durationMs,
  Value<String> raw,
  Value<int> addedAt,
  Value<int> sortOrder,
  Value<int> versionPhysical,
  Value<int> versionCounter,
  Value<String> deviceId,
});

class $$PlaylistTracksTableFilterComposer
    extends Composer<_$MoliaDatabase, $PlaylistTracksTable> {
  $$PlaylistTracksTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get playlistId => $composableBuilder(
      column: $table.playlistId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get sourceKey => $composableBuilder(
      column: $table.sourceKey, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get songId => $composableBuilder(
      column: $table.songId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get title => $composableBuilder(
      column: $table.title, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get artist => $composableBuilder(
      column: $table.artist, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get album => $composableBuilder(
      column: $table.album, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get coverUrl => $composableBuilder(
      column: $table.coverUrl, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get durationMs => $composableBuilder(
      column: $table.durationMs, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get raw => $composableBuilder(
      column: $table.raw, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get addedAt => $composableBuilder(
      column: $table.addedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get sortOrder => $composableBuilder(
      column: $table.sortOrder, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get versionPhysical => $composableBuilder(
      column: $table.versionPhysical,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get versionCounter => $composableBuilder(
      column: $table.versionCounter,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get deviceId => $composableBuilder(
      column: $table.deviceId, builder: (column) => ColumnFilters(column));
}

class $$PlaylistTracksTableOrderingComposer
    extends Composer<_$MoliaDatabase, $PlaylistTracksTable> {
  $$PlaylistTracksTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get playlistId => $composableBuilder(
      column: $table.playlistId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get sourceKey => $composableBuilder(
      column: $table.sourceKey, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get songId => $composableBuilder(
      column: $table.songId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get title => $composableBuilder(
      column: $table.title, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get artist => $composableBuilder(
      column: $table.artist, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get album => $composableBuilder(
      column: $table.album, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get coverUrl => $composableBuilder(
      column: $table.coverUrl, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get durationMs => $composableBuilder(
      column: $table.durationMs, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get raw => $composableBuilder(
      column: $table.raw, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get addedAt => $composableBuilder(
      column: $table.addedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get sortOrder => $composableBuilder(
      column: $table.sortOrder, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get versionPhysical => $composableBuilder(
      column: $table.versionPhysical,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get versionCounter => $composableBuilder(
      column: $table.versionCounter,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get deviceId => $composableBuilder(
      column: $table.deviceId, builder: (column) => ColumnOrderings(column));
}

class $$PlaylistTracksTableAnnotationComposer
    extends Composer<_$MoliaDatabase, $PlaylistTracksTable> {
  $$PlaylistTracksTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get playlistId => $composableBuilder(
      column: $table.playlistId, builder: (column) => column);

  GeneratedColumn<String> get sourceKey =>
      $composableBuilder(column: $table.sourceKey, builder: (column) => column);

  GeneratedColumn<String> get songId =>
      $composableBuilder(column: $table.songId, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get artist =>
      $composableBuilder(column: $table.artist, builder: (column) => column);

  GeneratedColumn<String> get album =>
      $composableBuilder(column: $table.album, builder: (column) => column);

  GeneratedColumn<String> get coverUrl =>
      $composableBuilder(column: $table.coverUrl, builder: (column) => column);

  GeneratedColumn<int> get durationMs => $composableBuilder(
      column: $table.durationMs, builder: (column) => column);

  GeneratedColumn<String> get raw =>
      $composableBuilder(column: $table.raw, builder: (column) => column);

  GeneratedColumn<int> get addedAt =>
      $composableBuilder(column: $table.addedAt, builder: (column) => column);

  GeneratedColumn<int> get sortOrder =>
      $composableBuilder(column: $table.sortOrder, builder: (column) => column);

  GeneratedColumn<int> get versionPhysical => $composableBuilder(
      column: $table.versionPhysical, builder: (column) => column);

  GeneratedColumn<int> get versionCounter => $composableBuilder(
      column: $table.versionCounter, builder: (column) => column);

  GeneratedColumn<String> get deviceId =>
      $composableBuilder(column: $table.deviceId, builder: (column) => column);
}

class $$PlaylistTracksTableTableManager extends RootTableManager<
    _$MoliaDatabase,
    $PlaylistTracksTable,
    PlaylistTrackRow,
    $$PlaylistTracksTableFilterComposer,
    $$PlaylistTracksTableOrderingComposer,
    $$PlaylistTracksTableAnnotationComposer,
    $$PlaylistTracksTableCreateCompanionBuilder,
    $$PlaylistTracksTableUpdateCompanionBuilder,
    (
      PlaylistTrackRow,
      BaseReferences<_$MoliaDatabase, $PlaylistTracksTable, PlaylistTrackRow>
    ),
    PlaylistTrackRow,
    PrefetchHooks Function()> {
  $$PlaylistTracksTableTableManager(
      _$MoliaDatabase db, $PlaylistTracksTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PlaylistTracksTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PlaylistTracksTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PlaylistTracksTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<int> playlistId = const Value.absent(),
            Value<String> sourceKey = const Value.absent(),
            Value<String> songId = const Value.absent(),
            Value<String> title = const Value.absent(),
            Value<String> artist = const Value.absent(),
            Value<String> album = const Value.absent(),
            Value<String?> coverUrl = const Value.absent(),
            Value<int?> durationMs = const Value.absent(),
            Value<String> raw = const Value.absent(),
            Value<int> addedAt = const Value.absent(),
            Value<int> sortOrder = const Value.absent(),
            Value<int> versionPhysical = const Value.absent(),
            Value<int> versionCounter = const Value.absent(),
            Value<String> deviceId = const Value.absent(),
          }) =>
              PlaylistTracksCompanion(
            id: id,
            playlistId: playlistId,
            sourceKey: sourceKey,
            songId: songId,
            title: title,
            artist: artist,
            album: album,
            coverUrl: coverUrl,
            durationMs: durationMs,
            raw: raw,
            addedAt: addedAt,
            sortOrder: sortOrder,
            versionPhysical: versionPhysical,
            versionCounter: versionCounter,
            deviceId: deviceId,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required int playlistId,
            required String sourceKey,
            required String songId,
            required String title,
            Value<String> artist = const Value.absent(),
            Value<String> album = const Value.absent(),
            Value<String?> coverUrl = const Value.absent(),
            Value<int?> durationMs = const Value.absent(),
            Value<String> raw = const Value.absent(),
            required int addedAt,
            Value<int> sortOrder = const Value.absent(),
            Value<int> versionPhysical = const Value.absent(),
            Value<int> versionCounter = const Value.absent(),
            Value<String> deviceId = const Value.absent(),
          }) =>
              PlaylistTracksCompanion.insert(
            id: id,
            playlistId: playlistId,
            sourceKey: sourceKey,
            songId: songId,
            title: title,
            artist: artist,
            album: album,
            coverUrl: coverUrl,
            durationMs: durationMs,
            raw: raw,
            addedAt: addedAt,
            sortOrder: sortOrder,
            versionPhysical: versionPhysical,
            versionCounter: versionCounter,
            deviceId: deviceId,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$PlaylistTracksTable, PlaylistTrackRow>(table),
                    BaseReferences<_$MoliaDatabase, $PlaylistTracksTable,
                        PlaylistTrackRow>(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$PlaylistTracksTableProcessedTableManager = ProcessedTableManager<
    _$MoliaDatabase,
    $PlaylistTracksTable,
    PlaylistTrackRow,
    $$PlaylistTracksTableFilterComposer,
    $$PlaylistTracksTableOrderingComposer,
    $$PlaylistTracksTableAnnotationComposer,
    $$PlaylistTracksTableCreateCompanionBuilder,
    $$PlaylistTracksTableUpdateCompanionBuilder,
    (
      PlaylistTrackRow,
      BaseReferences<_$MoliaDatabase, $PlaylistTracksTable, PlaylistTrackRow>
    ),
    PlaylistTrackRow,
    PrefetchHooks Function()>;
typedef $$SyncTombstonesTableCreateCompanionBuilder = SyncTombstonesCompanion
    Function({
  required String category,
  required String key,
  required int versionPhysical,
  Value<int> versionCounter,
  Value<String> deviceId,
  Value<int> deletedAt,
  Value<int> rowid,
});
typedef $$SyncTombstonesTableUpdateCompanionBuilder = SyncTombstonesCompanion
    Function({
  Value<String> category,
  Value<String> key,
  Value<int> versionPhysical,
  Value<int> versionCounter,
  Value<String> deviceId,
  Value<int> deletedAt,
  Value<int> rowid,
});

class $$SyncTombstonesTableFilterComposer
    extends Composer<_$MoliaDatabase, $SyncTombstonesTable> {
  $$SyncTombstonesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get category => $composableBuilder(
      column: $table.category, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get key => $composableBuilder(
      column: $table.key, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get versionPhysical => $composableBuilder(
      column: $table.versionPhysical,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get versionCounter => $composableBuilder(
      column: $table.versionCounter,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get deviceId => $composableBuilder(
      column: $table.deviceId, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get deletedAt => $composableBuilder(
      column: $table.deletedAt, builder: (column) => ColumnFilters(column));
}

class $$SyncTombstonesTableOrderingComposer
    extends Composer<_$MoliaDatabase, $SyncTombstonesTable> {
  $$SyncTombstonesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get category => $composableBuilder(
      column: $table.category, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get key => $composableBuilder(
      column: $table.key, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get versionPhysical => $composableBuilder(
      column: $table.versionPhysical,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get versionCounter => $composableBuilder(
      column: $table.versionCounter,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get deviceId => $composableBuilder(
      column: $table.deviceId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get deletedAt => $composableBuilder(
      column: $table.deletedAt, builder: (column) => ColumnOrderings(column));
}

class $$SyncTombstonesTableAnnotationComposer
    extends Composer<_$MoliaDatabase, $SyncTombstonesTable> {
  $$SyncTombstonesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get category =>
      $composableBuilder(column: $table.category, builder: (column) => column);

  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<int> get versionPhysical => $composableBuilder(
      column: $table.versionPhysical, builder: (column) => column);

  GeneratedColumn<int> get versionCounter => $composableBuilder(
      column: $table.versionCounter, builder: (column) => column);

  GeneratedColumn<String> get deviceId =>
      $composableBuilder(column: $table.deviceId, builder: (column) => column);

  GeneratedColumn<int> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);
}

class $$SyncTombstonesTableTableManager extends RootTableManager<
    _$MoliaDatabase,
    $SyncTombstonesTable,
    SyncTombstone,
    $$SyncTombstonesTableFilterComposer,
    $$SyncTombstonesTableOrderingComposer,
    $$SyncTombstonesTableAnnotationComposer,
    $$SyncTombstonesTableCreateCompanionBuilder,
    $$SyncTombstonesTableUpdateCompanionBuilder,
    (
      SyncTombstone,
      BaseReferences<_$MoliaDatabase, $SyncTombstonesTable, SyncTombstone>
    ),
    SyncTombstone,
    PrefetchHooks Function()> {
  $$SyncTombstonesTableTableManager(
      _$MoliaDatabase db, $SyncTombstonesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SyncTombstonesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SyncTombstonesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SyncTombstonesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> category = const Value.absent(),
            Value<String> key = const Value.absent(),
            Value<int> versionPhysical = const Value.absent(),
            Value<int> versionCounter = const Value.absent(),
            Value<String> deviceId = const Value.absent(),
            Value<int> deletedAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              SyncTombstonesCompanion(
            category: category,
            key: key,
            versionPhysical: versionPhysical,
            versionCounter: versionCounter,
            deviceId: deviceId,
            deletedAt: deletedAt,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String category,
            required String key,
            required int versionPhysical,
            Value<int> versionCounter = const Value.absent(),
            Value<String> deviceId = const Value.absent(),
            Value<int> deletedAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              SyncTombstonesCompanion.insert(
            category: category,
            key: key,
            versionPhysical: versionPhysical,
            versionCounter: versionCounter,
            deviceId: deviceId,
            deletedAt: deletedAt,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$SyncTombstonesTable, SyncTombstone>(table),
                    BaseReferences<_$MoliaDatabase, $SyncTombstonesTable,
                        SyncTombstone>(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$SyncTombstonesTableProcessedTableManager = ProcessedTableManager<
    _$MoliaDatabase,
    $SyncTombstonesTable,
    SyncTombstone,
    $$SyncTombstonesTableFilterComposer,
    $$SyncTombstonesTableOrderingComposer,
    $$SyncTombstonesTableAnnotationComposer,
    $$SyncTombstonesTableCreateCompanionBuilder,
    $$SyncTombstonesTableUpdateCompanionBuilder,
    (
      SyncTombstone,
      BaseReferences<_$MoliaDatabase, $SyncTombstonesTable, SyncTombstone>
    ),
    SyncTombstone,
    PrefetchHooks Function()>;
typedef $$SyncKnownTableCreateCompanionBuilder = SyncKnownCompanion Function({
  required String category,
  required String key,
  required int versionPhysical,
  Value<int> versionCounter,
  Value<String> deviceId,
  Value<int> rowid,
});
typedef $$SyncKnownTableUpdateCompanionBuilder = SyncKnownCompanion Function({
  Value<String> category,
  Value<String> key,
  Value<int> versionPhysical,
  Value<int> versionCounter,
  Value<String> deviceId,
  Value<int> rowid,
});

class $$SyncKnownTableFilterComposer
    extends Composer<_$MoliaDatabase, $SyncKnownTable> {
  $$SyncKnownTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get category => $composableBuilder(
      column: $table.category, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get key => $composableBuilder(
      column: $table.key, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get versionPhysical => $composableBuilder(
      column: $table.versionPhysical,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get versionCounter => $composableBuilder(
      column: $table.versionCounter,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get deviceId => $composableBuilder(
      column: $table.deviceId, builder: (column) => ColumnFilters(column));
}

class $$SyncKnownTableOrderingComposer
    extends Composer<_$MoliaDatabase, $SyncKnownTable> {
  $$SyncKnownTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get category => $composableBuilder(
      column: $table.category, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get key => $composableBuilder(
      column: $table.key, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get versionPhysical => $composableBuilder(
      column: $table.versionPhysical,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get versionCounter => $composableBuilder(
      column: $table.versionCounter,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get deviceId => $composableBuilder(
      column: $table.deviceId, builder: (column) => ColumnOrderings(column));
}

class $$SyncKnownTableAnnotationComposer
    extends Composer<_$MoliaDatabase, $SyncKnownTable> {
  $$SyncKnownTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get category =>
      $composableBuilder(column: $table.category, builder: (column) => column);

  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<int> get versionPhysical => $composableBuilder(
      column: $table.versionPhysical, builder: (column) => column);

  GeneratedColumn<int> get versionCounter => $composableBuilder(
      column: $table.versionCounter, builder: (column) => column);

  GeneratedColumn<String> get deviceId =>
      $composableBuilder(column: $table.deviceId, builder: (column) => column);
}

class $$SyncKnownTableTableManager extends RootTableManager<
    _$MoliaDatabase,
    $SyncKnownTable,
    SyncKnownData,
    $$SyncKnownTableFilterComposer,
    $$SyncKnownTableOrderingComposer,
    $$SyncKnownTableAnnotationComposer,
    $$SyncKnownTableCreateCompanionBuilder,
    $$SyncKnownTableUpdateCompanionBuilder,
    (
      SyncKnownData,
      BaseReferences<_$MoliaDatabase, $SyncKnownTable, SyncKnownData>
    ),
    SyncKnownData,
    PrefetchHooks Function()> {
  $$SyncKnownTableTableManager(_$MoliaDatabase db, $SyncKnownTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SyncKnownTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SyncKnownTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SyncKnownTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> category = const Value.absent(),
            Value<String> key = const Value.absent(),
            Value<int> versionPhysical = const Value.absent(),
            Value<int> versionCounter = const Value.absent(),
            Value<String> deviceId = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              SyncKnownCompanion(
            category: category,
            key: key,
            versionPhysical: versionPhysical,
            versionCounter: versionCounter,
            deviceId: deviceId,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String category,
            required String key,
            required int versionPhysical,
            Value<int> versionCounter = const Value.absent(),
            Value<String> deviceId = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              SyncKnownCompanion.insert(
            category: category,
            key: key,
            versionPhysical: versionPhysical,
            versionCounter: versionCounter,
            deviceId: deviceId,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$SyncKnownTable, SyncKnownData>(table),
                    BaseReferences<_$MoliaDatabase, $SyncKnownTable,
                        SyncKnownData>(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$SyncKnownTableProcessedTableManager = ProcessedTableManager<
    _$MoliaDatabase,
    $SyncKnownTable,
    SyncKnownData,
    $$SyncKnownTableFilterComposer,
    $$SyncKnownTableOrderingComposer,
    $$SyncKnownTableAnnotationComposer,
    $$SyncKnownTableCreateCompanionBuilder,
    $$SyncKnownTableUpdateCompanionBuilder,
    (
      SyncKnownData,
      BaseReferences<_$MoliaDatabase, $SyncKnownTable, SyncKnownData>
    ),
    SyncKnownData,
    PrefetchHooks Function()>;
typedef $$SyncJournalTableCreateCompanionBuilder = SyncJournalCompanion
    Function({
  Value<int> seq,
  required String category,
  required String key,
  required int versionPhysical,
  Value<int> versionCounter,
  Value<String> deviceId,
  Value<bool> deleted,
  Value<String?> data,
  required int at,
});
typedef $$SyncJournalTableUpdateCompanionBuilder = SyncJournalCompanion
    Function({
  Value<int> seq,
  Value<String> category,
  Value<String> key,
  Value<int> versionPhysical,
  Value<int> versionCounter,
  Value<String> deviceId,
  Value<bool> deleted,
  Value<String?> data,
  Value<int> at,
});

class $$SyncJournalTableFilterComposer
    extends Composer<_$MoliaDatabase, $SyncJournalTable> {
  $$SyncJournalTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get seq => $composableBuilder(
      column: $table.seq, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get category => $composableBuilder(
      column: $table.category, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get key => $composableBuilder(
      column: $table.key, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get versionPhysical => $composableBuilder(
      column: $table.versionPhysical,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get versionCounter => $composableBuilder(
      column: $table.versionCounter,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get deviceId => $composableBuilder(
      column: $table.deviceId, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get deleted => $composableBuilder(
      column: $table.deleted, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get data => $composableBuilder(
      column: $table.data, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get at => $composableBuilder(
      column: $table.at, builder: (column) => ColumnFilters(column));
}

class $$SyncJournalTableOrderingComposer
    extends Composer<_$MoliaDatabase, $SyncJournalTable> {
  $$SyncJournalTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get seq => $composableBuilder(
      column: $table.seq, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get category => $composableBuilder(
      column: $table.category, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get key => $composableBuilder(
      column: $table.key, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get versionPhysical => $composableBuilder(
      column: $table.versionPhysical,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get versionCounter => $composableBuilder(
      column: $table.versionCounter,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get deviceId => $composableBuilder(
      column: $table.deviceId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get deleted => $composableBuilder(
      column: $table.deleted, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get data => $composableBuilder(
      column: $table.data, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get at => $composableBuilder(
      column: $table.at, builder: (column) => ColumnOrderings(column));
}

class $$SyncJournalTableAnnotationComposer
    extends Composer<_$MoliaDatabase, $SyncJournalTable> {
  $$SyncJournalTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get seq =>
      $composableBuilder(column: $table.seq, builder: (column) => column);

  GeneratedColumn<String> get category =>
      $composableBuilder(column: $table.category, builder: (column) => column);

  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<int> get versionPhysical => $composableBuilder(
      column: $table.versionPhysical, builder: (column) => column);

  GeneratedColumn<int> get versionCounter => $composableBuilder(
      column: $table.versionCounter, builder: (column) => column);

  GeneratedColumn<String> get deviceId =>
      $composableBuilder(column: $table.deviceId, builder: (column) => column);

  GeneratedColumn<bool> get deleted =>
      $composableBuilder(column: $table.deleted, builder: (column) => column);

  GeneratedColumn<String> get data =>
      $composableBuilder(column: $table.data, builder: (column) => column);

  GeneratedColumn<int> get at =>
      $composableBuilder(column: $table.at, builder: (column) => column);
}

class $$SyncJournalTableTableManager extends RootTableManager<
    _$MoliaDatabase,
    $SyncJournalTable,
    SyncJournalData,
    $$SyncJournalTableFilterComposer,
    $$SyncJournalTableOrderingComposer,
    $$SyncJournalTableAnnotationComposer,
    $$SyncJournalTableCreateCompanionBuilder,
    $$SyncJournalTableUpdateCompanionBuilder,
    (
      SyncJournalData,
      BaseReferences<_$MoliaDatabase, $SyncJournalTable, SyncJournalData>
    ),
    SyncJournalData,
    PrefetchHooks Function()> {
  $$SyncJournalTableTableManager(_$MoliaDatabase db, $SyncJournalTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SyncJournalTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SyncJournalTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SyncJournalTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> seq = const Value.absent(),
            Value<String> category = const Value.absent(),
            Value<String> key = const Value.absent(),
            Value<int> versionPhysical = const Value.absent(),
            Value<int> versionCounter = const Value.absent(),
            Value<String> deviceId = const Value.absent(),
            Value<bool> deleted = const Value.absent(),
            Value<String?> data = const Value.absent(),
            Value<int> at = const Value.absent(),
          }) =>
              SyncJournalCompanion(
            seq: seq,
            category: category,
            key: key,
            versionPhysical: versionPhysical,
            versionCounter: versionCounter,
            deviceId: deviceId,
            deleted: deleted,
            data: data,
            at: at,
          ),
          createCompanionCallback: ({
            Value<int> seq = const Value.absent(),
            required String category,
            required String key,
            required int versionPhysical,
            Value<int> versionCounter = const Value.absent(),
            Value<String> deviceId = const Value.absent(),
            Value<bool> deleted = const Value.absent(),
            Value<String?> data = const Value.absent(),
            required int at,
          }) =>
              SyncJournalCompanion.insert(
            seq: seq,
            category: category,
            key: key,
            versionPhysical: versionPhysical,
            versionCounter: versionCounter,
            deviceId: deviceId,
            deleted: deleted,
            data: data,
            at: at,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$SyncJournalTable, SyncJournalData>(table),
                    BaseReferences<_$MoliaDatabase, $SyncJournalTable,
                        SyncJournalData>(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$SyncJournalTableProcessedTableManager = ProcessedTableManager<
    _$MoliaDatabase,
    $SyncJournalTable,
    SyncJournalData,
    $$SyncJournalTableFilterComposer,
    $$SyncJournalTableOrderingComposer,
    $$SyncJournalTableAnnotationComposer,
    $$SyncJournalTableCreateCompanionBuilder,
    $$SyncJournalTableUpdateCompanionBuilder,
    (
      SyncJournalData,
      BaseReferences<_$MoliaDatabase, $SyncJournalTable, SyncJournalData>
    ),
    SyncJournalData,
    PrefetchHooks Function()>;
typedef $$SyncJournalStatesTableCreateCompanionBuilder
    = SyncJournalStatesCompanion Function({
  Value<int> id,
  Value<int> baseSeq,
  Value<int> snapshotSeq,
});
typedef $$SyncJournalStatesTableUpdateCompanionBuilder
    = SyncJournalStatesCompanion Function({
  Value<int> id,
  Value<int> baseSeq,
  Value<int> snapshotSeq,
});

class $$SyncJournalStatesTableFilterComposer
    extends Composer<_$MoliaDatabase, $SyncJournalStatesTable> {
  $$SyncJournalStatesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get baseSeq => $composableBuilder(
      column: $table.baseSeq, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get snapshotSeq => $composableBuilder(
      column: $table.snapshotSeq, builder: (column) => ColumnFilters(column));
}

class $$SyncJournalStatesTableOrderingComposer
    extends Composer<_$MoliaDatabase, $SyncJournalStatesTable> {
  $$SyncJournalStatesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get baseSeq => $composableBuilder(
      column: $table.baseSeq, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get snapshotSeq => $composableBuilder(
      column: $table.snapshotSeq, builder: (column) => ColumnOrderings(column));
}

class $$SyncJournalStatesTableAnnotationComposer
    extends Composer<_$MoliaDatabase, $SyncJournalStatesTable> {
  $$SyncJournalStatesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get baseSeq =>
      $composableBuilder(column: $table.baseSeq, builder: (column) => column);

  GeneratedColumn<int> get snapshotSeq => $composableBuilder(
      column: $table.snapshotSeq, builder: (column) => column);
}

class $$SyncJournalStatesTableTableManager extends RootTableManager<
    _$MoliaDatabase,
    $SyncJournalStatesTable,
    SyncJournalState,
    $$SyncJournalStatesTableFilterComposer,
    $$SyncJournalStatesTableOrderingComposer,
    $$SyncJournalStatesTableAnnotationComposer,
    $$SyncJournalStatesTableCreateCompanionBuilder,
    $$SyncJournalStatesTableUpdateCompanionBuilder,
    (
      SyncJournalState,
      BaseReferences<_$MoliaDatabase, $SyncJournalStatesTable, SyncJournalState>
    ),
    SyncJournalState,
    PrefetchHooks Function()> {
  $$SyncJournalStatesTableTableManager(
      _$MoliaDatabase db, $SyncJournalStatesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SyncJournalStatesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SyncJournalStatesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SyncJournalStatesTableAnnotationComposer(
                  $db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<int> baseSeq = const Value.absent(),
            Value<int> snapshotSeq = const Value.absent(),
          }) =>
              SyncJournalStatesCompanion(
            id: id,
            baseSeq: baseSeq,
            snapshotSeq: snapshotSeq,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<int> baseSeq = const Value.absent(),
            Value<int> snapshotSeq = const Value.absent(),
          }) =>
              SyncJournalStatesCompanion.insert(
            id: id,
            baseSeq: baseSeq,
            snapshotSeq: snapshotSeq,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$SyncJournalStatesTable, SyncJournalState>(
                        table),
                    BaseReferences<_$MoliaDatabase, $SyncJournalStatesTable,
                        SyncJournalState>(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$SyncJournalStatesTableProcessedTableManager = ProcessedTableManager<
    _$MoliaDatabase,
    $SyncJournalStatesTable,
    SyncJournalState,
    $$SyncJournalStatesTableFilterComposer,
    $$SyncJournalStatesTableOrderingComposer,
    $$SyncJournalStatesTableAnnotationComposer,
    $$SyncJournalStatesTableCreateCompanionBuilder,
    $$SyncJournalStatesTableUpdateCompanionBuilder,
    (
      SyncJournalState,
      BaseReferences<_$MoliaDatabase, $SyncJournalStatesTable, SyncJournalState>
    ),
    SyncJournalState,
    PrefetchHooks Function()>;
typedef $$PlayEventsTableCreateCompanionBuilder = PlayEventsCompanion Function({
  Value<int> id,
  required String sourceKey,
  required String songId,
  Value<String> title,
  Value<String> artist,
  Value<String> album,
  Value<String?> coverUrl,
  Value<int?> durationMs,
  Value<String> raw,
  required int startedAt,
  Value<int?> endedAt,
  Value<int> listenedMs,
  Value<int> maxPositionMs,
  Value<String?> endReason,
  Value<String?> syncKey,
  Value<String> originDeviceId,
  Value<int> versionPhysical,
  Value<int> versionCounter,
});
typedef $$PlayEventsTableUpdateCompanionBuilder = PlayEventsCompanion Function({
  Value<int> id,
  Value<String> sourceKey,
  Value<String> songId,
  Value<String> title,
  Value<String> artist,
  Value<String> album,
  Value<String?> coverUrl,
  Value<int?> durationMs,
  Value<String> raw,
  Value<int> startedAt,
  Value<int?> endedAt,
  Value<int> listenedMs,
  Value<int> maxPositionMs,
  Value<String?> endReason,
  Value<String?> syncKey,
  Value<String> originDeviceId,
  Value<int> versionPhysical,
  Value<int> versionCounter,
});

class $$PlayEventsTableFilterComposer
    extends Composer<_$MoliaDatabase, $PlayEventsTable> {
  $$PlayEventsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get sourceKey => $composableBuilder(
      column: $table.sourceKey, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get songId => $composableBuilder(
      column: $table.songId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get title => $composableBuilder(
      column: $table.title, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get artist => $composableBuilder(
      column: $table.artist, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get album => $composableBuilder(
      column: $table.album, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get coverUrl => $composableBuilder(
      column: $table.coverUrl, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get durationMs => $composableBuilder(
      column: $table.durationMs, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get raw => $composableBuilder(
      column: $table.raw, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get startedAt => $composableBuilder(
      column: $table.startedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get endedAt => $composableBuilder(
      column: $table.endedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get listenedMs => $composableBuilder(
      column: $table.listenedMs, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get maxPositionMs => $composableBuilder(
      column: $table.maxPositionMs, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get endReason => $composableBuilder(
      column: $table.endReason, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get syncKey => $composableBuilder(
      column: $table.syncKey, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get originDeviceId => $composableBuilder(
      column: $table.originDeviceId,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get versionPhysical => $composableBuilder(
      column: $table.versionPhysical,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get versionCounter => $composableBuilder(
      column: $table.versionCounter,
      builder: (column) => ColumnFilters(column));
}

class $$PlayEventsTableOrderingComposer
    extends Composer<_$MoliaDatabase, $PlayEventsTable> {
  $$PlayEventsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get sourceKey => $composableBuilder(
      column: $table.sourceKey, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get songId => $composableBuilder(
      column: $table.songId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get title => $composableBuilder(
      column: $table.title, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get artist => $composableBuilder(
      column: $table.artist, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get album => $composableBuilder(
      column: $table.album, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get coverUrl => $composableBuilder(
      column: $table.coverUrl, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get durationMs => $composableBuilder(
      column: $table.durationMs, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get raw => $composableBuilder(
      column: $table.raw, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get startedAt => $composableBuilder(
      column: $table.startedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get endedAt => $composableBuilder(
      column: $table.endedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get listenedMs => $composableBuilder(
      column: $table.listenedMs, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get maxPositionMs => $composableBuilder(
      column: $table.maxPositionMs,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get endReason => $composableBuilder(
      column: $table.endReason, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get syncKey => $composableBuilder(
      column: $table.syncKey, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get originDeviceId => $composableBuilder(
      column: $table.originDeviceId,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get versionPhysical => $composableBuilder(
      column: $table.versionPhysical,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get versionCounter => $composableBuilder(
      column: $table.versionCounter,
      builder: (column) => ColumnOrderings(column));
}

class $$PlayEventsTableAnnotationComposer
    extends Composer<_$MoliaDatabase, $PlayEventsTable> {
  $$PlayEventsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get sourceKey =>
      $composableBuilder(column: $table.sourceKey, builder: (column) => column);

  GeneratedColumn<String> get songId =>
      $composableBuilder(column: $table.songId, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get artist =>
      $composableBuilder(column: $table.artist, builder: (column) => column);

  GeneratedColumn<String> get album =>
      $composableBuilder(column: $table.album, builder: (column) => column);

  GeneratedColumn<String> get coverUrl =>
      $composableBuilder(column: $table.coverUrl, builder: (column) => column);

  GeneratedColumn<int> get durationMs => $composableBuilder(
      column: $table.durationMs, builder: (column) => column);

  GeneratedColumn<String> get raw =>
      $composableBuilder(column: $table.raw, builder: (column) => column);

  GeneratedColumn<int> get startedAt =>
      $composableBuilder(column: $table.startedAt, builder: (column) => column);

  GeneratedColumn<int> get endedAt =>
      $composableBuilder(column: $table.endedAt, builder: (column) => column);

  GeneratedColumn<int> get listenedMs => $composableBuilder(
      column: $table.listenedMs, builder: (column) => column);

  GeneratedColumn<int> get maxPositionMs => $composableBuilder(
      column: $table.maxPositionMs, builder: (column) => column);

  GeneratedColumn<String> get endReason =>
      $composableBuilder(column: $table.endReason, builder: (column) => column);

  GeneratedColumn<String> get syncKey =>
      $composableBuilder(column: $table.syncKey, builder: (column) => column);

  GeneratedColumn<String> get originDeviceId => $composableBuilder(
      column: $table.originDeviceId, builder: (column) => column);

  GeneratedColumn<int> get versionPhysical => $composableBuilder(
      column: $table.versionPhysical, builder: (column) => column);

  GeneratedColumn<int> get versionCounter => $composableBuilder(
      column: $table.versionCounter, builder: (column) => column);
}

class $$PlayEventsTableTableManager extends RootTableManager<
    _$MoliaDatabase,
    $PlayEventsTable,
    PlayEventRow,
    $$PlayEventsTableFilterComposer,
    $$PlayEventsTableOrderingComposer,
    $$PlayEventsTableAnnotationComposer,
    $$PlayEventsTableCreateCompanionBuilder,
    $$PlayEventsTableUpdateCompanionBuilder,
    (
      PlayEventRow,
      BaseReferences<_$MoliaDatabase, $PlayEventsTable, PlayEventRow>
    ),
    PlayEventRow,
    PrefetchHooks Function()> {
  $$PlayEventsTableTableManager(_$MoliaDatabase db, $PlayEventsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PlayEventsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PlayEventsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PlayEventsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> sourceKey = const Value.absent(),
            Value<String> songId = const Value.absent(),
            Value<String> title = const Value.absent(),
            Value<String> artist = const Value.absent(),
            Value<String> album = const Value.absent(),
            Value<String?> coverUrl = const Value.absent(),
            Value<int?> durationMs = const Value.absent(),
            Value<String> raw = const Value.absent(),
            Value<int> startedAt = const Value.absent(),
            Value<int?> endedAt = const Value.absent(),
            Value<int> listenedMs = const Value.absent(),
            Value<int> maxPositionMs = const Value.absent(),
            Value<String?> endReason = const Value.absent(),
            Value<String?> syncKey = const Value.absent(),
            Value<String> originDeviceId = const Value.absent(),
            Value<int> versionPhysical = const Value.absent(),
            Value<int> versionCounter = const Value.absent(),
          }) =>
              PlayEventsCompanion(
            id: id,
            sourceKey: sourceKey,
            songId: songId,
            title: title,
            artist: artist,
            album: album,
            coverUrl: coverUrl,
            durationMs: durationMs,
            raw: raw,
            startedAt: startedAt,
            endedAt: endedAt,
            listenedMs: listenedMs,
            maxPositionMs: maxPositionMs,
            endReason: endReason,
            syncKey: syncKey,
            originDeviceId: originDeviceId,
            versionPhysical: versionPhysical,
            versionCounter: versionCounter,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required String sourceKey,
            required String songId,
            Value<String> title = const Value.absent(),
            Value<String> artist = const Value.absent(),
            Value<String> album = const Value.absent(),
            Value<String?> coverUrl = const Value.absent(),
            Value<int?> durationMs = const Value.absent(),
            Value<String> raw = const Value.absent(),
            required int startedAt,
            Value<int?> endedAt = const Value.absent(),
            Value<int> listenedMs = const Value.absent(),
            Value<int> maxPositionMs = const Value.absent(),
            Value<String?> endReason = const Value.absent(),
            Value<String?> syncKey = const Value.absent(),
            Value<String> originDeviceId = const Value.absent(),
            Value<int> versionPhysical = const Value.absent(),
            Value<int> versionCounter = const Value.absent(),
          }) =>
              PlayEventsCompanion.insert(
            id: id,
            sourceKey: sourceKey,
            songId: songId,
            title: title,
            artist: artist,
            album: album,
            coverUrl: coverUrl,
            durationMs: durationMs,
            raw: raw,
            startedAt: startedAt,
            endedAt: endedAt,
            listenedMs: listenedMs,
            maxPositionMs: maxPositionMs,
            endReason: endReason,
            syncKey: syncKey,
            originDeviceId: originDeviceId,
            versionPhysical: versionPhysical,
            versionCounter: versionCounter,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$PlayEventsTable, PlayEventRow>(table),
                    BaseReferences<_$MoliaDatabase, $PlayEventsTable,
                        PlayEventRow>(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$PlayEventsTableProcessedTableManager = ProcessedTableManager<
    _$MoliaDatabase,
    $PlayEventsTable,
    PlayEventRow,
    $$PlayEventsTableFilterComposer,
    $$PlayEventsTableOrderingComposer,
    $$PlayEventsTableAnnotationComposer,
    $$PlayEventsTableCreateCompanionBuilder,
    $$PlayEventsTableUpdateCompanionBuilder,
    (
      PlayEventRow,
      BaseReferences<_$MoliaDatabase, $PlayEventsTable, PlayEventRow>
    ),
    PlayEventRow,
    PrefetchHooks Function()>;
typedef $$DownloadsTableCreateCompanionBuilder = DownloadsCompanion Function({
  Value<int> id,
  required String originSourceKey,
  required String originSongId,
  required String title,
  Value<String> artist,
  Value<String> album,
  Value<String?> coverUrl,
  Value<int?> durationMs,
  Value<String> raw,
  Value<String> quality,
  Value<String?> filePath,
  Value<int> sizeBytes,
  Value<String?> lyricPath,
  Value<String?> coverPath,
  Value<String?> publicUri,
  Value<bool> imported,
  required int downloadedAt,
});
typedef $$DownloadsTableUpdateCompanionBuilder = DownloadsCompanion Function({
  Value<int> id,
  Value<String> originSourceKey,
  Value<String> originSongId,
  Value<String> title,
  Value<String> artist,
  Value<String> album,
  Value<String?> coverUrl,
  Value<int?> durationMs,
  Value<String> raw,
  Value<String> quality,
  Value<String?> filePath,
  Value<int> sizeBytes,
  Value<String?> lyricPath,
  Value<String?> coverPath,
  Value<String?> publicUri,
  Value<bool> imported,
  Value<int> downloadedAt,
});

class $$DownloadsTableFilterComposer
    extends Composer<_$MoliaDatabase, $DownloadsTable> {
  $$DownloadsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get originSourceKey => $composableBuilder(
      column: $table.originSourceKey,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get originSongId => $composableBuilder(
      column: $table.originSongId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get title => $composableBuilder(
      column: $table.title, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get artist => $composableBuilder(
      column: $table.artist, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get album => $composableBuilder(
      column: $table.album, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get coverUrl => $composableBuilder(
      column: $table.coverUrl, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get durationMs => $composableBuilder(
      column: $table.durationMs, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get raw => $composableBuilder(
      column: $table.raw, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get quality => $composableBuilder(
      column: $table.quality, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get filePath => $composableBuilder(
      column: $table.filePath, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get sizeBytes => $composableBuilder(
      column: $table.sizeBytes, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get lyricPath => $composableBuilder(
      column: $table.lyricPath, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get coverPath => $composableBuilder(
      column: $table.coverPath, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get publicUri => $composableBuilder(
      column: $table.publicUri, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get imported => $composableBuilder(
      column: $table.imported, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get downloadedAt => $composableBuilder(
      column: $table.downloadedAt, builder: (column) => ColumnFilters(column));
}

class $$DownloadsTableOrderingComposer
    extends Composer<_$MoliaDatabase, $DownloadsTable> {
  $$DownloadsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get originSourceKey => $composableBuilder(
      column: $table.originSourceKey,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get originSongId => $composableBuilder(
      column: $table.originSongId,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get title => $composableBuilder(
      column: $table.title, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get artist => $composableBuilder(
      column: $table.artist, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get album => $composableBuilder(
      column: $table.album, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get coverUrl => $composableBuilder(
      column: $table.coverUrl, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get durationMs => $composableBuilder(
      column: $table.durationMs, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get raw => $composableBuilder(
      column: $table.raw, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get quality => $composableBuilder(
      column: $table.quality, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get filePath => $composableBuilder(
      column: $table.filePath, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get sizeBytes => $composableBuilder(
      column: $table.sizeBytes, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get lyricPath => $composableBuilder(
      column: $table.lyricPath, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get coverPath => $composableBuilder(
      column: $table.coverPath, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get publicUri => $composableBuilder(
      column: $table.publicUri, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get imported => $composableBuilder(
      column: $table.imported, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get downloadedAt => $composableBuilder(
      column: $table.downloadedAt,
      builder: (column) => ColumnOrderings(column));
}

class $$DownloadsTableAnnotationComposer
    extends Composer<_$MoliaDatabase, $DownloadsTable> {
  $$DownloadsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get originSourceKey => $composableBuilder(
      column: $table.originSourceKey, builder: (column) => column);

  GeneratedColumn<String> get originSongId => $composableBuilder(
      column: $table.originSongId, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get artist =>
      $composableBuilder(column: $table.artist, builder: (column) => column);

  GeneratedColumn<String> get album =>
      $composableBuilder(column: $table.album, builder: (column) => column);

  GeneratedColumn<String> get coverUrl =>
      $composableBuilder(column: $table.coverUrl, builder: (column) => column);

  GeneratedColumn<int> get durationMs => $composableBuilder(
      column: $table.durationMs, builder: (column) => column);

  GeneratedColumn<String> get raw =>
      $composableBuilder(column: $table.raw, builder: (column) => column);

  GeneratedColumn<String> get quality =>
      $composableBuilder(column: $table.quality, builder: (column) => column);

  GeneratedColumn<String> get filePath =>
      $composableBuilder(column: $table.filePath, builder: (column) => column);

  GeneratedColumn<int> get sizeBytes =>
      $composableBuilder(column: $table.sizeBytes, builder: (column) => column);

  GeneratedColumn<String> get lyricPath =>
      $composableBuilder(column: $table.lyricPath, builder: (column) => column);

  GeneratedColumn<String> get coverPath =>
      $composableBuilder(column: $table.coverPath, builder: (column) => column);

  GeneratedColumn<String> get publicUri =>
      $composableBuilder(column: $table.publicUri, builder: (column) => column);

  GeneratedColumn<bool> get imported =>
      $composableBuilder(column: $table.imported, builder: (column) => column);

  GeneratedColumn<int> get downloadedAt => $composableBuilder(
      column: $table.downloadedAt, builder: (column) => column);
}

class $$DownloadsTableTableManager extends RootTableManager<
    _$MoliaDatabase,
    $DownloadsTable,
    DownloadRow,
    $$DownloadsTableFilterComposer,
    $$DownloadsTableOrderingComposer,
    $$DownloadsTableAnnotationComposer,
    $$DownloadsTableCreateCompanionBuilder,
    $$DownloadsTableUpdateCompanionBuilder,
    (
      DownloadRow,
      BaseReferences<_$MoliaDatabase, $DownloadsTable, DownloadRow>
    ),
    DownloadRow,
    PrefetchHooks Function()> {
  $$DownloadsTableTableManager(_$MoliaDatabase db, $DownloadsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$DownloadsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$DownloadsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$DownloadsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> originSourceKey = const Value.absent(),
            Value<String> originSongId = const Value.absent(),
            Value<String> title = const Value.absent(),
            Value<String> artist = const Value.absent(),
            Value<String> album = const Value.absent(),
            Value<String?> coverUrl = const Value.absent(),
            Value<int?> durationMs = const Value.absent(),
            Value<String> raw = const Value.absent(),
            Value<String> quality = const Value.absent(),
            Value<String?> filePath = const Value.absent(),
            Value<int> sizeBytes = const Value.absent(),
            Value<String?> lyricPath = const Value.absent(),
            Value<String?> coverPath = const Value.absent(),
            Value<String?> publicUri = const Value.absent(),
            Value<bool> imported = const Value.absent(),
            Value<int> downloadedAt = const Value.absent(),
          }) =>
              DownloadsCompanion(
            id: id,
            originSourceKey: originSourceKey,
            originSongId: originSongId,
            title: title,
            artist: artist,
            album: album,
            coverUrl: coverUrl,
            durationMs: durationMs,
            raw: raw,
            quality: quality,
            filePath: filePath,
            sizeBytes: sizeBytes,
            lyricPath: lyricPath,
            coverPath: coverPath,
            publicUri: publicUri,
            imported: imported,
            downloadedAt: downloadedAt,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required String originSourceKey,
            required String originSongId,
            required String title,
            Value<String> artist = const Value.absent(),
            Value<String> album = const Value.absent(),
            Value<String?> coverUrl = const Value.absent(),
            Value<int?> durationMs = const Value.absent(),
            Value<String> raw = const Value.absent(),
            Value<String> quality = const Value.absent(),
            Value<String?> filePath = const Value.absent(),
            Value<int> sizeBytes = const Value.absent(),
            Value<String?> lyricPath = const Value.absent(),
            Value<String?> coverPath = const Value.absent(),
            Value<String?> publicUri = const Value.absent(),
            Value<bool> imported = const Value.absent(),
            required int downloadedAt,
          }) =>
              DownloadsCompanion.insert(
            id: id,
            originSourceKey: originSourceKey,
            originSongId: originSongId,
            title: title,
            artist: artist,
            album: album,
            coverUrl: coverUrl,
            durationMs: durationMs,
            raw: raw,
            quality: quality,
            filePath: filePath,
            sizeBytes: sizeBytes,
            lyricPath: lyricPath,
            coverPath: coverPath,
            publicUri: publicUri,
            imported: imported,
            downloadedAt: downloadedAt,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$DownloadsTable, DownloadRow>(table),
                    BaseReferences<_$MoliaDatabase, $DownloadsTable,
                        DownloadRow>(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$DownloadsTableProcessedTableManager = ProcessedTableManager<
    _$MoliaDatabase,
    $DownloadsTable,
    DownloadRow,
    $$DownloadsTableFilterComposer,
    $$DownloadsTableOrderingComposer,
    $$DownloadsTableAnnotationComposer,
    $$DownloadsTableCreateCompanionBuilder,
    $$DownloadsTableUpdateCompanionBuilder,
    (
      DownloadRow,
      BaseReferences<_$MoliaDatabase, $DownloadsTable, DownloadRow>
    ),
    DownloadRow,
    PrefetchHooks Function()>;

class $MoliaDatabaseManager {
  final _$MoliaDatabase _db;
  $MoliaDatabaseManager(this._db);
  $$PlayContextsTableTableManager get playContexts =>
      $$PlayContextsTableTableManager(_db, _db.playContexts);
  $$PlayHistoryTableTableManager get playHistory =>
      $$PlayHistoryTableTableManager(_db, _db.playHistory);
  $$PlaylistsTableTableManager get playlists =>
      $$PlaylistsTableTableManager(_db, _db.playlists);
  $$PlaylistTracksTableTableManager get playlistTracks =>
      $$PlaylistTracksTableTableManager(_db, _db.playlistTracks);
  $$SyncTombstonesTableTableManager get syncTombstones =>
      $$SyncTombstonesTableTableManager(_db, _db.syncTombstones);
  $$SyncKnownTableTableManager get syncKnown =>
      $$SyncKnownTableTableManager(_db, _db.syncKnown);
  $$SyncJournalTableTableManager get syncJournal =>
      $$SyncJournalTableTableManager(_db, _db.syncJournal);
  $$SyncJournalStatesTableTableManager get syncJournalStates =>
      $$SyncJournalStatesTableTableManager(_db, _db.syncJournalStates);
  $$PlayEventsTableTableManager get playEvents =>
      $$PlayEventsTableTableManager(_db, _db.playEvents);
  $$DownloadsTableTableManager get downloads =>
      $$DownloadsTableTableManager(_db, _db.downloads);
}
