defmodule Electric.Postgres.Replication do
  use Electric.Satellite.Protobuf

  alias PgQuery, as: Pg
  alias Electric.Postgres.{Dialect, Extension.SchemaLoader, Schema.AST, Schema.Proto}

  defmodule Column do
    alias Electric.Postgres

    defstruct [
      :name,
      :type,
      :nullable?,
      type_modifier: -1,
      part_of_identity?: false
    ]

    @type name() :: Postgres.name()

    @type t() :: %__MODULE__{
            name: name(),
            type: atom(),
            nullable?: boolean(),
            type_modifier: integer(),
            part_of_identity?: boolean() | nil
          }
  end

  defmodule Table do
    alias Electric.Postgres

    defstruct [
      :schema,
      :name,
      :oid,
      primary_keys: [],
      replica_identity: :index,
      columns: []
    ]

    @type t() :: %__MODULE__{
            schema: Postgres.name(),
            name: Postgres.name(),
            oid: Postgres.oid(),
            primary_keys: [Postgres.name()],
            replica_identity: :all_columns | :default | :nothing | :index,
            columns: [Column.t()]
          }
  end

  @type version() :: binary()

  @default_dialect Dialect.SQLite

  # we get a list of sql statements and a schema
  # 1. update the schema with the ddl
  # 2. generate the sqlite sql from the ast
  # 3. get the list of tables involved in the migration
  # 4. use the updated schema to get column, fk and pk information for the affected tables
  #
  # - creation of indexes doesn't affect any tables so that list should be empty
  @spec migrate(SchemaLoader.Version.t(), binary(), Electric.Postgres.Dialect.t()) ::
          {:ok, [%SatOpMigrate{}], [{binary, binary}]}
  def migrate(schema_version, stmt, dialect \\ @default_dialect) do
    ast = Electric.Postgres.parse!(stmt)

    case propagatable_stmt?(ast) do
      [] ->
        {:ok, [], []}

      propagate_ast ->
        {msg, relations} = build_replication_msg(propagate_ast, stmt, schema_version, dialect)

        {:ok, [msg], relations}
    end
  end

  def stmt_type(%Pg.CreateStmt{}) do
    :CREATE_TABLE
  end

  def stmt_type(%Pg.IndexStmt{}) do
    :CREATE_INDEX
  end

  def stmt_type(%Pg.CreateEnumStmt{}) do
    :CREATE_ENUM_TYPE
  end

  def stmt_type(%Pg.AlterTableStmt{cmds: [cmd]}) do
    case cmd do
      %{node: {:alter_table_cmd, %Pg.AlterTableCmd{subtype: :AT_AddColumn}}} ->
        :ALTER_ADD_COLUMN
    end
  end

  defp to_sql(_ast, stmt, Dialect.Postgresql), do: stmt
  defp to_sql(ast, _stmt, dialect), do: Dialect.to_sql(ast, dialect)

  def affected_tables(stmts, dialect \\ @default_dialect) when is_list(stmts) do
    stmts
    |> Enum.flat_map(&get_affected_table/1)
    |> Enum.uniq_by(&Dialect.table_name(&1, dialect))
  end

  defp get_affected_table(%Pg.CreateStmt{relation: relation}) do
    [AST.map(relation)]
  end

  defp get_affected_table(%Pg.AlterTableStmt{relation: relation}) do
    [AST.map(relation)]
  end

  defp get_affected_table(%Pg.IndexStmt{}) do
    []
  end

  defp get_affected_table(_stmt) do
    []
  end

  defp build_replication_msg(ast, stmt, schema_version, dialect) do
    affected_tables = affected_tables(ast, dialect)

    relations = Enum.map(affected_tables, &{&1.schema, &1.name})

    tables =
      affected_tables
      |> Enum.map(&SchemaLoader.Version.table!(schema_version, &1))
      |> Enum.map(&replication_msg_table(&1, dialect))

    table =
      case tables do
        [] -> nil
        [table] -> table
      end

    stmts =
      ast
      |> Enum.reject(&(dialect == Dialect.SQLite and match?(%Pg.CreateEnumStmt{}, &1)))
      |> Enum.map(
        &%SatOpMigrate.Stmt{
          type: stmt_type(&1),
          sql: to_sql(&1, stmt, dialect)
        }
      )

    enum_type =
      ast
      |> Enum.filter(&match?(%Pg.CreateEnumStmt{}, &1))
      |> Enum.map(fn enum_ast ->
        name = AST.map(enum_ast.type_name)
        values = AST.map(enum_ast.vals)
        %SatOpMigrate.EnumType{name: Dialect.table_name(name, dialect), values: values}
      end)
      |> case do
        [] -> nil
        [enum] -> enum
      end

    affected_entity =
      case {table, enum_type} do
        {%SatOpMigrate.Table{}, nil} -> {:table, table}
        {nil, %SatOpMigrate.EnumType{}} -> {:enum_type, enum_type}
        {nil, nil} -> nil
      end

    {%SatOpMigrate{
       version: SchemaLoader.Version.version(schema_version),
       affected_entity: affected_entity,
       stmts: stmts
     }, relations}
  end

  # FIXME: not all ddl commands are suitable for passing to the clients.
  # these should be filtered by the event trigger function. in lieu of that
  # filter them here
  defp propagatable_stmt?(ast) do
    Enum.filter(ast, fn
      %Pg.CreateStmt{} ->
        true

      %Pg.IndexStmt{} ->
        true

      %Pg.AlterTableStmt{
        cmds: [%{node: {:alter_table_cmd, %Pg.AlterTableCmd{subtype: :AT_AddColumn}}}]
      } ->
        true

      %Pg.CreateEnumStmt{} ->
        true

      _else ->
        false
    end)
  end

  defp replication_msg_table(%Proto.Table{} = table, dialect) do
    %SatOpMigrate.Table{
      name: Dialect.table_name(table.name, dialect),
      columns: Enum.map(table.columns, &replication_msg_table_col(&1)),
      fks: Enum.flat_map(table.constraints, &replication_msg_table_fk(&1, dialect)),
      pks: Enum.flat_map(table.constraints, &replication_msg_table_pk(&1))
    }
  end

  defp replication_msg_table_col(%Proto.Column{} = column) do
    %SatOpMigrate.Column{
      name: column.name,
      pg_type: replication_msg_table_col_type(column.type),
      sqlite_type: Dialect.type_name(column.type, Dialect.SQLite)
    }
  end

  defp replication_msg_table_col_type(%Proto.Column.Type{} = type) do
    %SatOpMigrate.PgColumnType{
      name: type.name,
      array: type.array,
      size: type.size
    }
  end

  defp replication_msg_table_pk(%Proto.Constraint{constraint: {:primary, pk}}), do: pk.keys
  defp replication_msg_table_pk(_constraint), do: []

  defp replication_msg_table_fk(%Proto.Constraint{constraint: {:foreign, fk}}, dialect) do
    [
      %SatOpMigrate.ForeignKey{
        fk_cols: fk.fk_cols,
        pk_cols: fk.pk_cols,
        pk_table: Dialect.table_name(fk.pk_table, dialect)
      }
    ]
  end

  defp replication_msg_table_fk(_constraint, _dialect) do
    []
  end
end
