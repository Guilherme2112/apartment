require 'apartment/adapters/abstract_adapter'

module Apartment
  module Database

    def self.postgresql_adapter(config)
      adapter = Adapters::PostgresqlAdapter
      adapter = Adapters::PostgresqlSchemaAdapter if Apartment.use_schemas
      adapter = Adapters::PostgresqlSchemaFromSqlAdapter if Apartment.use_sql && Apartment.use_schemas
      adapter.new(config)
    end
  end

  module Adapters
    # Default adapter when not using Postgresql Schemas
    class PostgresqlAdapter < AbstractAdapter

      def drop(tenant)
        # Apartment.connection.drop_database note that drop_database will not throw an exception, so manually execute
        Apartment.connection.execute(%{DROP DATABASE "#{tenant}"})

      rescue *rescuable_exceptions
        raise DatabaseNotFound, "The tenant #{tenant} cannot be found"
      end

    private

      def rescue_from
        PGError
      end
    end

    # Separate Adapter for Postgresql when using schemas
    class PostgresqlSchemaAdapter < AbstractAdapter

      def initialize(config)
        super

        reset
      end

      #   Drop the tenant
      #
      #   @param {String} tenant Database (schema) to drop
      #
      def drop(tenant)
        Apartment.connection.execute(%{DROP SCHEMA "#{tenant}" CASCADE})

      rescue *rescuable_exceptions
        raise SchemaNotFound, "The schema #{tenant.inspect} cannot be found."
      end

      #   Reset search path to default search_path
      #   Set the table_name to always use the default namespace for excluded models
      #
      def process_excluded_models
        Apartment.excluded_models.each do |excluded_model|
          excluded_model.constantize.tap do |klass|
            # some models (such as delayed_job) seem to load and cache their column names before this,
            # so would never get the default prefix, so reset first
            klass.reset_column_information

            # Ensure that if a schema *was* set, we override
            table_name = klass.table_name.split('.', 2).last

            klass.table_name = "#{Apartment.default_schema}.#{table_name}"
          end
        end
      end

      #   Reset schema search path to the default schema_search_path
      #
      #   @return {String} default schema search path
      #
      def reset
        @current_tenant = Apartment.default_schema
        Apartment.connection.schema_search_path = full_search_path
      end

      def current_tenant
        @current_tenant || Apartment.default_schema
      end

    protected

      #   Set schema search path to new schema
      #
      def connect_to_new(tenant = nil)
        return reset if tenant.nil?
        raise ActiveRecord::StatementInvalid.new("Could not find schema #{tenant}") unless Apartment.connection.schema_exists? tenant

        @current_tenant = tenant.to_s
        Apartment.connection.schema_search_path = full_search_path

      rescue *rescuable_exceptions
        raise SchemaNotFound, "One of the following schema(s) is invalid: #{tenant}, #{full_search_path}"
      end

      #   Create the new schema
      #
      def create_tenant(tenant)
        Apartment.connection.execute(%{CREATE SCHEMA "#{tenant}"})

      rescue *rescuable_exceptions
        raise SchemaExists, "The schema #{tenant} already exists."
      end

    private

      #   Generate the final search path to set including persistent_schemas
      #
      def full_search_path
        persistent_schemas.map(&:inspect).join(", ")
      end

      def persistent_schemas
        [@current_tenant, Apartment.persistent_schemas].flatten
      end
    end

    # Another Adapter for Postgresql when using schemas and SQL
    class PostgresqlSchemaFromSqlAdapter < PostgresqlSchemaAdapter

      def import_database_schema
        clone_pg_schema
        copy_schema_migrations
      end

    private

      # Clone default schema into new schema named after current tenant
      #
      def clone_pg_schema
        pg_schema_sql = patch_search_path(pg_dump_schema)
        Apartment.connection.execute(pg_schema_sql)
      end

      # Copy data from schema_migrations into new schema
      #
      def copy_schema_migrations
        pg_migrations_data = patch_search_path(pg_dump_schema_migrations_data)
        Apartment.connection.execute(pg_migrations_data)
      end

      #   Dump postgres default schema
      #
      #   @return {String} raw SQL contaning only postgres schema dump
      #
      def pg_dump_schema
        dbname = ActiveRecord::Base.connection_config[:database]
        default_schema = Apartment.default_schema

        # Skip excluded tables? :/
        # excluded_tables =
        #   collect_table_names(Apartment.excluded_models)
        #   .map! {|t| "-T #{t}"}
        #   .join(' ')

        # `pg_dump -s -x -O -n #{default_schema} #{excluded_tables} #{dbname}`

        `pg_dump -s -x -O -n #{default_schema} #{dbname}`
      end

      #   Dump data from schema_migrations table
      #
      #   @return {String} raw SQL contaning inserts with data from schema_migrations
      #
      def pg_dump_schema_migrations_data
        `pg_dump -a --inserts -t schema_migrations -n #{Apartment.default_schema} bithub_development`
      end

      #   Remove "SET search_path ..." line from SQL dump and prepend search_path set to current tenant
      #
      #   @return {String} patched raw SQL dump
      #
      def patch_search_path(sql)
        search_path = "SET search_path = #{self.current_tenant}, #{Apartment.default_schema};"

        sql
          .split("\n")
          .reject {|line| line.starts_with? "SET search_path"}
          .prepend(search_path)
          .join("\n")
      end

      #   Collect table names from AR Models
      #
      def collect_table_names(models)
        models.map do |m|
          m.constantize.table_name
        end
      end

    end


  end
end
