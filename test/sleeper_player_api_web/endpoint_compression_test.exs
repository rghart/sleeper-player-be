defmodule SleeperPlayerApiWeb.EndpointCompressionTest do
  use ExUnit.Case, async: true

  alias SleeperPlayerApiWeb.Endpoint

  # `Phoenix.ConnTest` calls the plug pipeline directly and never starts
  # Cowboy, so no request test can see a `content-encoding` header. The
  # honest end-to-end check is a real request against a real server, and
  # it lives in the PR body and `DEPLOY.md`, not here.
  #
  # What *is* testable is the step that silently swallowed the first
  # attempt at this. `:stream_handlers` is a top-level `Plug.Cowboy`
  # option, not a Cowboy protocol option, so
  # `protocol_options: [stream_handlers: [:cowboy_compress_h, ...]]` —
  # which is what the plan and every blog post suggest — parses, boots,
  # serves traffic, and compresses nothing, because `Plug.Cowboy.args/4`
  # merges its own defaults over the nested list. Running that merge over
  # the real endpoint config is the difference between "the config looks
  # right" and "the handler is actually installed".
  # Read through `Endpoint.init/2` rather than straight from the app env,
  # so the https listener carries the cert options `SiteEncrypt` merges in
  # — both because `Plug.Cowboy` refuses to build args without them, and
  # because that merge is the other thing in this config that could drop
  # `compress` on its way to Cowboy.
  defp listener_opts(scheme) do
    {:ok, config} =
      Endpoint.init(:supervisor, Application.fetch_env!(:sleeper_player_api, Endpoint))

    config[scheme]
  end

  for scheme <- [:http, :https] do
    test "the #{scheme} listener really installs cowboy's compress handler" do
      listener_opts = listener_opts(unquote(scheme))

      [_ref, _transport_options, protocol_options] =
        Plug.Cowboy.args(unquote(scheme), Endpoint, [], listener_opts)

      assert :cowboy_compress_h in protocol_options.stream_handlers,
             "expected :cowboy_compress_h in #{inspect(protocol_options.stream_handlers)}"
    end
  end
end
