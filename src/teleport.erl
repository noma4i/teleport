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
  connect/1,
  connect/2,
  disconnect/1,
  incoming_conns/0,
  outgoing_conns/0,
  call/4,
  call/5,
  cast/4,
  blocking_call/4,
  blocking_call/5,
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

-include("teleport.hrl").

-type host() :: inet:socket_address() | inet:hostname().
-type uri() :: string().

-type connect_options() :: #{
  num_connections => non_neg_integer(),
  connect_timeout => non_neg_integer()
}.

-type client_config() :: #{
  host := host(),
  port => inet:port_number(),
  num_connections => non_neg_integer(),
  connect_timeout => non_neg_integer()
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

%% @doc connect to a server
-spec connect(atom(), [client_config()] | client_config()) -> boolean()
        ; (uri(), connect_options()) -> boolean().
connect(Name, Configs) when is_atom(Name) ->
  teleport_conns_sup:connect(Name, Configs);
connect(Uri, Options) when is_list(Uri) ->
  #{name := Name } = HostConfig = teleport_uri:parse(Uri),
  Config = maps:merge(HostConfig, Options),
  teleport_conns_sup:connect(Name, Config).

%% @doc disconnect from a server
-spec disconnect(atom()) -> ok.
disconnect(Name) ->
  teleport_conns_sup:disconnect(Name).

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

call(Name, M, F, A) -> call(Name, M, F, A, 5000).

call(Name, M, F, A, Timeout) ->
  teleport_client:call(Name, M, F, A, Timeout).

cast(Name, M, F, A) ->
  teleport_client:cast(Name, M, F, A).

blocking_call(Name, M, F, A) -> blocking_call(Name, M, F, A, 5000).

blocking_call(Name, M, F, A, Timeout) ->
  teleport_client:blocking_call(Name, M, F, A, Timeout).

abcast(Names, ProcName, Msg) ->
  teleport_client:abcast(Names, ProcName, Msg).

sbcast(Names, ProcName, Msg) ->
  teleport_client:sbcast(Names, ProcName, Msg).





