defmodule Rajska.QueryScopeAuthorization do
  @moduledoc """
  Absinthe middleware to perform query scoping.

  ## Usage

  [Create your Authorization module and add it and QueryAuthorization to your Absinthe.Schema](https://hexdocs.pm/rajska/Rajska.html#module-usage). Since Scope Authorization middleware must be used with Query Authorization, it is automatically called when adding the former. Then set the scoped module and argument field:

  ```elixir
    mutation do
      field :create_user, :user do
        arg :params, non_null(:user_params)

        # all does not require scoping, since it means anyone can execute this query, even without being logged in.
        middleware Rajska.QueryAuthorization, permit: :all
        resolve &AccountsResolver.create_user/2
      end

      field :update_user, :user do
        arg :id, non_null(:integer)
        arg :params, non_null(:user_params)

        middleware Rajska.QueryAuthorization, [permit: :user, scope: User] # same as [permit: :user, scope: User, args: :id]
        resolve &AccountsResolver.update_user/2
      end

      field :delete_user, :user do
        arg :user_id, non_null(:integer)

        # Providing a map for args is useful to map query argument to struct field.
        middleware Rajska.QueryAuthorization, [permit: [:user, :manager], scope: User, args: %{id: :user_id}]
        resolve &AccountsResolver.delete_user/2
      end

      input_object :user_params do
        field :id, non_null(:integer)
      end

      field :accept_user, :user do
        arg :params, non_null(:user_params)

        middleware Rajska.QueryAuthorization, [
          permit: :user,
          scope: User,
          args: %{id: [:params, :id]},
          rule: :accept_user
        ]
        resolve &AccountsResolver.invite_user/2
      end
    end
  ```

  In the above example, `:all` and `:admin` permissions don't require the `:scope` keyword, as defined in the `c:Rajska.Authorization.not_scoped_roles/0` function, but you can modify this behavior by overriding it.

  ## Options

  All the following options are sent to `c:Rajska.Authorization.has_user_access?/3`:

    * `:scope`
      - `false`: disables scoping
      - `User`: a module that will be passed to `c:Rajska.Authorization.has_user_access?/3`. It must define a struct.
    * `:args`
      - `%{user_id: [:params, :id]}`: where `user_id` is the scoped field and `id` is an argument nested inside the `params` argument.
      - `:id`: this is the same as `%{id: :id}`, where `:id` is both the query argument and the scoped field that will be passed to `c:Rajska.Authorization.has_user_access?/3`
      - `[:code, :user_group_id]`: this is the same as `%{code: :code, user_group_id: :user_group_id}`, where `code` and `user_group_id` are both query arguments and scoped fields.
    * `:optional` (optional) - when set to true the arguments are optional, so if no argument is provided, the query will be authorized. Defaults to false.
    * `:rule` (optional) - allows the same struct to have different rules. See `Rajska.Authorization` for `rule` default settings.
  """

  @behaviour Absinthe.Middleware

  alias Absinthe.Resolution

  alias Rajska.Introspection

  def call(%Resolution{state: :resolved} = resolution, _config), do: resolution

  def call(resolution, [_ | [scope: false]]), do: resolution

  def call(resolution, [{:permit, permission} | scope_config]) do
    not_scoped_roles = Rajska.apply_auth_mod(resolution.context, :not_scoped_roles)

    case Enum.member?(not_scoped_roles, permission) do
      true -> resolution
      false -> scope_user!(resolution, scope_config)
    end
  end

  def scope_user!(%{context: context} = resolution, config) do
    default_rule = Rajska.apply_auth_mod(context, :default_rule)
    rule = Keyword.get(config, :rule, default_rule)
    scope = Keyword.get(config, :scope)
    arg_fields = config |> Keyword.get(:args, :id) |> arg_fields_to_map()
    optional = Keyword.get(config, :optional, false)
    arguments_source = get_arguments_source!(resolution, scope)

    arg_fields
    |> Enum.map(& get_scoped_struct_field(arguments_source, &1, optional, resolution.definition.name))
    |> Enum.reject(&is_nil/1)
    |> has_user_access?(scope, resolution.context, rule, optional)
    |> update_result(resolution)
  end

  defp arg_fields_to_map(field) when is_atom(field), do: Map.new([{field, field}])
  defp arg_fields_to_map(fields) when is_list(fields), do: fields |> Enum.map(& {&1, &1}) |> Map.new()
  defp arg_fields_to_map(field) when is_map(field), do: field

  defp get_arguments_source!(%Resolution{definition: %{name: name}}, nil) do
    raise "Error in query #{name}: no scope argument found in middleware Scope Authorization"
  end

  defp get_arguments_source!(%Resolution{arguments: args}, _scope), do: args

  def get_scoped_struct_field(arguments_source, {scope_field, arg_field}, optional, query_name) do
    case get_scope_field_value(arguments_source, arg_field) do
      nil when optional === true -> nil
      nil when optional === false -> raise "Error in query #{query_name}: no argument #{inspect arg_field} found in #{inspect arguments_source}"
      field_value -> {scope_field, field_value}
    end
  end

  defp get_scope_field_value(arguments_source, fields) when is_list(fields), do: get_in(arguments_source, fields)
  defp get_scope_field_value(arguments_source, field) when is_atom(field), do: Map.get(arguments_source, field)

  defp has_user_access?([], _scope, _context, _rule, true), do: true

  defp has_user_access?(scoped_struct_fields, scope, context, rule, _optional) do
    scoped_struct = scope.__struct__(scoped_struct_fields)

    Rajska.apply_auth_mod(context, :context_user_authorized?, [context, scoped_struct, rule])
  end

  defp update_result(true, resolution), do: resolution

  defp update_result(
    false,
    %Resolution{context: context, definition: %{schema_node: %{type: object_type}}} = resolution
  ) do
    object_type = Introspection.get_object_type(object_type)
    put_error(resolution, Rajska.apply_auth_mod(context, :unauthorized_query_scope_message, [resolution, object_type]))
  end

  defp put_error(resolution, message), do: Resolution.put_result(resolution, {:error, message})
end
