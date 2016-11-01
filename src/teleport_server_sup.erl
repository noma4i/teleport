%% Copyright (c) 2016 Contributors as noted in the AUTHORS file
%%
%% This file is part teleport
%%
%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at http://mozilla.org/MPL/2.0/.

-module(teleport_server_sup).

-export([
  start_server/2,
  stop_server/1,
  get_port/1,
  get_addr/1,
  get_uri/1
]).

-export([start_link/0]).

-export([init/1]).

-include("teleport.hrl").

%%====================================================================
%% API functions
%%====================================================================

start_link() ->
  supervisor:start_link({local, ?MODULE}, ?MODULE, []).

start_server(Name, Config) when is_map(Config) ->
  case supervisor:start_child(?MODULE, server_spec(Name, Config)) of
    {ok, Pid} ->
      lager:info("teleport: start server: ~s", [get_uri(Name)]),
      {ok, Pid};
    {error, {already_started, Pid}} ->
      case teleport_server:get_config(Pid) of
        Config -> {ok, Pid};
        _ -> {error, bad_server_config}
      end
  end;
start_server(Name, Config) when is_list(Config) ->
  start_server(Name, maps:from_list(Config));
start_server(_, _) -> erlang:error(badarg).

stop_server(Name) ->
  Uri = get_uri(Name),
  case supervisor:terminate_child(?MODULE, listener_name(Name)) of
    ok ->
      _ = supervisor:delete_child(?MODULE, listener_name(Name)),
      ranch_server:cleanup_listener_opts(server_name(Name)),
      lager:info("teleport: stopped server ~s~n", [Uri]),
      ok;
    Error ->
      lager:error("teleport: error stopping server ~p~n", [Name]),
      Error
  end.

get_port(Name) -> ranch:get_port(server_name(Name)).

get_addr(Name) -> ranch:get_addr(server_name(Name)).

get_uri(Name) ->
  #{host := Host, transport := Transport} = ranch:get_protocol_options(server_name(Name)),
  Port = get_port(Name),
  UriBin = iolist_to_binary(
    ["teleport.", atom_to_list(teleport_uri:to_transport(Transport)), "://",
      teleport_lib:to_list(Name), "@", Host, ":", integer_to_list(Port)]
  ),
  binary_to_list(UriBin).
  

%%====================================================================
%% Supervisor callbacks
%%====================================================================

%% Child :: {Id,StartFunc,Restart,Shutdown,Type,Modules}
init([]) ->
  Servers = application:get_env(teleport, servers, []),
  Servers1 = case application:get_env(teleport, node_config) of
               undefined -> Servers;
               {ok, NodeConfig} ->
                 [SName, Host] = string:tokens(atom_to_list(node()), "@"),
                 [{SName, [{host, Host}, {port, ?DEFAULT_PORT} | NodeConfig]} | Servers]
             end,
  Specs = lists:map(fun({Name, Config}) ->
      server_spec(Name, Config)
    end, Servers1),
  {ok, {{one_for_one, 1, 5}, Specs}}.

server_spec(Name, Config) ->
  {ok, HostName} = inet:gethostname(),
  Host = maps:get(host, Config, HostName),
  Port = maps:get(port, Config, 0),
  NumAcceptors = maps:get(num_acceptors, Config, 100),
  Transport = teleport_uri:parse_transport(Config),
  TransportOpts0 = case Transport of
                     ranch_tcp -> [{backlog, 2048}];
                     ranch_ssl ->
                       Host = maps:get(host, Config, inet:gethostname()),
                       teleport_lib:ssl_conf(server, Host)
                   end,
  TransportOpts = [{port, Port} | TransportOpts0],

  ranch:child_spec(
    server_name(Name), NumAcceptors, Transport, TransportOpts,
    teleport_protocol, #{ host => Host, transport => Transport, name => Name}
  ).

listener_name(Name) ->
  {ranch_listener_sup, server_name(Name)}.

server_name(Name) ->
  teleport_lib:to_atom("teleport_server" ++ [$_|atom_to_list(Name)]).
