defmodule EctoMiddleware.ResolutionTest do
  @moduledoc """
  Tests for EctoMiddleware.Resolution module.
  """
  use ExUnit.Case, async: true

  alias EctoMiddleware.Resolution

  describe "struct fields" do
    test "has :repo field" do
      resolution = %Resolution{repo: MyRepo}
      assert resolution.repo == MyRepo
    end

    test "has :action field" do
      resolution = %Resolution{action: :insert}
      assert resolution.action == :insert
    end

    test "has :args field" do
      resolution = %Resolution{args: [%{id: 1}]}
      assert resolution.args == [%{id: 1}]
    end

    test "has :middleware field" do
      resolution = %Resolution{middleware: [SomeMiddleware]}
      assert resolution.middleware == [SomeMiddleware]
    end

    test "has :entity field" do
      resolution = %Resolution{entity: %{id: 1}}
      assert resolution.entity == %{id: 1}
    end

    test "has :private field" do
      resolution = %Resolution{private: %{key: "value"}}
      assert resolution.private == %{key: "value"}
    end

    test "has :before_input field (v1 compat)" do
      resolution = %Resolution{before_input: %{id: 1}}
      assert resolution.before_input == %{id: 1}
    end

    test "has :before_output field (v1 compat)" do
      resolution = %Resolution{before_output: %{id: 1}}
      assert resolution.before_output == %{id: 1}
    end

    test "has :after_input field (v1 compat)" do
      resolution = %Resolution{after_input: %{id: 1}}
      assert resolution.after_input == %{id: 1}
    end

    test "has :after_output field (v1 compat)" do
      resolution = %Resolution{after_output: %{id: 1}}
      assert resolution.after_output == %{id: 1}
    end
  end

  describe "put_private/3" do
    test "stores value under atom key" do
      resolution = %Resolution{private: %{}}
      resolution = Resolution.put_private(resolution, :my_key, "my_value")

      assert resolution.private[:my_key] == "my_value"
    end

    test "initializes private map when nil" do
      resolution = %Resolution{private: nil}
      resolution = Resolution.put_private(resolution, :my_key, "my_value")

      assert resolution.private == %{my_key: "my_value"}
    end

    test "overwrites existing key" do
      resolution = %Resolution{private: %{my_key: "old"}}
      resolution = Resolution.put_private(resolution, :my_key, "new")

      assert resolution.private[:my_key] == "new"
    end

    test "preserves other keys" do
      resolution = %Resolution{private: %{other: "value"}}
      resolution = Resolution.put_private(resolution, :my_key, "my_value")

      assert resolution.private[:other] == "value"
      assert resolution.private[:my_key] == "my_value"
    end
  end

  describe "get_private/2" do
    test "retrieves stored value" do
      resolution = %Resolution{private: %{my_key: "my_value"}}

      assert Resolution.get_private(resolution, :my_key) == "my_value"
    end

    test "returns nil for missing key" do
      resolution = %Resolution{private: %{}}

      assert Resolution.get_private(resolution, :missing) == nil
    end

    test "returns nil when private is nil" do
      resolution = %Resolution{private: nil}

      assert Resolution.get_private(resolution, :any_key) == nil
    end
  end

  describe "get_private/3" do
    test "returns default for missing key" do
      resolution = %Resolution{private: %{}}

      assert Resolution.get_private(resolution, :missing, :default) == :default
    end

    test "returns stored value over default" do
      resolution = %Resolution{private: %{my_key: "my_value"}}

      assert Resolution.get_private(resolution, :my_key, :default) == "my_value"
    end
  end

  describe "set_before_input/2" do
    test "sets before_input field" do
      resolution = %Resolution{}
      resolution = Resolution.set_before_input(resolution, %{input: true})

      assert resolution.before_input == %{input: true}
    end
  end

  describe "set_before_output/2" do
    test "sets before_output field" do
      resolution = %Resolution{}
      resolution = Resolution.set_before_output(resolution, %{output: true})

      assert resolution.before_output == %{output: true}
    end
  end

  describe "set_after_input/2" do
    test "sets after_input field" do
      resolution = %Resolution{}
      resolution = Resolution.set_after_input(resolution, %{input: true})

      assert resolution.after_input == %{input: true}
    end
  end

  describe "set_after_output/2" do
    test "sets after_output field" do
      resolution = %Resolution{}
      resolution = Resolution.set_after_output(resolution, %{output: true})

      assert resolution.after_output == %{output: true}
    end
  end
end
