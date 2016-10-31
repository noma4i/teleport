%% Copyright (c) 2016 Contributors as noted in the AUTHORS file
%%
%% This file is part teleport
%%
%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at http://mozilla.org/MPL/2.0/.

-module(teleport).
-author("Benoit Chesneau").

%% API
-export([
  start_server/2,
  stop_server/1,
  server_uri/1,
  connect/1, connect/2,
  disconnect/1,
  start_pool/2,
  stop_pool/1,
  start_group/2, start_pool/3,
  stop_group/1,
  incoming_conns/0,
  outgoing_conns/0,
  call/4,
  call/5,
  call/6,
  cast/4,
  cast/5,
  blocking_call/4,
  blocking_call/5,
  blocking_call/6,
  abcast/3,
  sbcast/3,
  monitor_node/1,
  demonitor_node/1,
  monitor_conn/1,
  demonitor_conn/1,
  monitor_nodes/1,
  monitor_conns/1,
  await_connection/2
]).

-export([default_strategy/0]).

-include("teleport.hrl").

-define(DEFAULT_STRATEGY, random).

-type host() :: inet:socket_address() | inet:hostname().
-type uri() :: string().

-type pool_options() :: #{
  host :=  host(),
  port => inet:port_number(),
  num_connections => non_neg_integer(),
  connect_timeout => non_neg_integer(),
  sup_intensity => non_neg_integer(),
  sup_period => non_neg_integer()
}.

-type server_config() :: #{
  host :=  host(),
  port => inet:port_number(), %% default is 0
  transport => tcp | ssl,
  num_acceptors => non_neg_integer()
}.

-export_types([
  host/0,
  uri/0,
  connect_options/0,
  client_config/0,
  server_config/0
]).

%% @doc start a server that will handle a route
-spec start_server(atom(), server_config()) -> {ok, pid()} |{error, term()}.
start_server(Name, Config) ->
  teleport_server_sup:start_server(Name, Config).

%% @doc stop a server
-spec stop_server(atom()) -> ok.
stop_server(Name) ->
  teleport_server_sup:stop_server(Name).

%% @doc get the server uri that can be used to connect from a client
-spec server_uri(atom()) -> uri().
server_uri(Name) ->
  teleport_server_sup:get_uri(Name).

%% @doc connect to a server using an uri
-spec connect(Uri::uri()) -> boolean().
connect(Uri) when is_list(Uri) ->
  #{ name := Name } = Config = teleport_uri:parse(Uri),
  teleport_conns_sup:connect(Name, Config).

%% @doc connect to a server using an uri
-spec connect(Uri::uri(), pool_options()) -> boolean()
        ; (Name::atom(), pool_options()) -> boolean().
connect(Uri, Options) when is_list(Uri) ->
  #{ name := Name } = Config = teleport_uri:parse(Uri),
  teleport_conns_sup:connect(Name, maps:merge(Config, Options));
connect(Name, Config) when is_atom(Name), is_map(Config) ->
  teleport_conns_sup:connect(Name, Config).

%% @doc disconnect from a server
-spec disconnect(atom()) -> ok.
disconnect(Name) ->
  teleport_conns_sup:disconnect(Name).

-spec start_pool(atom(), uri()) -> {ok, pid()} | {error, term()}.
start_pool(Name, Uri) when is_list(Uri) ->
  Config = teleport_uri:parse(Uri),
  teleport_conns_sup:start_pool(Name, Config#{name => Name});
start_pool(Name, Config) when is_atom(Name) ->
  teleport_conns_sup:start_pool(Name, Config).

start_pool(Name, Uri, Options) ->
  Config = teleport_uri:parse(Uri),
  teleport_conns_sup:start_pool(Name, maps:merge(Config, Options)).

-spec stop_pool(atom()) -> ok.
stop_pool(Name) ->
  teleport_conns_sup:stop_pool(Name).

-spec start_group(atom(), [uri() | pool_options()]) ->
  {ok, pid()} | {error, term()}.
start_group(Name, Group) ->
  teleport_conns_sup:start_pool(Name, Group).

-spec stop_group(atom()) -> ok.
stop_group(Name) ->
  teleport_conns_sup:stop_pool(Name).


%% @doc on a server node list incoming connections
incoming_conns() ->
  lists:usort(
    [Node || {_, _, Node} <- ets:tab2list(teleport_incoming_conns)]).

%% @doc on a client node list outgoing connections
outgoing_conns() ->
  lists:usort(
    [Node || {_, _, Node} <- ets:tab2list(teleport_outgoing_conns)]).

%% @doc wait for a connection to be up
await_connection(Name, Timeout) ->
  teleport_lb:await_connection(Name, Timeout).


%% MONITOR API

%% @doc monitor all nodes
-spec monitor_nodes(boolean()) -> ok.
monitor_nodes(true) -> teleport_monitor:monitor_node('$all_nodes');
monitor_nodes(false) -> teleport_monitor:demonitor_node('$all_nodes').

%% @doc monitor all connections
-spec monitor_conns(boolean()) -> ok.
monitor_conns(true) -> teleport_monitor:monitor_conn('$all_conns');
monitor_conns(false) -> teleport_monitor:demonitor_conn('$all_conns').

%% @doc monitor a node name
monitor_node(Name) -> teleport_monitor:monitor_node(Name).

demonitor_node(Name) -> teleport_monitor:demonitor_node(Name).

monitor_conn(Name) -> teleport_monitor:monitor_conn(Name).

demonitor_conn(Name) -> teleport_monitor:demonitor_conn(Name).


%% RPC API

call(Name, M, F, A) -> call(Name, M, F, A, default_strategy(), 5000).

call(Name, M, F, A, Strategy) -> call(Name, M, F, A, Strategy, 5000).

call(Name, M, F, A, Strategy, Timeout) ->
  teleport_client:call(Name, M, F, A, Strategy, Timeout).

cast(Name, M, F, A) -> cast(Name, M, F, A, default_strategy()).

cast(Name, M, F, A, Strategy) ->
  teleport_client:cast(Name, M, F, A, Strategy).

blocking_call(Name, M, F, A) -> blocking_call(Name, M, F, A, default_strategy(), 5000).

blocking_call(Name, M, F, A, Strategy) -> blocking_call(Name, M, F, A, Strategy, 5000).

blocking_call(Name, M, F, A, Strategy, Timeout) ->
  teleport_client:blocking_call(Name, M, F, A, Strategy, Timeout).

abcast(Names, ProcName, Msg) ->
  teleport_client:abcast(Names, ProcName, Msg).

sbcast(Names, ProcName, Msg) ->
  teleport_client:sbcast(Names, ProcName, Msg).





%% internal

default_strategy() ->
  case application:get_env(teleport, default_strategy) of
    undefined -> random;
    {ok, Strategy} -> Strategy
  end.
