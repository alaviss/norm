import strutils, sequtils
import sugar
import macros; export macros

import objutils, pragmas


type Row = seq[string]


template parser*(op: (string) -> any) {.pragma.}
  ##[ Pragma to define a parser for an object field.

  ``op`` should be a proc that accepts ``string`` and returns the object field type.

  The proc is called in ``to`` template to turn a string from row into a typed object field.
  ]##

template parseIt*(op: untyped) {.pragma.}
  ##[ Pragma to define a parse expression for an object field.

  ``op`` should be an expression with ``it`` variable that evaluates to the object field type.

  The expression is invoked in ``to`` template to turn a string from row into a typed object field.
  ]##

template formatter*(op: (any) -> string) {.pragma.}
  ##[ Pragma to define a formatter for an object field.

  ``op`` should be a proc that accepts the object field type and returns ``string``.

  The proc is called in ``toRow`` proc to turn a typed object field into a string within a row.
  ]##

template formatIt*(op: untyped) {.pragma.}
  ##[ Pragma to define a format expression for an object field.

  ``op`` should be an expression with ``it`` variable with the object field type and evaluates
  to ``string``.

  The expression is invoked in ``toRow`` proc to turn a typed object field into a string
  within a row.
  ]##

template to*(row: Row, obj: var object) =
  ##[ Convert row to an existing object instance. String values from row are converted
  into types of the respective object fields.

  If object fields don't require initialization, you may use the proc that instantiates the object
  on the fly. This template though can be safely used for all object kinds.
  ]##

  runnableExamples:
    import times, sugar

    proc parseDateTime(s: string): DateTime = s.parse("yyyy-MM-dd HH:mm:sszzz")

    type
      Example = object
        intField: int
        strField: string
        floatField: float
        dtField {.parser: parseDateTime.}: DateTime

    let row = @["123", "foo", "123.321", "2019-01-21 15:03:21+04:00"]

    var example = Example(dtField: now())

    row.to(example)

    doAssert example.intField == 123
    doAssert example.strField == "foo"
    doAssert example.floatField == 123.321
    doAssert example.dtField == "2019-01-21 15:03:21+04:00".parseDateTime()

  var i: int

  for field, value in obj.fieldPairs:
    when obj.dot(field).hasCustomPragma(parser):
      obj.dot(field) = obj.dot(field).getCustomPragmaVal(parser) row[i]
    elif obj.dot(field).hasCustomPragma(parseIt):
      block:
        let it {.inject.} = row[i]
        obj.dot(field) = obj.dot(field).getCustomPragmaVal(parseIt)
    elif type(value) is string:
      obj.dot(field) = row[i]
    elif type(value) is int:
      obj.dot(field) = parseInt row[i]
    elif type(value) is float:
      obj.dot(field) = parseFloat row[i]
    else:
      raise newException(ValueError, "Parser for $# is undefined." % type(value))

    inc i

template to*(rows: openArray[Row], objs: var seq[object]) =
  ##[ Convert a open array of rows into an existing sequence of objects.

  If the number of rows is higher than the number of objects, extra rows are ignored.

  If the number of objects is higher, unused objects are trimmed away.
  ]##

  runnableExamples:
    import times, sugar

    proc parseDateTime(s: string): DateTime = s.parse("yyyy-MM-dd HH:mm:sszzz")

    type
      Example = object
        intField: int
        strField: string
        floatField: float
        dtField {.parser: parseDateTime.}: DateTime

    let rows = @[
      @["123", "foo", "123.321", "2019-01-21 15:03:21+04:00"],
      @["456", "bar", "456.654", "2019-02-22 16:14:32+04:00"],
      @["789", "baz", "789.987", "2019-03-23 17:25:43+04:00"]
    ]

    var examples = @[
      Example(dtField: now()),
      Example(dtField: now()),
      Example(dtField: now())
    ]

    rows.to(examples)

    doAssert examples[0].intField == 123
    doAssert examples[1].strField == "bar"
    doAssert examples[2].floatField == 789.987
    doAssert examples[0].dtField == "2019-01-21 15:03:21+04:00".parseDateTime()

  objs.setLen min(len(rows), len(objs))

  for i in 0..high(objs):
    rows[i].to(objs[i])

proc to*(row: Row, T: type): T =
  ##[ Instantiate object with type ``T`` with values from ``row``. String values from row
  are converted into types of the respective object fields.

  Use this proc if the object fields have default values and do not require initialization, e.g. ``int``, ``string``, ``float``.

  If fields require initialization, for example, ``times.DateTime``, use template ``to``.
  It converts a row to a existing object instance.
  ]##

  runnableExamples:
    type
      Example = object
        intField: int
        strField: string
        floatField: float

    let
      row = @["123", "foo", "123.321"]
      obj = row.to(Example)

    doAssert obj.intField == 123
    doAssert obj.strField == "foo"
    doAssert obj.floatField == 123.321

  row.to(result)

proc to*(rows: openArray[Row], T: type): seq[T] =
  ##[ Instantiate a sequence of objects with type ``T`` with values
  from ``rows``. String values from each row are converted into types
  of the respective object fields.

  Use this proc if the object fields have default values and do not require initialization, e.g. ``int``, ``string``, ``float``.

  If fields require initialization, for example, ``times.DateTime``, use template ``to``.
  It converts an open array of rows to an existing object instance openarray.
  ]##

  runnableExamples:
    type
      Example = object
        intField: int
        strField: string
        floatField: float

    let
      rows = @[
        @["123", "foo", "123.321"],
        @["456", "bar", "456.654"],
        @["789", "baz", "789.987"]
      ]
      examples = rows.to(Example)

    doAssert examples[0].intField == 123
    doAssert examples[1].strField == "bar"
    doAssert examples[2].floatField == 789.987

  result.setLen len(rows)

  rows.to(result)

proc toRow*(obj: object, force = false): Row =
  ##[ Convert an object into row, i.e. sequence of strings.

  If a custom formatter is provided for a field, it is used for conversion,
  otherwise `$` is invoked.
  ]##

  runnableExamples:
    import strutils, sequtils, sugar

    type
      Example = object
        intField: int
        strField{.formatIt: it.toLowerAscii().}: string
        floatField: float

    let
      example = Example(intField: 123, strField: "Foo", floatField: 123.321)
      row = example.toRow()

    doAssert row[0] == "123"
    doAssert row[1] == "foo"
    doAssert row[2] == "123.321"

  for field, value in obj.fieldPairs:
    if force or not obj.dot(field).hasCustomPragma(ro):
      when obj.dot(field).hasCustomPragma(formatter):
        result.add obj.dot(field).getCustomPragmaVal(formatter) value
      elif obj.dot(field).hasCustomPragma(formatIt):
        block:
          let it {.inject.} = value
          result.add obj.dot(field).getCustomPragmaVal(formatIt)
      else:
        result.add $value

proc toRows*(objs: openArray[object], force = false): seq[Row] =
  ##[ Convert an open array of objects into a sequence of rows.

  If a custom formatter is provided for a field, it is used for conversion,
  otherwise `$` is invoked.
  ]##

  runnableExamples:
    import strutils, sequtils, sugar

    type
      Example = object
        intField: int
        strField{.formatIt: it.toLowerAscii().}: string
        floatField: float

    let
      examples = @[
        Example(intField: 123, strField: "Foo", floatField: 123.321),
        Example(intField: 456, strField: "Bar", floatField: 456.654),
        Example(intField: 789, strField: "Baz", floatField: 789.987)
      ]
      rows = examples.toRows()

    doAssert rows[0][0] == "123"
    doAssert rows[1][1] == "bar"
    doAssert rows[2][2] == "789.987"

  objs.mapIt(it.toRow(force))

proc isEmpty*(row: Row): bool =
  ## Check if row is empty, i.e. all its items are ``""``.

  row.allIt(it.len == 0)
