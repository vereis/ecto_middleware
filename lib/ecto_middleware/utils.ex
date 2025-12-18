defmodule EctoMiddleware.Utils do
  @moduledoc """
  Utility functions and guards for working with middleware operations.

  ## Guards for Operation Detection

  Use guards in middleware to detect operation types, especially useful for
  `insert_or_update` which can be either an insert or update:

      defmodule SmartTimestamp do
        use EctoMiddleware

        def process_before(changeset, resolution) do
          changeset = cond do
            is_insert(changeset, resolution.action) ->
              changeset
              |> put_change(:created_at, DateTime.utc_now())
              |> put_change(:updated_at, DateTime.utc_now())

            is_update(changeset, resolution.action) ->
              put_change(changeset, :updated_at, DateTime.utc_now())

            true ->
              changeset
          end

          {:cont, changeset}
        end
      end

  ### Available Guards

  - `is_read/2` - Matches read operations (get, get!, all, etc.)
  - `is_write/2` - Matches write operations (insert, update, delete, etc.)
  - `is_insert/2` - Matches inserts (including insert_or_update with new records)
  - `is_update/2` - Matches updates (including insert_or_update with existing records)
  - `is_delete/2` - Matches delete operations
  - `is_preload/2` - Matches preload operations

  ### How `insert_or_update` Detection Works

  For `insert_or_update` actions, the guards inspect the changeset's `__meta__.state`:

      # New record (insert)
      changeset.data.__meta__.state == :built
      
      # Existing record (update)
      changeset.data.__meta__.state == :loaded

  ## Result Transformation

  Use `apply/3` to transform Ecto results while preserving their structure:

      defmodule EnrichUsers do
        use EctoMiddleware

        def process_after(result, resolution) do
          enriched = Utils.apply(result, resolution, fn user ->
            %{user | full_name: "\#{user.first_name} \#{user.last_name}"}
          end)
          
          {:cont, enriched}
        end
      end

  `apply/3` handles all common Ecto return types:
  - `{:ok, value}` → `{:ok, transformed}`
  - `{:error, reason}` → unchanged
  - `[values]` → `[transformed values]`
  - `nil` → unchanged
  - `{count, list}` → `{count, [transformed values]}`
  - Bare values → `transformed`

  See `apply/3` documentation for complete examples.
  """

  @read_actions [:get, :get!, :get_by, :get_by!, :one, :one!, :all, :reload, :reload!, :preload]
  @insert_actions [:insert, :insert!]
  @update_actions [:update, :update!]
  @delete_actions [:delete, :delete!]
  @insert_or_update_actions [:insert_or_update, :insert_or_update!]

  # ============================================
  # Guards
  # ============================================

  @doc """
  Guard that matches read actions.

  Matches the action atoms for the following `Ecto.Repo` callbacks:
  `c:Ecto.Repo.get/3`, `c:Ecto.Repo.get!/3`, `c:Ecto.Repo.get_by/3`, `c:Ecto.Repo.get_by!/3`,
  `c:Ecto.Repo.one/2`, `c:Ecto.Repo.one!/2`, `c:Ecto.Repo.all/2`, `c:Ecto.Repo.reload/2`,
  `c:Ecto.Repo.reload!/2`, `c:Ecto.Repo.preload/3`
  """
  defguard is_read(_changeset, action) when action in @read_actions

  @doc """
  Guard that matches write actions (anything not a read).

  Matches the action atoms for the following `Ecto.Repo` callbacks:
  `c:Ecto.Repo.insert/2`, `c:Ecto.Repo.insert!/2`, `c:Ecto.Repo.update/2`, `c:Ecto.Repo.update!/2`,
  `c:Ecto.Repo.delete/2`, `c:Ecto.Repo.delete!/2`, `c:Ecto.Repo.insert_or_update/2`,
  `c:Ecto.Repo.insert_or_update!/2`
  """
  defguard is_write(_changeset, action) when action not in @read_actions

  @doc """
  Guard that matches insert actions.

  Matches the action atoms for `c:Ecto.Repo.insert/2` and `c:Ecto.Repo.insert!/2`.

  Also matches `c:Ecto.Repo.insert_or_update/2` and `c:Ecto.Repo.insert_or_update!/2` when
  the record is new (changeset's `__meta__.state` is `:built`).
  """
  defguard is_insert(changeset, action)
           when action in @insert_actions or
                  (action in @insert_or_update_actions and changeset.data.__meta__.state == :built)

  @doc """
  Guard that matches update actions.

  Matches the action atoms for `c:Ecto.Repo.update/2` and `c:Ecto.Repo.update!/2`.

  Also matches `c:Ecto.Repo.insert_or_update/2` and `c:Ecto.Repo.insert_or_update!/2` when
  the record already exists (changeset's `__meta__.state` is `:loaded`).
  """
  defguard is_update(changeset, action)
           when action in @update_actions or
                  (action in @insert_or_update_actions and changeset.data.__meta__.state == :loaded)

  @doc """
  Guard that matches delete actions.

  Matches the action atoms for `c:Ecto.Repo.delete/2` and `c:Ecto.Repo.delete!/2`.
  """
  defguard is_delete(_changeset, action) when action in @delete_actions

  @doc """
  Guard that matches the preload action.

  Matches the action atom for `c:Ecto.Repo.preload/3`.
  """
  defguard is_preload(_changeset, action) when action == :preload

  # ============================================
  # Result Transformation
  # ============================================

  @doc """
  Applies a function to the "inner" value of an Ecto result, handling all common return types.

  The second argument is reserved for future use and currently ignored. You can pass the
  resolution struct or any placeholder value.

  ## Return Type Handling

  | Input | Output |
  |-------|--------|
  | `{:ok, value}` | `{:ok, fun.(value)}` |
  | `{:error, reason}` | `{:error, reason}` (unchanged) |
  | `[values]` | `Enum.map(values, fun)` |
  | `nil` | `nil` (unchanged) |
  | `{count, list}` | `{count, Enum.map(list, fun)}` |
  | `{count, nil}` | `{count, nil}` (unchanged) |
  | bare value | `fun.(value)` |

  ## Examples

      # In process_after/2
      def process_after(result, resolution) do
        {:cont, Utils.apply(result, resolution, &Map.put(&1, :enriched, true))}
      end

      # {:ok, struct} -> {:ok, enriched_struct}
      Utils.apply({:ok, user}, resolution, &Map.put(&1, :enriched, true))
      #=> {:ok, %User{enriched: true, ...}}

      # {:error, changeset} -> {:error, changeset} (unchanged)
      Utils.apply({:error, changeset}, resolution, &Map.put(&1, :enriched, true))
      #=> {:error, changeset}

      # [structs] -> [enriched_structs]
      Utils.apply([user1, user2], resolution, &Map.put(&1, :enriched, true))
      #=> [%User{enriched: true}, %User{enriched: true}]

      # nil -> nil
      Utils.apply(nil, resolution, &Map.put(&1, :enriched, true))
      #=> nil

      # {count, list} from update_all/delete_all
      Utils.apply({3, [user1, user2, user3]}, resolution, &Map.put(&1, :processed, true))
      #=> {3, [%User{processed: true}, ...]}
  """
  @spec apply(result :: term(), context :: struct(), fun :: (term() -> term())) :: term()
  def apply(result, context, fun)

  def apply({:ok, value}, _context, fun), do: {:ok, fun.(value)}
  def apply({:error, _} = error, _context, _fun), do: error
  def apply(nil, _context, _fun), do: nil
  def apply([], _context, _fun), do: []
  def apply(list, _context, fun) when is_list(list), do: Enum.map(list, fun)
  def apply({count, nil}, _context, _fun) when is_integer(count), do: {count, nil}

  def apply({count, list}, _context, fun) when is_integer(count) and is_list(list) do
    {count, Enum.map(list, fun)}
  end

  def apply(value, _context, fun), do: fun.(value)
end
