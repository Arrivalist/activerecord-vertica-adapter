require 'active_record/connection_adapters/abstract_adapter'
require 'active_support/core_ext/object/blank'
require 'active_record/connection_adapters/statement_pool'
require 'arel/visitors/bind_visitor'

# Make sure we're using pg high enough for PGResult#values
gem 'pg', '~> 0.18'
require 'pg'

module ActiveRecord
  class Base
    # Establishes a connection to the database that's used by all Active Record objects
    def self.vertica_connection(config) # :nodoc:
      config = config.symbolize_keys
      host     = config[:host]
      port     = config[:port] || 5433
      username = config[:username].to_s if config[:username]
      password = config[:password].to_s if config[:password]

      if config.key?(:database)
        database = config[:database]
      else
        raise ArgumentError, "No database specified. Missing argument: database."
      end

      # The postgres drivers don't allow the creation of an unconnected PGconn object,
      # so just pass a nil connection object for the time being.
      # The order the options are passed to the ::connect method. (in pg/connection.rb)
      #CONNECT_ARGUMENT_ORDER = %w[host port options tty dbname user password]
      ConnectionAdapters::VerticaAdapter.new(nil, logger, [host, port, nil, nil, database, username, password], config)
    end
  end

  module ConnectionAdapters
    # PostgreSQL-specific extensions to column definitions in a table.
    class VerticaColumn < Column #:nodoc:
      # Instantiates a new PostgreSQL column definition in a table.
      def initialize(name, default, sql_type = nil, null = true)

        super(name, self.class.extract_value_from_default(default), sql_type, null)
      end

      def sql_type
        type.to_s
      end

      # :stopdoc:
      class << self
        attr_accessor :money_precision
        def string_to_time(string)
          return string unless String === string

          case string
            when 'infinity'  then 1.0 / 0.0
            when '-infinity' then -1.0 / 0.0
            else
              super
          end
        end
      end
      # :startdoc:

      private

      def extract_limit(sql_type)
        case sql_type
          # vertica uses bigint for any int
          when /^integer|int|int8|bigint|smallint|tinyint/i; 8
          else super
        end
      end

      # Extracts the scale from PostgreSQL-specific data types.
      def extract_scale(sql_type)
        # Money type has a fixed scale of 2.
        sql_type =~ /^money/ ? 2 : super
      end

      # Extracts the precision from PostgreSQL-specific data types.
      def extract_precision(sql_type)
        if sql_type == 'money'
          self.class.money_precision
        else
          super
        end
      end

      # Maps PostgreSQL-specific data types to logical Rails types.
      def simplified_type(field_type)
        case field_type
          # Numeric and monetary types
          when /^(?:real|double precision)$/
            :float
          # Monetary types
          when 'money'
            :decimal
          # Character types
          when /^(?:character varying|bpchar)(?:\(\d+\))?$/
            :string
          # Binary data types
          when 'bytea'
            :binary
          # Date/time types
          when /^timestamp with(?:out)? time zone$/
            :datetime
          when 'interval'
            :string
          # Geometric types
          when /^(?:point|line|lseg|box|"?path"?|polygon|circle)$/
            :string
          # Network address types
          when /^(?:cidr|inet|macaddr)$/
            :string
          # Bit strings
          when /^bit(?: varying)?(?:\(\d+\))?$/
            :string
          # XML type
          when 'xml'
            :xml
          # tsvector type
          when 'tsvector'
            :tsvector
          # Arrays
          when /^\D+\[\]$/
            :string
          # Object identifier types
          when 'oid'
            :integer
          # UUID type
          when 'uuid'
            :string
          # Small and big integer types
          when /^(?:small|big)int$/
            :integer
          # Pass through all types that are not specific to PostgreSQL.
          else
            super
        end
      end

      # Extracts the value from a PostgreSQL column default definition.
      def self.extract_value_from_default(default)
        case default
          # This is a performance optimization for Ruby 1.9.2 in development.
          # If the value is nil, we return nil straight away without checking
          # the regular expressions. If we check each regular expression,
          # Regexp#=== will call NilClass#to_str, which will trigger
          # method_missing (defined by whiny nil in ActiveSupport) which
          # makes this method very very slow.
          when NilClass
            nil
          # Numeric types
          when /\A\(?(-?\d+(\.\d*)?\)?)\z/
            $1
          # Character types
          when /\A\(?'(.*)'::.*\b(?:character varying|bpchar|text)\z/m
            $1
          # Binary data types
          when /\A'(.*)'::bytea\z/m
            $1
          # Date/time types
          when /\A'(.+)'::(?:time(?:stamp)? with(?:out)? time zone|date)\z/
            $1
          when /\A'(.*)'::interval\z/
            $1
          # Boolean type
          when 'true'
            true
          when 'false'
            false
          # Geometric types
          when /\A'(.*)'::(?:point|line|lseg|box|"?path"?|polygon|circle)\z/
            $1
          # Network address types
          when /\A'(.*)'::(?:cidr|inet|macaddr)\z/
            $1
          # Bit string types
          when /\AB'(.*)'::"?bit(?: varying)?"?\z/
            $1
          # XML type
          when /\A'(.*)'::xml\z/m
            $1
          # Arrays
          when /\A'(.*)'::"?\D+"?\[\]\z/
            $1
          # Object identifier types
          when /\A-?\d+\z/
            $1
          else
            # Anything else is blank, some user type, or some function
            # and we can't know the value of that, so return nil.
            nil
        end
      end
    end

    # The PostgreSQL adapter works both with the native C (http://ruby.scripting.ca/postgres/) and the pure
    # Ruby (available both as gem and from http://rubyforge.org/frs/?group_id=234&release_id=1944) drivers.
    #
    # Options:
    #
    # * <tt>:host</tt> - Defaults to "localhost".
    # * <tt>:port</tt> - Defaults to 5432.
    # * <tt>:username</tt> - Defaults to nothing.
    # * <tt>:password</tt> - Defaults to nothing.
    # * <tt>:database</tt> - The name of the database. No default, must be provided.
    # * <tt>:schema_search_path</tt> - An optional schema search path for the connection given
    #   as a string of comma-separated schema names. This is backward-compatible with the <tt>:schema_order</tt> option.
    # * <tt>:encoding</tt> - An optional client encoding that is used in a <tt>SET client_encoding TO
    #   <encoding></tt> call on the connection.
    class VerticaAdapter < AbstractAdapter
      class TableDefinition < ActiveRecord::ConnectionAdapters::TableDefinition
        def text(*args)
          options = args.extract_options!
          options[:limit] = 65000
          column(args[0], 'text', options)
        end
        def xml(*args)
          options = args.extract_options!
          column(args[0], 'xml', options)
        end

        def tsvector(*args)
          options = args.extract_options!
          column(args[0], 'tsvector', options)
        end
      end

      ADAPTER_NAME = 'Vertica'

      NATIVE_DATABASE_TYPES = {
          :primary_key => "identity primary key",
          :non_inc_pk  => "integer primary key",
          :string      => { :name => "varchar", :limit => 255 },
          :text        => { :name => "varchar", :limit => 65000 },
          :integer     => { :name => "integer" },
          :float       => { :name => "float" },
          :decimal     => { :name => "decimal" },
          :datetime    => { :name => "timestamp" },
          :timestamp   => { :name => "timestamp" },
          :time        => { :name => "time" },
          :date        => { :name => "date" },
          :binary      => { :name => "bytea" },
          :boolean     => { :name => "boolean" },
          :xml         => { :name => "xml" },
          :tsvector    => { :name => "tsvector" }
      }

      # Returns 'PostgreSQL' as adapter name for identification purposes.
      def adapter_name
        ADAPTER_NAME
      end

      # Returns +true+, since this connection adapter supports prepared statement
      # caching.
      def supports_statement_cache?
        true
      end

      def supports_index_sort_order?
        true
      end

      def add_index(table_name, column_name, options = {})
        # no op - feature not supported
      end

      class StatementPool < ConnectionAdapters::StatementPool
        def initialize(max)
          super
          @counter = 0
          @cache   = Hash.new { |h,pid| h[pid] = {} }
        end

        def each(&block); cache.each(&block); end
        def key?(key);    cache.key?(key); end
        def [](key);      cache[key]; end
        def length;       cache.length; end

        def next_key
          "a#{@counter + 1}"
        end

        def []=(sql, key)
          while @max <= cache.size
            dealloc(cache.shift.last)
          end
          @counter += 1
          cache[sql] = key
        end

        def clear
          cache.each_value do |stmt_key|
            dealloc stmt_key
          end
          cache.clear
        end

        def delete(sql_key)
          dealloc cache[sql_key]
          cache.delete sql_key
        end

        private
        def cache
          @cache[$$]
        end

        def dealloc(key)
          @connection.query "DEALLOCATE #{key}" if connection_active?
        end

        def connection_active?
          @connection.status == PGconn::CONNECTION_OK
        rescue PGError
          false
        end
      end

      class BindSubstitution < Arel::Visitors::PostgreSQL # :nodoc:
        include Arel::Visitors::BindVisitor
      end

      # Initializes and connects a PostgreSQL adapter.
      def initialize(connection, logger, connection_parameters, config)
        super(connection, logger)

        if config.fetch(:prepared_statements) { true }
          @visitor = Arel::Visitors::PostgreSQL.new self
        else
          @visitor = BindSubstitution.new self
        end

        connection_parameters.delete :prepared_statements

        @connection_parameters, @config = connection_parameters, config

        # @local_tz is initialized as nil to avoid warnings when connect tries to use it
        @local_tz = nil
        @table_alias_length = 128

        connect
        @statements = StatementPool.new config.fetch(:statement_limit) { 1000 }

        @local_tz = execute('SHOW TIME ZONE', 'SCHEMA').first["TimeZone"]
      end

      # Clears the prepared statements cache.
      def clear_cache!
        @statements.clear
      end

      # Is this connection alive and ready for queries?
      def active?
        @connection.query 'SELECT 1'
        true
      rescue PGError
        false
      end

      # Close then reopen the connection.
      def reconnect!
        clear_cache!
        @connection.reset
        @open_transactions = 0
        configure_connection
      end

      def reset!
        clear_cache!
        super
      end

      # Disconnects from the database if already connected. Otherwise, this
      # method does nothing.
      def disconnect!
        clear_cache!
        @connection.close rescue nil
      end

      def native_database_types #:nodoc:
        NATIVE_DATABASE_TYPES
      end

      # Returns true, since this connection adapter supports migrations.
      def supports_migrations?
        true
      end

      # Does Vertica support finding primary key on non-Active Record tables?
      def supports_primary_key? #:nodoc:
        true
      end

      # Enable standard-conforming strings if available.
      def set_standard_conforming_strings
        execute('SET standard_conforming_strings = on', 'SCHEMA') rescue nil
      end

      def supports_insert_with_returning?
        false
      end

      def supports_ddl_transactions?
        true
      end

      # Returns true, since this connection adapter supports savepoints.
      def supports_savepoints?
        true
      end

      # Returns true.
      def supports_explain?
        true
      end

      # Returns the configured supported identifier length supported by PostgreSQL
      def table_alias_length
        @table_alias_length ||= 128
      end

      # QUOTING ==================================================

      # Escapes binary strings for bytea input to the database.
      def escape_bytea(value)
        @connection.escape_bytea(value) if value
      end

      # Unescapes bytea output from a database to the binary string it represents.
      # NOTE: This is NOT an inverse of escape_bytea! This is only to be used
      #       on escaped binary output from database drive.
      def unescape_bytea(value)
        @connection.unescape_bytea(value) if value
      end

      # Quotes PostgreSQL-specific data types for SQL input.
      def quote(value, column = nil) #:nodoc:
        return super unless column

        case value
          when Float
            return super unless value.infinite? && column.type == :datetime
            "'#{value.to_s.downcase}'"
          when Numeric
            return super unless column.sql_type == 'money'
            # Not truly string input, so doesn't require (or allow) escape string syntax.
            "'#{value}'"
          when String
            case column.sql_type
              when 'bytea' then "'#{escape_bytea(value)}'"
              when 'xml'   then "xml '#{quote_string(value)}'"
              when /^bit/
                case value
                  when /^[01]*$/      then "B'#{value}'" # Bit-string notation
                  when /^[0-9A-F]*$/i then "X'#{value}'" # Hexadecimal notation
                end
              else
                super
            end
          else
            super
        end
      end

      def type_cast(value, column = nil)
        return super unless column

        case value
          when String
            return super unless 'bytea' == column.sql_type
            { :value => value, :format => 1 }
          else
            super
        end
      end

      # Quotes strings for use in SQL input. Adds the current_schema if not specified when should_add_schema is true.
      def quote_string(s) #:nodoc:
        @connection.escape(s)
      end

      # Checks the following cases:
      #
      # - table_name
      # - "table.name"
      # - schema_name.table_name
      # - schema_name."table.name"
      # - "schema.name".table_name
      # - "schema.name"."table.name"
      def quote_table_name(name, should_add_schema=false)
        schema, name_part = extract_pg_identifier_from_name(name.to_s)

        if !name_part && !should_add_schema
          quote_column_name(schema)
        else
          if !name_part && should_add_schema
            table_name = schema
            schema = current_schema
          else
            table_name, name_part = extract_pg_identifier_from_name(name_part)
          end
          "#{quote_column_name(schema)}.#{quote_column_name(table_name)}"
        end
      end

      # Quotes column names for use in SQL queries.
      def quote_column_name(name) #:nodoc:
        PGconn.quote_ident(name.to_s)
      end

      # Set the authorized user for this session
      def session_auth=(user)
        clear_cache!
        exec_query "SET SESSION AUTHORIZATION #{user}"
      end

      # REFERENTIAL INTEGRITY ====================================

      def supports_disable_referential_integrity? #:nodoc:
        true
      end

      def disable_referential_integrity #:nodoc:
        if supports_disable_referential_integrity? then
          execute(tables.collect { |name| "ALTER TABLE #{quote_table_name(name, true)} DISABLE TRIGGER ALL" }.join(";"))
        end
        yield
      ensure
        if supports_disable_referential_integrity? then
          execute(tables.collect { |name| "ALTER TABLE #{quote_table_name(name, true)} ENABLE TRIGGER ALL" }.join(";"))
        end
      end

      # DATABASE STATEMENTS ======================================

      def explain(arel, binds = [])
        sql = "EXPLAIN #{to_sql(arel, binds)}"
        ExplainPrettyPrinter.new.pp(exec_query(sql, 'EXPLAIN', binds))
      end

      class ExplainPrettyPrinter # :nodoc:
        # Pretty prints the result of a EXPLAIN in a way that resembles the output of the
        # PostgreSQL shell:
        #
        #                                     QUERY PLAN
        #   ------------------------------------------------------------------------------
        #    Nested Loop Left Join  (cost=0.00..37.24 rows=8 width=0)
        #      Join Filter: (posts.user_id = users.id)
        #      ->  Index Scan using users_pkey on users  (cost=0.00..8.27 rows=1 width=4)
        #            Index Cond: (id = 1)
        #      ->  Seq Scan on posts  (cost=0.00..28.88 rows=8 width=4)
        #            Filter: (posts.user_id = 1)
        #   (6 rows)
        #
        def pp(result)
          header = result.columns.first
          lines  = result.rows.map(&:first)

          # We add 2 because there's one char of padding at both sides, note
          # the extra hyphens in the example above.
          width = [header, *lines].map(&:length).max + 2

          pp = []

          pp << header.center(width).rstrip
          pp << '-' * width

          pp += lines.map {|line| " #{line}"}

          nrows = result.rows.length
          rows_label = nrows == 1 ? 'row' : 'rows'
          pp << "(#{nrows} #{rows_label})"

          pp.join("\n") + "\n"
        end
      end

      # Executes a SELECT query and returns an array of rows. Each row is an
      # array of field values.
      def select_rows(sql, name = nil, binds = [])
        select_raw(sql, name).last
      end

      # Executes an INSERT query and returns the new record's ID
      def insert_sql(sql, name = nil, pk = nil, id_value = nil, sequence_name = nil)
        # note: Vertica doesn't have PK's
        super
        #unless pk
        #  # Extract the table from the insert sql. Yuck.
        #  table_ref = extract_table_ref_from_insert_sql(sql)
        #  pk = primary_key(table_ref) if table_ref
        #end
        #
        #if pk
        #  select_value("#{sql} RETURNING #{quote_column_name(pk)}")
        #else
        #  super
        #end
      end
      alias :create :insert

      # create a 2D array representing the result set
      def result_as_array(res) #:nodoc:

        # CJR 11-12-14 We need to convert everything other than string because
        # everything is coming back as string (we are not converting char(8) or varchar(9))
        convert_types = {boolean: 5, integer: 6, float: 7, string: 9, numeric: 16, date: 10, time: 11, timestamp: 12}

        # check if we have any binary column and if they need escaping
        ftypes = Array.new(res.nfields) do |i|
          [i, res.ftype(i)]
        end

        rows = res.values


        return rows unless ftypes.any? { |_, x|
          convert_types.values.include?(x) || x == BYTEA_COLUMN_TYPE_OID || x == MONEY_COLUMN_TYPE_OID
        }

        typehash = ftypes.group_by { |_, type| type }
        binaries = typehash[BYTEA_COLUMN_TYPE_OID] || []
        monies   = typehash[MONEY_COLUMN_TYPE_OID] || []
        integers = typehash[6] || []
        floats   = typehash[16] || []
        floats   += typehash[7] unless typehash[7].nil?
        strings  = typehash[9] || []
        dates    = typehash[10] || []
        # CJR 11-12-14 not converting boolean, time and timestamp because we don't use them

        rows.each do |row|
          # unescape string passed BYTEA field (OID == 17)
          binaries.each do |index, _|
            row[index] = unescape_bytea(row[index])
          end

          integers.each do |index, _|
            row[index] = row[index].to_i
          end
          floats.each do |index, _|
            row[index] = row[index].to_f
          end
          dates.each do |index, _|
            row[index] = Date.parse(row[index])
          end
          strings.each do |index, _|
            row[index] = row[index].force_encoding('UTF-8') if row[index]
          end
          # If this is a money type column and there are any currency symbols,
          # then strip them off. Indeed it would be prettier to do this in
          # PostgreSQLColumn.string_to_decimal but would break form input
          # fields that call value_before_type_cast.
          monies.each do |index, _|
            data = row[index]
            # Because money output is formatted according to the locale, there are two
            # cases to consider (note the decimal separators):
            #  (1) $12,345,678.12
            #  (2) $12.345.678,12
            case data
              when /^-?\D+[\d,]+\.\d{2}$/  # (1)
                data.gsub!(/[^-\d.]/, '')
              when /^-?\D+[\d.]+,\d{2}$/  # (2)
                data.gsub!(/[^-\d,]/, '').sub!(/,/, '.')
            end
          end
        end
      end


      # Queries the database and returns the results in an Array-like object
      def query(sql, name = nil) #:nodoc:
        log(sql, name) do
          result_as_array @connection.async_exec(sql)
        end
      end

      # Executes an SQL statement, returning a PGresult object on success
      # or raising a PGError exception otherwise.
      def execute(sql, name = nil)
        log(sql, name) do
          @connection.async_exec(sql)
        end
      end

      def exec_query(sql, name = 'SQL', binds = [], prepare: false)
        execute_and_clear(sql, name, binds, prepare: prepare) do |result|
          ActiveRecord::Result.new(result.fields, result_as_array(result))
        end
      end

      def exec_delete(sql, name = 'SQL', binds = [])
        execute_and_clear(sql, name, binds) {|result| result.cmd_tuples }
      end
      alias :exec_update :exec_delete

      def sql_for_insert(sql, pk, id_value, sequence_name, binds)
        # note: Vertica doesn't have PK's
        #unless pk
        #  # Extract the table from the insert sql. Yuck.
        #  table_ref = extract_table_ref_from_insert_sql(sql)
        #  pk = primary_key(table_ref) if table_ref
        #end
        #sql = "#{sql} RETURNING #{quote_column_name(pk)}" if pk
        [sql, binds]
      end

      # Executes an UPDATE query and returns the number of affected tuples.
      def update_sql(sql, name = nil)
        super.cmd_tuples
      end

      # Begins a transaction.
      def begin_db_transaction
        execute "BEGIN"
      end

      # Commits a transaction.
      def commit_db_transaction
        execute "COMMIT" unless outside_transaction?
      end

      # Aborts a transaction.
      def rollback_db_transaction
        execute "ROLLBACK" unless outside_transaction?
      end

      def outside_transaction?
        @connection.transaction_status == PGconn::PQTRANS_IDLE
      end

      def create_savepoint(name = nil)
        execute("SAVEPOINT #{name}") unless outside_transaction?
      end

      def rollback_to_savepoint(name = nil)
        execute("ROLLBACK TO SAVEPOINT #{name}") unless outside_transaction?
      end

      def release_savepoint(name = nil)
        execute("RELEASE SAVEPOINT #{name}") unless outside_transaction?
      end

      # SCHEMA STATEMENTS ========================================

      # Drops the database specified on the +name+ attribute
      # and creates it again using the provided +options+.
      def recreate_database(name, options = {}) #:nodoc:
        drop_database(name)
        create_database(name, options)
      end

      # Create a new PostgreSQL database. Options include <tt>:owner</tt>, <tt>:template</tt>,
      # <tt>:encoding</tt>, <tt>:tablespace</tt>, and <tt>:connection_limit</tt> (note that MySQL uses
      # <tt>:charset</tt> while PostgreSQL uses <tt>:encoding</tt>).
      #
      # Example:
      #   create_database config[:database], config
      #   create_database 'foo_development', :encoding => 'unicode'
      def create_database(name, options = {})
        # options = options.reverse_merge(:encoding => "utf8")

        option_string = options.symbolize_keys.sum do |key, value|
          case key
            when :owner
              " OWNER = \"#{value}\""
            when :template
              " TEMPLATE = \"#{value}\""
            # when :encoding
            #   " ENCODING = '#{value}'"
            when :tablespace
              " TABLESPACE = \"#{value}\""
            when :connection_limit
              " CONNECTION LIMIT = #{value}"
            else
              ""
          end
        end

        execute "CREATE DATABASE #{quote_table_name(name, false)}#{option_string}"
      end

      # Drops a PostgreSQL database.
      #
      # Example:
      #   drop_database 'matt_development'
      def drop_database(name) #:nodoc:
        execute "DROP DATABASE IF EXISTS #{quote_table_name(name, false)}"
      end

      # Drops a PostgreSQL table.
      # If the schema is not specified as part of +name+ then it will use the current schema
      #
      # Example:
      #   drop_table 'cjo_gss_dev.s1_rmonths'
      def drop_table(table_name, options = {}) #:nodoc:
        execute "DROP TABLE IF EXISTS #{quote_table_name(table_name, true)}"
      end

      # Returns the list of all tables in the specified or current schema, if none specified.
      def views(name = nil)
        query(<<-SQL, 'SCHEMA').map { |row| row[0] }
          SELECT table_name FROM views
          WHERE table_schema = '#{current_schema}';
        SQL
      end

      # Returns true if table exists.
      # If the schema is not specified as part of +name+ then it will only find tables within
      # the current schema (regardless of permissions to access tables in other schemas)
      def views_exists?(name)
        schema, name = get_schema_and_name(name)
        exec_query(<<-SQL, 'SCHEMA').rows.first[0].to_i > 0
          SELECT COUNT(*)
          FROM tables
          WHERE table_name = '#{name}'
          AND table_schema = '#{schema}'
        SQL
      end

      # Returns the list of all tables in the specified or current schema, if none specified.
      def tables(name = nil)
        query(<<-SQL, 'SCHEMA').map { |row| row[0] }
          SELECT table_name FROM tables
          WHERE table_schema = '#{current_schema}';
        SQL
      end

      # Returns true if table exists.
      # If the schema is not specified as part of +name+ then it will only find tables within
      # the current schema (regardless of permissions to access tables in other schemas)
      def table_exists?(name)
        schema, name = get_schema_and_name(name)
        exec_query(<<-SQL, 'SCHEMA').rows.first[0].to_i > 0
          SELECT COUNT(*)
          FROM tables
          WHERE table_name = '#{name}'
          AND table_schema = '#{schema}'
        SQL
      end

      # Returns true if schema exists.
      def schema_exists?(name)
        exec_query(<<-SQL, 'SCHEMA').rows.first[0].to_i > 0
          SELECT COUNT(*)
          FROM pg_namespace
          WHERE nspname = '#{name}'
        SQL
      end

      # Returns an array of indexes for the given table.
      def indexes(table_name, name = nil)
        []
      end

      # Returns the list of all column definitions for a table.
      def columns(table_name, name = nil)
        # Limit, precision, and scale are all handled by the superclass.
        column_definitions(table_name).collect do |column_name, type, default, null|
          VerticaColumn.new(column_name, default, self.lookup_cast_type(type), null == 't')
        end
      end

      # Returns the current database name.
      def current_database
        query('select current_database()', 'SCHEMA')[0][0]
      end

      # Returns the current schema name.
      def current_schema
        query('SELECT current_schema', 'SCHEMA')[0][0]
      end

      # Returns the current database encoding format.
      def encoding
        query(<<-end_sql, 'SCHEMA')[0][0]
          SELECT pg_encoding_to_char(pg_database.encoding) FROM pg_database
          WHERE pg_database.datname LIKE '#{current_database}'
        end_sql
      end

      # Sets the schema search path to a string of comma-separated schema names.
      # Names beginning with $ have to be quoted (e.g. $user => '$user').
      # See: http://www.postgresql.org/docs/current/static/ddl-schemas.html
      #
      # This should be not be called manually but set in database.yml.
      def schema_search_path=(schema_csv)
        if schema_csv
          execute("SET search_path TO #{schema_csv}", 'SCHEMA')
          @schema_search_path = schema_csv
        end
      end

      # Returns the active schema search path.
      def schema_search_path
        @schema_search_path ||= query('SHOW search_path', 'SCHEMA')[0][0]
      end

      # Returns the sequence name for a table's primary key or some other specified key.
      def default_sequence_name(table_name, pk = nil) #:nodoc:
        serial_sequence(table_name, pk || 'id').split('.').last
      rescue ActiveRecord::StatementInvalid
        "#{table_name}_#{pk || 'id'}_seq"
      end

      def serial_sequence(table, column)
        result = exec_query(<<-eosql, 'SCHEMA')
          SELECT pg_get_serial_sequence('#{table}', '#{column}')
        eosql
        result.rows.first.first
      end

      # Renames a table.
      # Also renames a table's primary key sequence if the sequence name matches the
      # Active Record default.
      #
      # Example:
      #   rename_table('octopuses', 'octopi')
      def rename_table(name, new_name)
        clear_cache!
        execute "ALTER TABLE #{quote_table_name(name, true)} RENAME TO #{quote_table_name(new_name, true)}"
      end

      # Adds a new column to the named table.
      # See TableDefinition#column for details of the options you can use.
      def add_column(table_name, column_name, type, options = {})
        clear_cache!
        super
      end

      # Changes the column of a table.
      def change_column(table_name, column_name, type, options = {})
        clear_cache!
        quoted_table_name = quote_table_name(table_name, true)

        execute "ALTER TABLE #{quoted_table_name} ALTER COLUMN #{quote_column_name(column_name)} TYPE #{type_to_sql(type, options[:limit], options[:precision], options[:scale])}"

        change_column_default(table_name, column_name, options[:default]) if options_include_default?(options)
        change_column_null(table_name, column_name, options[:null], options[:default]) if options.key?(:null)
      end

      # Changes the default value of a table column.
      def change_column_default(table_name, column_name, default)
        clear_cache!
        execute "ALTER TABLE #{quote_table_name(table_name, true)} ALTER COLUMN #{quote_column_name(column_name)} SET DEFAULT #{quote(default)}"
      end

      def change_column_null(table_name, column_name, null, default = nil)
        clear_cache!
        unless null || default.nil?
          execute("UPDATE #{quote_table_name(table_name, true)} SET #{quote_column_name(column_name)}=#{quote(default)} WHERE #{quote_column_name(column_name)} IS NULL")
        end
        execute("ALTER TABLE #{quote_table_name(table_name, true)} ALTER #{quote_column_name(column_name)} #{null ? 'DROP' : 'SET'} NOT NULL")
      end

      # Renames a column in a table.
      def rename_column(table_name, column_name, new_column_name)
        clear_cache!
        execute "ALTER TABLE #{quote_table_name(table_name, true)} RENAME COLUMN #{quote_column_name(column_name)} TO #{quote_column_name(new_column_name)}"
      end

      def remove_column(table_name, column_name, type = nil, options = {})
        clear_cache!
        execute "ALTER TABLE #{quote_table_name(table_name)} DROP COLUMN #{quote_column_name(column_name)} CASCADE"
      end

      def remove_index!(table_name, index_name) #:nodoc:
        execute "DROP INDEX #{quote_table_name(index_name, true)}"
      end

      def rename_index(table_name, old_name, new_name)
        execute "ALTER INDEX #{quote_column_name(old_name)} RENAME TO #{quote_column_name(new_name)}"
      end

      def index_name_length
        63
      end

      # Maps logical Rails types to PostgreSQL-specific data types.
      def type_to_sql(type, limit = nil, precision = nil, scale = nil)
        case type.to_s
          when 'binary'
            # PostgreSQL doesn't support limits on binary (bytea) columns.
            # The hard limit is 1Gb, because of a 32-bit size field, and TOAST.
            case limit
              when nil, 0..0x3fffffff; super(type)
              else raise(ActiveRecordError, "No binary type has byte size #{limit}.")
            end
          when 'text'
            # note: adapted for Vertica
            case limit
              when nil, 0..65000; "varchar(#{limit})"
              else raise(ActiveRecordError, "The limit on varchar in Vertica can be at most 65000 bytes.")
            end
          when 'integer'
            return 'integer' unless limit

            case limit
              when 1, 2; 'smallint'
              when 3, 4; 'integer'
              when 5..8; 'bigint'
              else raise(ActiveRecordError, "No integer type has byte size #{limit}. Use a numeric with precision 0 instead.")
            end
          else
            super
        end
      end

      # Returns just a table's primary key
      def primary_key(table)
        'id'
      end

      # Returns a SELECT DISTINCT clause for a given set of columns and a given ORDER BY clause.
      #
      # PostgreSQL requires the ORDER BY columns in the select list for distinct queries, and
      # requires that the ORDER BY include the distinct column.
      #
      #   distinct("posts.id", "posts.created_at desc")
      def distinct(columns, orders) #:nodoc:
        return "DISTINCT #{columns}" if orders.empty?

        # Construct a clean list of column names from the ORDER BY clause, removing
        # any ASC/DESC modifiers
        order_columns = orders.collect { |s| s.gsub(/\s+(ASC|DESC)\s*(NULLS\s+(FIRST|LAST)\s*)?/i, '') }
        order_columns.delete_if { |c| c.blank? }
        order_columns = order_columns.zip((0...order_columns.size).to_a).map { |s,i| "#{s} AS alias_#{i}" }

        "DISTINCT #{columns}, #{order_columns * ', '}"
      end

      module Utils
        extend self

        # Returns an array of <tt>[schema_name, table_name]</tt> extracted from +name+.
        # +schema_name+ is nil if not specified in +name+.
        # +schema_name+ and +table_name+ exclude surrounding quotes (regardless of whether provided in +name+)
        # +name+ supports the range of schema/table references understood by PostgreSQL, for example:
        #
        # * <tt>table_name</tt>
        # * <tt>"table.name"</tt>
        # * <tt>schema_name.table_name</tt>
        # * <tt>schema_name."table.name"</tt>
        # * <tt>"schema.name"."table name"</tt>
        def extract_schema_and_table(name)
          table, schema = name.scan(/[^".\s]+|"[^"]*"/)[0..1].collect{|m| m.gsub(/(^"|"$)/,'') }.reverse
          [schema, table]
        end
      end

      protected
      def extract_limit(sql_type) # :nodoc:
        case sql_type
          when /^int/i
            8
          when /\((.*)\)/
            $1.to_i
        end
      end

      # FIXME: Double check this on Vertica
      # Returns the version of the connected PostgreSQL server.
      def postgresql_version
        @connection.server_version
      end

      # See http://www.postgresql.org/docs/9.1/static/errcodes-appendix.html
      FOREIGN_KEY_VIOLATION = "23503"
      UNIQUE_VIOLATION      = "23505"

      # def translate_exception(exception, message)
      #   case exception.result.error_field(PGresult::PG_DIAG_SQLSTATE)
      #   when UNIQUE_VIOLATION
      #     RecordNotUnique.new(message, exception)
      #   when FOREIGN_KEY_VIOLATION
      #     InvalidForeignKey.new(message, exception)
      #   else
      #     super
      #   end
      # end

      private
      FEATURE_NOT_SUPPORTED = "0A000" # :nodoc:

      def execute_and_clear(sql, name, binds, prepare: false)
        if without_prepared_statement?(binds)
          result = exec_no_cache(sql, name, [])
        elsif !prepare
          result = exec_no_cache(sql, name, binds)
        else
          result = exec_cache(sql, name, binds)
        end
        ret = yield result
        result.clear
        ret
      end

      def exec_no_cache(sql, name, binds)
        @connection.async_exec(sql)
      end

      def exec_cache(sql, name, binds)
        begin
          stmt_key = prepare_statement sql

          # Clear the queue
          @connection.get_last_result
          @connection.send_query_prepared(stmt_key, binds.map { |col, val|
            type_cast(val, col)
          })
          @connection.block
          @connection.get_last_result
        rescue PGError => e
          # Get the PG code for the failure.  Annoyingly, the code for
          # prepared statements whose return value may have changed is
          # FEATURE_NOT_SUPPORTED.  Check here for more details:
          # http://git.postgresql.org/gitweb/?p=postgresql.git;a=blob;f=src/backend/utils/cache/plancache.c#l573
          code = e.result.result_error_field(PGresult::PG_DIAG_SQLSTATE)
          if FEATURE_NOT_SUPPORTED == code
            @statements.delete sql_key(sql)
            retry
          else
            raise e
          end
        end
      end

      # Returns the statement identifier for the client side cache
      # of statements
      def sql_key(sql)
        "#{schema_search_path}-#{sql}"
      end

      # Prepare the statement if it hasn't been prepared, return
      # the statement key.
      def prepare_statement(sql)
        sql_key = sql_key(sql)
        unless @statements.key? sql_key
          nextkey = @statements.next_key
          @connection.prepare nextkey, sql
          @statements[sql_key] = nextkey
        end
        @statements[sql_key]
      end

      # The internal PostgreSQL identifier of the money data type.
      MONEY_COLUMN_TYPE_OID = 790 #:nodoc:
      # The internal PostgreSQL identifier of the BYTEA data type.
      BYTEA_COLUMN_TYPE_OID = 17 #:nodoc:

      # Connects to a PostgreSQL server and sets up the adapter depending on the
      # connected server's characteristics.
      def connect
        @connection = PGconn.connect(*@connection_parameters)

        # Money type has a fixed precision of 10 in PostgreSQL 8.2 and below, and as of
        # PostgreSQL 8.3 it has a fixed precision of 19. PostgreSQLColumn.extract_precision
        # should know about this but can't detect it there, so deal with it here.
        VerticaColumn.money_precision = (postgresql_version >= 80300) ? 19 : 10

        configure_connection
      end

      # Configures the encoding, verbosity, schema search path, and time zone of the connection.
      # This is called by #connect and should not be called manually.
      def configure_connection
        # if @config[:encoding]
        #   @connection.set_client_encoding(@config[:encoding])
        # end
        self.schema_search_path = @config[:schema_search_path] || @config[:schema_order]

        # Use standard-conforming strings if available so we don't have to do the E'...' dance.
        set_standard_conforming_strings

        # If using Active Record's time zone support configure the connection to return
        # TIMESTAMP WITH ZONE types in UTC.
        if ActiveRecord::Base.default_timezone == :utc
          execute("SET time zone 'UTC'", 'SCHEMA')
        elsif @local_tz
          execute("SET time zone '#{@local_tz}'", 'SCHEMA')
        end

        execute("SET SESSION AUTOCOMMIT TO  ON")

      end

      # Returns the current ID of a table's id.
      def last_insert_id(sequence_name) #:nodoc:
        r = exec_query("SELECT currval('id')", 'SQL')
        Integer(r.rows.first.first)
      end

      def select_raw(sql, name = nil)
        res = execute(sql, name)
        results = result_as_array(res)
        fields = res.fields
        res.clear
        return fields, results
      end

      # Returns the list of a table's column names, data types, and default values.
      #
      # The underlying query is roughly:
      #  SELECT column.name, column.type, default.value
      #    FROM column LEFT JOIN default
      #      ON column.table_id = default.table_id
      #     AND column.num = default.column_num
      #   WHERE column.table_id = get_table_id('table_name')
      #     AND column.num > 0
      #     AND NOT column.is_dropped
      #   ORDER BY column.num
      #
      # If the table name is not prefixed with a schema, the database will
      # use the current schema
      #
      # Query implementation notes:
      #  - format_type includes the column size constraint, e.g. varchar(50)
      #  - ::regclass is a function that gives the id for a table name
      def column_definitions(table_name) #:nodoc:
        schema, name = get_schema_and_name(table_name)
        exec_query(<<-end_sql, 'SCHEMA').rows
            SELECT column_name, data_type, column_default, is_nullable
            FROM columns
            WHERE table_name = '#{name}'
            AND table_schema = '#{schema}'
        end_sql
      end

      def extract_pg_identifier_from_name(name)
        match_data = name.start_with?('"') ? name.match(/\"([^\"]+)\"/) : name.match(/([^\.]+)/)

        if match_data
          rest = name[match_data[0].length, name.length]
          rest = rest[1, rest.length] if rest.start_with? "."
          [match_data[1], (rest.length > 0 ? rest : nil)]
        end
      end

      def extract_table_ref_from_insert_sql(sql)
        sql[/into\s+([^\(]*).*values\s*\(/i]
        $1.strip if $1
      end

      def table_definition
        TableDefinition.new(self)
      end

      def get_schema_and_name(name)
        schema, table = Utils.extract_schema_and_table(name)
        schema = current_schema if schema.nil?
        [schema, table]
      end

    end
  end
end
