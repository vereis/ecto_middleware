defmodule EctoMiddleware.UtilsTest do
  @moduledoc """
  Tests for EctoMiddleware.Utils module.
  """
  use ExUnit.Case, async: true

  import EctoMiddleware.Utils

  alias Ecto.Schema.Metadata
  alias EctoMiddleware.Test.Schemas.User
  alias EctoMiddleware.Utils

  # Helper to create changesets with different states
  defp built_changeset do
    %Ecto.Changeset{data: %User{__meta__: %Metadata{state: :built}}}
  end

  defp loaded_changeset do
    %Ecto.Changeset{data: %User{__meta__: %Metadata{state: :loaded}}}
  end

  describe "guards: is_read/2" do
    test "matches read actions" do
      assert is_read(nil, :get)
      assert is_read(nil, :get!)
      assert is_read(nil, :get_by)
      assert is_read(nil, :get_by!)
      assert is_read(nil, :one)
      assert is_read(nil, :one!)
      assert is_read(nil, :all)
      assert is_read(nil, :reload)
      assert is_read(nil, :reload!)
      assert is_read(nil, :preload)
    end

    test "does not match write actions" do
      refute is_read(nil, :insert)
      refute is_read(nil, :update)
      refute is_read(nil, :delete)
      refute is_read(nil, :insert_or_update)
    end
  end

  describe "guards: is_write/2" do
    test "matches write actions" do
      assert is_write(nil, :insert)
      assert is_write(nil, :update)
      assert is_write(nil, :delete)
      assert is_write(nil, :insert_or_update)
    end

    test "does not match read actions" do
      refute is_write(nil, :get)
      refute is_write(nil, :all)
      refute is_write(nil, :preload)
    end
  end

  describe "guards: is_insert/2" do
    test "matches insert actions" do
      cs = built_changeset()
      assert is_insert(cs, :insert)
      assert is_insert(cs, :insert!)
    end

    test "matches insert_or_update with :built state" do
      cs = built_changeset()
      assert is_insert(cs, :insert_or_update)
      assert is_insert(cs, :insert_or_update!)
    end

    test "does not match insert_or_update with :loaded state" do
      cs = loaded_changeset()
      refute is_insert(cs, :insert_or_update)
      refute is_insert(cs, :insert_or_update!)
    end

    test "does not match other actions" do
      cs = built_changeset()
      refute is_insert(cs, :update)
      refute is_insert(cs, :delete)
      refute is_insert(cs, :get)
    end
  end

  describe "guards: is_update/2" do
    test "matches update actions" do
      cs = loaded_changeset()
      assert is_update(cs, :update)
      assert is_update(cs, :update!)
    end

    test "matches insert_or_update with :loaded state" do
      cs = loaded_changeset()
      assert is_update(cs, :insert_or_update)
      assert is_update(cs, :insert_or_update!)
    end

    test "does not match insert_or_update with :built state" do
      cs = built_changeset()
      refute is_update(cs, :insert_or_update)
      refute is_update(cs, :insert_or_update!)
    end

    test "does not match other actions" do
      cs = loaded_changeset()
      refute is_update(cs, :insert)
      refute is_update(cs, :delete)
      refute is_update(cs, :get)
    end
  end

  describe "guards: is_delete/2" do
    test "matches delete actions" do
      assert is_delete(nil, :delete)
      assert is_delete(nil, :delete!)
    end

    test "does not match other actions" do
      refute is_delete(nil, :insert)
      refute is_delete(nil, :update)
      refute is_delete(nil, :get)
    end
  end

  describe "guards: is_preload/2" do
    test "matches preload action" do
      assert is_preload(nil, :preload)
    end

    test "does not match other actions" do
      refute is_preload(nil, :insert)
      refute is_preload(nil, :get)
      refute is_preload(nil, :all)
    end
  end

  describe "apply/3" do
    test "with {:ok, value}, applies function to inner value" do
      result = Utils.apply({:ok, 1}, %{}, &(&1 * 2))
      assert result == {:ok, 2}
    end

    test "with {:ok, value}, preserves :ok tuple wrapper" do
      result = Utils.apply({:ok, %{a: 1}}, %{}, &Map.put(&1, :b, 2))
      assert result == {:ok, %{a: 1, b: 2}}
    end

    test "with {:error, reason}, returns error unchanged" do
      result = Utils.apply({:error, :failed}, %{}, &(&1 * 2))
      assert result == {:error, :failed}
    end

    test "with {:error, reason}, does not call function" do
      Utils.apply({:error, :failed}, %{}, fn _ ->
        send(self(), :should_not_run)
        :result
      end)

      refute_received :should_not_run
    end

    test "with list, maps function over all elements" do
      result = Utils.apply([1, 2, 3], %{}, &(&1 * 2))
      assert result == [2, 4, 6]
    end

    test "with list, returns empty list unchanged" do
      result = Utils.apply([], %{}, &(&1 * 2))
      assert result == []
    end

    test "with nil, returns nil unchanged" do
      result = Utils.apply(nil, %{}, &(&1 * 2))
      assert result == nil
    end

    test "with nil, does not call function" do
      Utils.apply(nil, %{}, fn _ ->
        send(self(), :should_not_run)
        :result
      end)

      refute_received :should_not_run
    end

    test "with bare values, applies function to bare struct" do
      result = Utils.apply(%{a: 1}, %{}, &Map.put(&1, :b, 2))
      assert result == %{a: 1, b: 2}
    end

    test "with bare values, applies function to bare map" do
      result = Utils.apply(%{count: 1}, %{}, &Map.update!(&1, :count, fn c -> c + 1 end))
      assert result == %{count: 2}
    end

    test "with {count, list}, maps function over list, preserves count" do
      result = Utils.apply({5, [1, 2, 3]}, %{}, &(&1 * 2))
      assert result == {5, [2, 4, 6]}
    end

    test "with {count, nil}, returns {count, nil} unchanged" do
      result = Utils.apply({5, nil}, %{}, &(&1 * 2))
      assert result == {5, nil}
    end
  end
end
