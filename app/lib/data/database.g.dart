// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'database.dart';

// ignore_for_file: type=lint
class $RecordsTable extends Records with TableInfo<$RecordsTable, StoredRecord> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $RecordsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _collectionMeta = const VerificationMeta('collection');
  @override
  late final GeneratedColumn<String> collection = GeneratedColumn<String>(
    'collection',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _noteMeta = const VerificationMeta('note');
  @override
  late final GeneratedColumn<String> note = GeneratedColumn<String>(
    'note',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _dataMeta = const VerificationMeta('data');
  @override
  late final GeneratedColumn<String> data = GeneratedColumn<String>(
    'data',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [collection, id, note, data];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'records';
  @override
  VerificationContext validateIntegrity(Insertable<StoredRecord> instance, {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('collection')) {
      context.handle(_collectionMeta, collection.isAcceptableOrUnknown(data['collection']!, _collectionMeta));
    } else if (isInserting) {
      context.missing(_collectionMeta);
    }
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('note')) {
      context.handle(_noteMeta, note.isAcceptableOrUnknown(data['note']!, _noteMeta));
    }
    if (data.containsKey('data')) {
      context.handle(_dataMeta, this.data.isAcceptableOrUnknown(data['data']!, _dataMeta));
    } else if (isInserting) {
      context.missing(_dataMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {collection, id};
  @override
  StoredRecord map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return StoredRecord(
      collection: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}collection'])!,
      id: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      note: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}note'])!,
      data: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}data'])!,
    );
  }

  @override
  $RecordsTable createAlias(String alias) {
    return $RecordsTable(attachedDatabase, alias);
  }
}

class StoredRecord extends DataClass implements Insertable<StoredRecord> {
  final String collection;
  final String id;

  /// The note a record belongs to (a note belongs to itself), for revokes.
  final String note;
  final String data;
  const StoredRecord({required this.collection, required this.id, required this.note, required this.data});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['collection'] = Variable<String>(collection);
    map['id'] = Variable<String>(id);
    map['note'] = Variable<String>(note);
    map['data'] = Variable<String>(data);
    return map;
  }

  RecordsCompanion toCompanion(bool nullToAbsent) {
    return RecordsCompanion(collection: Value(collection), id: Value(id), note: Value(note), data: Value(data));
  }

  factory StoredRecord.fromJson(Map<String, dynamic> json, {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return StoredRecord(
      collection: serializer.fromJson<String>(json['collection']),
      id: serializer.fromJson<String>(json['id']),
      note: serializer.fromJson<String>(json['note']),
      data: serializer.fromJson<String>(json['data']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'collection': serializer.toJson<String>(collection),
      'id': serializer.toJson<String>(id),
      'note': serializer.toJson<String>(note),
      'data': serializer.toJson<String>(data),
    };
  }

  StoredRecord copyWith({String? collection, String? id, String? note, String? data}) => StoredRecord(
    collection: collection ?? this.collection,
    id: id ?? this.id,
    note: note ?? this.note,
    data: data ?? this.data,
  );
  StoredRecord copyWithCompanion(RecordsCompanion data) {
    return StoredRecord(
      collection: data.collection.present ? data.collection.value : this.collection,
      id: data.id.present ? data.id.value : this.id,
      note: data.note.present ? data.note.value : this.note,
      data: data.data.present ? data.data.value : this.data,
    );
  }

  @override
  String toString() {
    return (StringBuffer('StoredRecord(')
          ..write('collection: $collection, ')
          ..write('id: $id, ')
          ..write('note: $note, ')
          ..write('data: $data')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(collection, id, note, data);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StoredRecord &&
          other.collection == this.collection &&
          other.id == this.id &&
          other.note == this.note &&
          other.data == this.data);
}

class RecordsCompanion extends UpdateCompanion<StoredRecord> {
  final Value<String> collection;
  final Value<String> id;
  final Value<String> note;
  final Value<String> data;
  final Value<int> rowid;
  const RecordsCompanion({
    this.collection = const Value.absent(),
    this.id = const Value.absent(),
    this.note = const Value.absent(),
    this.data = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  RecordsCompanion.insert({
    required String collection,
    required String id,
    this.note = const Value.absent(),
    required String data,
    this.rowid = const Value.absent(),
  }) : collection = Value(collection),
       id = Value(id),
       data = Value(data);
  static Insertable<StoredRecord> custom({
    Expression<String>? collection,
    Expression<String>? id,
    Expression<String>? note,
    Expression<String>? data,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (collection != null) 'collection': collection,
      if (id != null) 'id': id,
      if (note != null) 'note': note,
      if (data != null) 'data': data,
      if (rowid != null) 'rowid': rowid,
    });
  }

  RecordsCompanion copyWith({
    Value<String>? collection,
    Value<String>? id,
    Value<String>? note,
    Value<String>? data,
    Value<int>? rowid,
  }) {
    return RecordsCompanion(
      collection: collection ?? this.collection,
      id: id ?? this.id,
      note: note ?? this.note,
      data: data ?? this.data,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (collection.present) {
      map['collection'] = Variable<String>(collection.value);
    }
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (note.present) {
      map['note'] = Variable<String>(note.value);
    }
    if (data.present) {
      map['data'] = Variable<String>(data.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('RecordsCompanion(')
          ..write('collection: $collection, ')
          ..write('id: $id, ')
          ..write('note: $note, ')
          ..write('data: $data, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $OutboxTable extends Outbox with TableInfo<$OutboxTable, OutboxData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $OutboxTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _seqMeta = const VerificationMeta('seq');
  @override
  late final GeneratedColumn<int> seq = GeneratedColumn<int>(
    'seq',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'),
  );
  static const VerificationMeta _opMeta = const VerificationMeta('op');
  @override
  late final GeneratedColumn<String> op = GeneratedColumn<String>(
    'op',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdMeta = const VerificationMeta('created');
  @override
  late final GeneratedColumn<String> created = GeneratedColumn<String>(
    'created',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [seq, op, created];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'outbox';
  @override
  VerificationContext validateIntegrity(Insertable<OutboxData> instance, {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('seq')) {
      context.handle(_seqMeta, seq.isAcceptableOrUnknown(data['seq']!, _seqMeta));
    }
    if (data.containsKey('op')) {
      context.handle(_opMeta, op.isAcceptableOrUnknown(data['op']!, _opMeta));
    } else if (isInserting) {
      context.missing(_opMeta);
    }
    if (data.containsKey('created')) {
      context.handle(_createdMeta, created.isAcceptableOrUnknown(data['created']!, _createdMeta));
    } else if (isInserting) {
      context.missing(_createdMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {seq};
  @override
  OutboxData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return OutboxData(
      seq: attachedDatabase.typeMapping.read(DriftSqlType.int, data['${effectivePrefix}seq'])!,
      op: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}op'])!,
      created: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}created'])!,
    );
  }

  @override
  $OutboxTable createAlias(String alias) {
    return $OutboxTable(attachedDatabase, alias);
  }
}

class OutboxData extends DataClass implements Insertable<OutboxData> {
  final int seq;
  final String op;
  final String created;
  const OutboxData({required this.seq, required this.op, required this.created});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['seq'] = Variable<int>(seq);
    map['op'] = Variable<String>(op);
    map['created'] = Variable<String>(created);
    return map;
  }

  OutboxCompanion toCompanion(bool nullToAbsent) {
    return OutboxCompanion(seq: Value(seq), op: Value(op), created: Value(created));
  }

  factory OutboxData.fromJson(Map<String, dynamic> json, {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return OutboxData(
      seq: serializer.fromJson<int>(json['seq']),
      op: serializer.fromJson<String>(json['op']),
      created: serializer.fromJson<String>(json['created']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'seq': serializer.toJson<int>(seq),
      'op': serializer.toJson<String>(op),
      'created': serializer.toJson<String>(created),
    };
  }

  OutboxData copyWith({int? seq, String? op, String? created}) =>
      OutboxData(seq: seq ?? this.seq, op: op ?? this.op, created: created ?? this.created);
  OutboxData copyWithCompanion(OutboxCompanion data) {
    return OutboxData(
      seq: data.seq.present ? data.seq.value : this.seq,
      op: data.op.present ? data.op.value : this.op,
      created: data.created.present ? data.created.value : this.created,
    );
  }

  @override
  String toString() {
    return (StringBuffer('OutboxData(')
          ..write('seq: $seq, ')
          ..write('op: $op, ')
          ..write('created: $created')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(seq, op, created);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is OutboxData && other.seq == this.seq && other.op == this.op && other.created == this.created);
}

class OutboxCompanion extends UpdateCompanion<OutboxData> {
  final Value<int> seq;
  final Value<String> op;
  final Value<String> created;
  const OutboxCompanion({
    this.seq = const Value.absent(),
    this.op = const Value.absent(),
    this.created = const Value.absent(),
  });
  OutboxCompanion.insert({this.seq = const Value.absent(), required String op, required String created})
    : op = Value(op),
      created = Value(created);
  static Insertable<OutboxData> custom({Expression<int>? seq, Expression<String>? op, Expression<String>? created}) {
    return RawValuesInsertable({
      if (seq != null) 'seq': seq,
      if (op != null) 'op': op,
      if (created != null) 'created': created,
    });
  }

  OutboxCompanion copyWith({Value<int>? seq, Value<String>? op, Value<String>? created}) {
    return OutboxCompanion(seq: seq ?? this.seq, op: op ?? this.op, created: created ?? this.created);
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (seq.present) {
      map['seq'] = Variable<int>(seq.value);
    }
    if (op.present) {
      map['op'] = Variable<String>(op.value);
    }
    if (created.present) {
      map['created'] = Variable<String>(created.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('OutboxCompanion(')
          ..write('seq: $seq, ')
          ..write('op: $op, ')
          ..write('created: $created')
          ..write(')'))
        .toString();
  }
}

class $MetaTable extends Meta with TableInfo<$MetaTable, MetaData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MetaTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
    'key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
    'value',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [key, value];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'meta';
  @override
  VerificationContext validateIntegrity(Insertable<MetaData> instance, {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(_keyMeta, key.isAcceptableOrUnknown(data['key']!, _keyMeta));
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value')) {
      context.handle(_valueMeta, value.isAcceptableOrUnknown(data['value']!, _valueMeta));
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  MetaData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MetaData(
      key: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}key'])!,
      value: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}value'])!,
    );
  }

  @override
  $MetaTable createAlias(String alias) {
    return $MetaTable(attachedDatabase, alias);
  }
}

class MetaData extends DataClass implements Insertable<MetaData> {
  final String key;
  final String value;
  const MetaData({required this.key, required this.value});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value'] = Variable<String>(value);
    return map;
  }

  MetaCompanion toCompanion(bool nullToAbsent) {
    return MetaCompanion(key: Value(key), value: Value(value));
  }

  factory MetaData.fromJson(Map<String, dynamic> json, {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MetaData(key: serializer.fromJson<String>(json['key']), value: serializer.fromJson<String>(json['value']));
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{'key': serializer.toJson<String>(key), 'value': serializer.toJson<String>(value)};
  }

  MetaData copyWith({String? key, String? value}) => MetaData(key: key ?? this.key, value: value ?? this.value);
  MetaData copyWithCompanion(MetaCompanion data) {
    return MetaData(
      key: data.key.present ? data.key.value : this.key,
      value: data.value.present ? data.value.value : this.value,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MetaData(')
          ..write('key: $key, ')
          ..write('value: $value')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, value);
  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is MetaData && other.key == this.key && other.value == this.value);
}

class MetaCompanion extends UpdateCompanion<MetaData> {
  final Value<String> key;
  final Value<String> value;
  final Value<int> rowid;
  const MetaCompanion({
    this.key = const Value.absent(),
    this.value = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MetaCompanion.insert({required String key, required String value, this.rowid = const Value.absent()})
    : key = Value(key),
      value = Value(value);
  static Insertable<MetaData> custom({Expression<String>? key, Expression<String>? value, Expression<int>? rowid}) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (value != null) 'value': value,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MetaCompanion copyWith({Value<String>? key, Value<String>? value, Value<int>? rowid}) {
    return MetaCompanion(key: key ?? this.key, value: value ?? this.value, rowid: rowid ?? this.rowid);
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (value.present) {
      map['value'] = Variable<String>(value.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MetaCompanion(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$ChitDb extends GeneratedDatabase {
  _$ChitDb(QueryExecutor e) : super(e);
  $ChitDbManager get managers => $ChitDbManager(this);
  late final $RecordsTable records = $RecordsTable(this);
  late final $OutboxTable outbox = $OutboxTable(this);
  late final $MetaTable meta = $MetaTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables => allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [records, outbox, meta];
}

typedef $$RecordsTableCreateCompanionBuilder = RecordsCompanion Function({
  required String collection,
  required String id,
  Value<String> note,
  required String data,
  Value<int> rowid,
});
typedef $$RecordsTableUpdateCompanionBuilder = RecordsCompanion Function({
  Value<String> collection,
  Value<String> id,
  Value<String> note,
  Value<String> data,
  Value<int> rowid,
});

class $$RecordsTableFilterComposer extends Composer<_$ChitDb, $RecordsTable> {
  $$RecordsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get collection =>
      $composableBuilder(column: $table.collection, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get id => $composableBuilder(column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get note => $composableBuilder(column: $table.note, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get data => $composableBuilder(column: $table.data, builder: (column) => ColumnFilters(column));
}

class $$RecordsTableOrderingComposer extends Composer<_$ChitDb, $RecordsTable> {
  $$RecordsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get collection =>
      $composableBuilder(column: $table.collection, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get id => $composableBuilder(column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get note =>
      $composableBuilder(column: $table.note, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get data =>
      $composableBuilder(column: $table.data, builder: (column) => ColumnOrderings(column));
}

class $$RecordsTableAnnotationComposer extends Composer<_$ChitDb, $RecordsTable> {
  $$RecordsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get collection => $composableBuilder(column: $table.collection, builder: (column) => column);

  GeneratedColumn<String> get id => $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get note => $composableBuilder(column: $table.note, builder: (column) => column);

  GeneratedColumn<String> get data => $composableBuilder(column: $table.data, builder: (column) => column);
}

class $$RecordsTableTableManager
    extends
        RootTableManager<
          _$ChitDb,
          $RecordsTable,
          StoredRecord,
          $$RecordsTableFilterComposer,
          $$RecordsTableOrderingComposer,
          $$RecordsTableAnnotationComposer,
          $$RecordsTableCreateCompanionBuilder,
          $$RecordsTableUpdateCompanionBuilder,
          (StoredRecord, BaseReferences<_$ChitDb, $RecordsTable, StoredRecord>),
          StoredRecord,
          PrefetchHooks Function()
        > {
  $$RecordsTableTableManager(_$ChitDb db, $RecordsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () => $$RecordsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () => $$RecordsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () => $$RecordsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> collection = const Value.absent(),
            Value<String> id = const Value.absent(),
            Value<String> note = const Value.absent(),
            Value<String> data = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) => RecordsCompanion(collection: collection, id: id, note: note, data: data, rowid: rowid),
          createCompanionCallback: ({
            required String collection,
            required String id,
            Value<String> note = const Value.absent(),
            required String data,
            Value<int> rowid = const Value.absent(),
          }) => RecordsCompanion.insert(collection: collection, id: id, note: note, data: data, rowid: rowid),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$RecordsTable, StoredRecord>(table),
                  BaseReferences<_$ChitDb, $RecordsTable, StoredRecord>(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$RecordsTableProcessedTableManager =
    ProcessedTableManager<
      _$ChitDb,
      $RecordsTable,
      StoredRecord,
      $$RecordsTableFilterComposer,
      $$RecordsTableOrderingComposer,
      $$RecordsTableAnnotationComposer,
      $$RecordsTableCreateCompanionBuilder,
      $$RecordsTableUpdateCompanionBuilder,
      (StoredRecord, BaseReferences<_$ChitDb, $RecordsTable, StoredRecord>),
      StoredRecord,
      PrefetchHooks Function()
    >;
typedef $$OutboxTableCreateCompanionBuilder = OutboxCompanion Function({
  Value<int> seq,
  required String op,
  required String created,
});
typedef $$OutboxTableUpdateCompanionBuilder = OutboxCompanion Function({
  Value<int> seq,
  Value<String> op,
  Value<String> created,
});

class $$OutboxTableFilterComposer extends Composer<_$ChitDb, $OutboxTable> {
  $$OutboxTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get seq => $composableBuilder(column: $table.seq, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get op => $composableBuilder(column: $table.op, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get created =>
      $composableBuilder(column: $table.created, builder: (column) => ColumnFilters(column));
}

class $$OutboxTableOrderingComposer extends Composer<_$ChitDb, $OutboxTable> {
  $$OutboxTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get seq => $composableBuilder(column: $table.seq, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get op => $composableBuilder(column: $table.op, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get created =>
      $composableBuilder(column: $table.created, builder: (column) => ColumnOrderings(column));
}

class $$OutboxTableAnnotationComposer extends Composer<_$ChitDb, $OutboxTable> {
  $$OutboxTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get seq => $composableBuilder(column: $table.seq, builder: (column) => column);

  GeneratedColumn<String> get op => $composableBuilder(column: $table.op, builder: (column) => column);

  GeneratedColumn<String> get created => $composableBuilder(column: $table.created, builder: (column) => column);
}

class $$OutboxTableTableManager
    extends
        RootTableManager<
          _$ChitDb,
          $OutboxTable,
          OutboxData,
          $$OutboxTableFilterComposer,
          $$OutboxTableOrderingComposer,
          $$OutboxTableAnnotationComposer,
          $$OutboxTableCreateCompanionBuilder,
          $$OutboxTableUpdateCompanionBuilder,
          (OutboxData, BaseReferences<_$ChitDb, $OutboxTable, OutboxData>),
          OutboxData,
          PrefetchHooks Function()
        > {
  $$OutboxTableTableManager(_$ChitDb db, $OutboxTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () => $$OutboxTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () => $$OutboxTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () => $$OutboxTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> seq = const Value.absent(),
            Value<String> op = const Value.absent(),
            Value<String> created = const Value.absent(),
          }) => OutboxCompanion(seq: seq, op: op, created: created),
          createCompanionCallback: ({
            Value<int> seq = const Value.absent(),
            required String op,
            required String created,
          }) => OutboxCompanion.insert(seq: seq, op: op, created: created),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$OutboxTable, OutboxData>(table),
                  BaseReferences<_$ChitDb, $OutboxTable, OutboxData>(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$OutboxTableProcessedTableManager =
    ProcessedTableManager<
      _$ChitDb,
      $OutboxTable,
      OutboxData,
      $$OutboxTableFilterComposer,
      $$OutboxTableOrderingComposer,
      $$OutboxTableAnnotationComposer,
      $$OutboxTableCreateCompanionBuilder,
      $$OutboxTableUpdateCompanionBuilder,
      (OutboxData, BaseReferences<_$ChitDb, $OutboxTable, OutboxData>),
      OutboxData,
      PrefetchHooks Function()
    >;
typedef $$MetaTableCreateCompanionBuilder = MetaCompanion Function({
  required String key,
  required String value,
  Value<int> rowid,
});
typedef $$MetaTableUpdateCompanionBuilder = MetaCompanion Function({
  Value<String> key,
  Value<String> value,
  Value<int> rowid,
});

class $$MetaTableFilterComposer extends Composer<_$ChitDb, $MetaTable> {
  $$MetaTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(column: $table.key, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => ColumnFilters(column));
}

class $$MetaTableOrderingComposer extends Composer<_$ChitDb, $MetaTable> {
  $$MetaTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => ColumnOrderings(column));
}

class $$MetaTableAnnotationComposer extends Composer<_$ChitDb, $MetaTable> {
  $$MetaTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key => $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get value => $composableBuilder(column: $table.value, builder: (column) => column);
}

class $$MetaTableTableManager
    extends
        RootTableManager<
          _$ChitDb,
          $MetaTable,
          MetaData,
          $$MetaTableFilterComposer,
          $$MetaTableOrderingComposer,
          $$MetaTableAnnotationComposer,
          $$MetaTableCreateCompanionBuilder,
          $$MetaTableUpdateCompanionBuilder,
          (MetaData, BaseReferences<_$ChitDb, $MetaTable, MetaData>),
          MetaData,
          PrefetchHooks Function()
        > {
  $$MetaTableTableManager(_$ChitDb db, $MetaTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () => $$MetaTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () => $$MetaTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () => $$MetaTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> key = const Value.absent(),
            Value<String> value = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) => MetaCompanion(key: key, value: value, rowid: rowid),
          createCompanionCallback: ({
            required String key,
            required String value,
            Value<int> rowid = const Value.absent(),
          }) => MetaCompanion.insert(key: key, value: value, rowid: rowid),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$MetaTable, MetaData>(table),
                  BaseReferences<_$ChitDb, $MetaTable, MetaData>(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$MetaTableProcessedTableManager =
    ProcessedTableManager<
      _$ChitDb,
      $MetaTable,
      MetaData,
      $$MetaTableFilterComposer,
      $$MetaTableOrderingComposer,
      $$MetaTableAnnotationComposer,
      $$MetaTableCreateCompanionBuilder,
      $$MetaTableUpdateCompanionBuilder,
      (MetaData, BaseReferences<_$ChitDb, $MetaTable, MetaData>),
      MetaData,
      PrefetchHooks Function()
    >;

class $ChitDbManager {
  final _$ChitDb _db;
  $ChitDbManager(this._db);
  $$RecordsTableTableManager get records => $$RecordsTableTableManager(_db, _db.records);
  $$OutboxTableTableManager get outbox => $$OutboxTableTableManager(_db, _db.outbox);
  $$MetaTableTableManager get meta => $$MetaTableTableManager(_db, _db.meta);
}
