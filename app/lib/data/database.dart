import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'database.g.dart';

/// Every record the user can see, as its wire JSON. Merged field by field
/// with the per-field clocks inside `data` (see replica.dart).
@DataClassName('StoredRecord') // not `Record`: that is dart:core's record type
class Records extends Table {
  TextColumn get collection => text()();
  TextColumn get id => text()();

  /// The note a record belongs to (a note belongs to itself), for revokes.
  TextColumn get note => text().withDefault(const Constant(''))();
  TextColumn get data => text()();

  @override
  Set<Column<Object>> get primaryKey => {collection, id};
}

/// Edits made here, waiting for the server, oldest first.
class Outbox extends Table {
  IntColumn get seq => integer().autoIncrement()();
  TextColumn get op => text()();
  TextColumn get created => text()();
}

/// The session, the feed cursor, this device's id.
class Meta extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column<Object>> get primaryKey => {key};
}

@DriftDatabase(tables: [Records, Outbox, Meta])
class ChitDb extends _$ChitDb {
  ChitDb([QueryExecutor? executor]) : super(executor ?? _open());

  @override
  int get schemaVersion => 1;

  // The web build runs SQLite as WebAssembly in a worker; the native
  // builds use the bundled library. drift_flutter picks per platform.
  static QueryExecutor _open() => driftDatabase(
    name: 'chit',
    web: DriftWebOptions(sqlite3Wasm: Uri.parse('sqlite3.wasm'), driftWorker: Uri.parse('drift_worker.js')),
  );
}
