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
  case supervisor:start_child(?MODULE, server_spec(server_name(Name), Name, Config)) of
    {ok, Pid} ->
      lager:info("teleport: start server: ~s", [get_uri(Name)]),
      {ok, Pid};
    {error, {already_started, Pid}} ->
      {ok, Pid}
  end;
start_server(Name, Config) when is_list(Config) ->
  start_server(Name, maps:from_list(Config));
start_server(_, _) -> erlang:error(badarg).

stop_server(Name) ->
  Server = server_name(Name),
  Uri = get_uri(Name),
  case supervisor:terminate_child(?MODULE, Server) of
    ok ->
      _ = supervisor:delete_child(?MODULE, Server),
      _ = ranch_server:cleanup_listener_opts(Server),
      lager:info("teleport: stopped server ~s~n", [Uri]),
      ok;
    Error ->
      lager:error("teleport: error stopping server ~p~n", [Name]),
      Error
  end.

get_port(Name) -> ranch:get_port(Name).

get_addr(Name) -> ranch:get_addr(Name).

get_uri(Name) ->
  #{host := Host, transport := Transport} = ranch:get_protocol_options(Name),
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
      server_spec(server_name(Name), Name, Config)
    end, Servers1),
  {ok, {{one_for_one, 1, 5}, Specs}}.

server_spec(ServerName, Name, Config) ->
  #{id => ServerName,
    start => {teleport_server, start_link, [ServerName, Name, Config]},
    restart => permanent,
    shutdown => 2000,
    type => worker,
    modules => [teleport_server]}.


server_name(Name) ->
  teleport_lib:to_atom("teleport_server" ++ [$_|atom_to_list(Name)]).
