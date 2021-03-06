##[

##############
SQLite Backend
##############

]##


import strutils, macros, typetraits, logging
import db_sqlite

import rowutils, objutils, pragmas


export strutils, macros, logging
export db_sqlite
export rowutils, objutils, pragmas


proc `$`*(query: SqlQuery): string = $ string query

proc getTable*(objRepr: ObjRepr): string =
  ##[ Get the name of the DB table for the given object representation:
  ``table`` pragma value if it exists or lowercased type name otherwise.
  ]##

  result = objRepr.signature.name.toLowerAscii()

  for prag in objRepr.signature.pragmas:
    if prag.name == "table" and prag.kind == pkKval:
      return $prag.value

proc getTable*(T: type): string =
  ##[ Get the name of the DB table for the given type: ``table`` pragma value if it exists
  or lowercased type name otherwise.
  ]##

  when T.hasCustomPragma(table): T.getCustomPragmaVal(table)
  else: ($T).toLowerAscii()

proc getColumn*(fieldRepr: FieldRepr): string =
  ##[ Get the name of DB column for a field: ``dbCol`` pragma value if it exists
  or field name otherwise.
  ]##

  result = fieldRepr.signature.name

  for prag in fieldRepr.signature.pragmas:
    if prag.name == "dbCol" and prag.kind == pkKval:
      return $prag.value

proc getColumns*(obj: object, force = false): seq[string] =
  ## Get DB column names for an object as a sequence of strings.

  for field, _ in obj.fieldPairs:
    if force or not obj.dot(field).hasCustomPragma(ro):
      when obj.dot(field).hasCustomPragma(dbCol):
        result.add obj.dot(field).getCustomPragmaVal(dbCol)
      else:
        result.add field

proc getDbType(fieldRepr: FieldRepr): string =
  ## SQLite-specific mapping from Nim types to SQL data types.

  result = case $fieldRepr.typ
  of "int": "INTEGER"
  of "string": "TEXT"
  of "float": "REAL"
  else: "TEXT"

  for prag in fieldRepr.signature.pragmas:
    if prag.name == "dbType" and prag.kind == pkKval:
      return $prag.value

proc genColStmt(fieldRepr: FieldRepr, dbObjReprs: openarray[ObjRepr]): string =
  ## Generate SQL column statement for a field representation.

  result.add fieldRepr.getColumn()
  result.add " "
  result.add getDbType(fieldRepr)

  for prag in fieldRepr.signature.pragmas:
    if prag.name == "pk" and prag.kind == pkFlag:
      result.add " PRIMARY KEY"
    elif prag.name == "notNull" and prag.kind == pkFlag:
      result.add " NOT NULL"
    elif prag.name == "check" and prag.kind == pkKval:
      result.add " CHECK $#" % $prag.value
    elif prag.name == "default" and prag.kind == pkKval:
      result.add " DEFAULT $#" % $prag.value
    elif prag.name == "fk" and prag.kind == pkKval:
      expectKind(prag.value, {nnkIdent, nnkDotExpr})

      result.add case prag.value.kind
      of nnkIdent:
        ", FOREIGN KEY ($#) REFERENCES $# (id)" % [fieldRepr.getColumn(),
                                                    dbObjReprs.getByName($prag.value).getTable()]
      of nnkDotExpr:
        ", FOREIGN KEY ($#) REFERENCES $# ($#)" % [fieldRepr.getColumn(),
                                                    dbObjReprs.getByName($prag.value[0]).getTable(),
                                                    $prag.value[1]]
      else: ""

proc genTableSchema(dbObjRepr: ObjRepr, dbObjReprs: openarray[ObjRepr]): string =
  ## Generate table schema for an object representation.

  result.add "CREATE TABLE $# (\n" % dbObjRepr.getTable()

  var columns: seq[string]

  for field in dbObjRepr.fields:
    columns.add "\t$#" % genColStmt(field, dbObjReprs)

  result.add columns.join(",\n")
  result.add "\n)"

proc genTableSchemas*(dbObjReprs: openarray[ObjRepr]): seq[SqlQuery] =
  ## Generate table schemas for a list of object representations.

  for dbObjRepr in dbObjReprs:
    result.add sql genTableSchema(dbObjRepr, dbObjReprs)

proc genDropTableQueries*(dbObjReprs: seq[ObjRepr]): seq[SqlQuery] =
  ## Generate ``DROP TABLE`` queries for a list of object representations.

  for dbObjRepr in dbObjReprs:
    result.add sql "DROP TABLE IF EXISTS $#" % dbObjRepr.getTable()

proc genInsertQuery*(obj: object, force: bool): SqlQuery =
  ## Generate ``INSERT`` query for an object.

  let
    fields = obj.getColumns(force)
    placeholders = '?'.repeat(fields.len)

  result = sql "INSERT INTO $# ($#) VALUES ($#)" % [type(obj).getTable(), fields.join(", "),
                                                    placeholders.join(", ")]

proc genGetOneQuery*(obj: object): SqlQuery =
  ## Generate ``SELECT`` query to fetch a single record for an object.

  sql "SELECT $# FROM $# WHERE id = ?" % [obj.getColumns(force=true).join(", "),
                                          type(obj).getTable()]

proc genGetManyQuery*(obj: object, condition, orderBy: string): SqlQuery =
  ## Generate ``SELECT`` query to fetch multiple records for an object.

  sql "SELECT $# FROM $# WHERE $# ORDER BY $# LIMIT ? OFFSET ?" % [
                                                      obj.getColumns(force=true).join(", "),
                                                      type(obj).getTable(), condition, orderBy]

proc getUpdateQuery*(obj: object, force: bool): SqlQuery =
  ## Generate ``UPDATE`` query for an object.

  var fieldsWithPlaceholders: seq[string]

  for field in obj.getColumns(force):
    fieldsWithPlaceholders.add field & " = ?"

  result = sql "UPDATE $# SET $# WHERE id = ?" % [type(obj).getTable(),
                                                  fieldsWithPlaceholders.join(", ")]

proc genDeleteQuery*(obj: object): SqlQuery =
  ## Generate ``DELETE`` query for an object.

  sql "DELETE FROM $# WHERE id = ?" % type(obj).getTable()

template genWithDb(connection, user, password, database: string,
                    tableSchemas, dropTableQueries: openarray[SqlQuery]): untyped {.dirty.} =
  ## Generate ``withDb`` templates.

  template withDb*(body: untyped): untyped {.dirty.} =
    ##[ A wrapper for actions that require DB connection. Defines CRUD procs to work with the DB,
    as well as ``createTables`` and ``dropTables`` procs.

      Aforementioned procs and procs defined in a ``db`` block can be used only
      in  a ``withDb`` block.
    ]##

    block:
      let dbConn = open(connection, user, password, database)

      template dropTables() =
        ## Drop tables for all types in all type sections under ``db`` macro.

        for dropTableQuery in dropTableQueries:
          debug dropTableQuery

          dbConn.exec sql dropTableQuery

      template createTables(force = false) =
        ##[ Create tables for all types in all type sections under ``db`` macro.

        If ``force`` is ``true``, drop tables beforehand.
        ]##

        if force:
          dropTables()

        for tableSchema in tableSchemas:
          debug tableSchema

          dbConn.exec sql tableSchema

      template insert(obj: var object, force = false) =
        ##[ Insert object instance as a record into DB.The object's id is updated after
        the insertion.

        By default, readonly fields are not inserted. Use ``force=true`` to insert all fields.
        ]##

        let
          insertQuery = genInsertQuery(obj, force)
          params = obj.toRow(force)

        debug insertQuery, " <- ", params.join(", ")

        obj.id = dbConn.insertID(insertQuery, params).int

      template getOne(obj: var object, id: int) =
        ## Read a record from DB and store it into an existing object instance.

        let getOneQuery = genGetOneQuery(obj)

        debug getOneQuery, " <- ", $id

        let row = dbConn.getRow(genGetOneQuery(obj), id)

        if row.isEmpty():
          raise newException(KeyError, "Record with id=$# not found." % $id)

        row.to(obj)

      proc getOne(T: type, id: int): T =
        ## Read a record from DB into a new object instance.

        result.getOne(id)

      proc getMany(objs: var seq[object], limit: int,  offset = 0, where = "1", orderBy = "id") =
        ##[ Read ``limit`` records with ``offset``  from DB into an existing open array of objects.

        Filter using ``where`` condition.
        ]##

        if len(objs) == 0: return

        let
          getManyQuery = genGetManyQuery(objs[0], where, orderBy)
          params = [$min(limit, len(objs)), $offset]

        debug getManyQuery, " <- ", params.join(", ")

        let rows = dbConn.getAllRows(getManyQuery, params)

        rows.to(objs)

      proc getMany(T: type, limit: int, offset = 0, where = "1", orderBy = "id"): seq[T] =
        ##[ Read ``limit`` records  with ``offset`` from DB into a sequence of objects,
        create the sequence on the fly.

        Filter using ``where`` condition.
        ]##

        result.setLen limit
        result.getMany(limit, offset, where, orderBy)

      template update(obj: object, force = false) =
        ##[ Update DB record with object field values.

        By default, readonly fields are not updated. Use ``force=true`` to update all fields.
        ]##

        let
          updateQuery = getUpdateQuery(obj, force)
          params = obj.toRow(force) & $obj.id

        debug updateQuery, " <- ", params.join(", ")

        dbConn.exec(updateQuery, params)

      template delete(obj: var object) =
        ## Delete a record in DB by object's id. The id is set to 0 after the deletion.

        let deleteQuery = genDeleteQuery(obj)

        debug deleteQuery, " <- ", $obj.id

        dbConn.exec(deleteQuery, obj.id)

        obj.id = 0

      try: body
      finally: dbConn.close()

proc ensureIdFields(typeSection: NimNode): NimNode =
  ## Check if ``id`` field is in the object definition, insert it if it's not.

  result = newNimNode(nnkTypeSection)

  for typeDef in typeSection:
    var objRepr = typeDef.toObjRepr()

    if "id" notin objRepr.fieldNames:
      let idField = FieldRepr(
        signature: SignatureRepr(
          name: "id",
          exported: true,
          pragmas: @[
            PragmaRepr(name: "pk", kind: pkFlag),
            PragmaRepr(name: "ro", kind: pkFlag)
          ]
        ),
        typ: ident "int"
      )
      objRepr.fields.insert(idField, 0)

    result.add objRepr.toTypeDef()

macro db*(connection, user, password, database: string, body: untyped): untyped =
  ##[ DB models definition. Models are defined as regular Nim objects in regular ``type`` sections.

  ``connection``, ``user``, ``password``, ``database`` are the same args accepted
  by a standard ``dbConn`` instance.

  The macro generates ``withDb`` template that wraps all DB interations.
  ]##

  result = newStmtList()

  var dbObjReprs: seq[ObjRepr]

  for node in body:
    if node.kind == nnkTypeSection:
      let typeSection = node.ensureIdFields()

      result.add typeSection

      for typeDef in typeSection:
        dbObjReprs.add typeDef.toObjRepr()

    else:
      result.add node

  let withDbNode = getAst genWithDb(connection, user, password, database,
                                    genTableSchemas(dbObjReprs), genDropTableQueries(dbObjReprs))

  result.insert(0, withDbNode)
