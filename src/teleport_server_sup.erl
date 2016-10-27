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
  stop_server/1
]).

-export([start_link/0]).

-export([init/1]).

-include("teleport.hrl").

%%====================================================================
%% API functions
%%====================================================================

start_link() ->
  supervisor:start_link({local, ?MODULE}, ?MODULE, []).


%%====================================================================
%% Supervisor callbacks
%%====================================================================

start_server(Name, Config) when is_map(Config) ->
  case supervisor:start_child(?MODULE, server_spec(server_name(Name), Config)) of
    {ok, Pid} -> {ok, Pid};
    {error, {already_started, Pid}} -> {ok, Pid}
  end;
start_server(Name, Config) when is_list(Config) ->
  start_server(Name, maps:from_list(Config));
start_server(_, _) -> erlang:error(badarg).

stop_server(Name) ->
  supervisor:terminate_child(?MODULE, server_name(Name)).

%% Child :: {Id,StartFunc,Restart,Shutdown,Type,Modules}
init([]) ->
  Servers = application:get_env(teleport, servers, []),
  Specs = lists:map(fun({Name, Config}) ->
      server_spec(Name, Config)
    end, Servers),
  {ok, {{one_for_one, 1, 5}, Specs}}.


server_spec(Name, Config) ->
  Host = maps:get(host, Config, "localhost"),
  Port = maps:get(port, Config, ?DEFAULT_PORT),
  NumAcceptors = maps:get(num_acceptors, Config, 100),
  Transport = teleport_lib:get_transport(maps:get(transport, Config, tcp)),
  TransportOpts0 = case Transport of
                     ranch_tcp -> [{backlog, 2048}];
                     ranch_ssl ->
                       Host = maps:get(host, Config, "localhost"),
                       teleport_lib:ssl_conf(server, Host)
                   end,
  TransportOpts = [{port, Port} | TransportOpts0],

  ranch:child_spec(Name, NumAcceptors, Transport, TransportOpts,
   teleport_protocol, []).


server_name(Name) ->
  list_to_atom("teleport_server" ++ [$_|atom_to_list(Name)]).
