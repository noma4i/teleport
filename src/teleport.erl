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
  system_uri/1,
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
  monitor_link/1,
  demonitor_link/1,
  monitor_links/1
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

%% @doc start a system.  A system is a hierarchical group of processes which
%% share common configuration. It is also the entry point for registering or
%% looking up proceses.
-spec start_server(atom(), server_config()) -> {ok, pid()} |{error, term()}.
start_server(Name, Config) ->
  teleport_server_sup:start_server(Name, Config).

%% @doc stop a system
-spec stop_server(atom()) -> ok.
stop_server(Name) ->
  teleport_server_sup:stop_server(Name).

%% @doc get the server uri that can be used to connect from a client
-spec system_uri(atom()) -> uri().
system_uri(Name) ->
  teleport_server_sup:get_uri(Name).

%% @doc connect to a server using an uri
-spec connect(Uri::uri(), pool_options()) -> boolean()
        ; (Name::atom(), pool_options()) -> boolean().
connect(Name, Uri) when is_atom(Name), is_list(Uri) ->
  Config = teleport_uri:config_from_uri(Uri),
  connect(Name, Config);
connect(Name, Config) when is_atom(Name), is_map(Config) ->
  Spec = teleport_link_sup:link_spec(Name, Config),
  case supervisor:start_child(teleport_link_sup, Spec) of
    {ok, _Pid} -> true;
    {error, {already_started, _Pid}} -> false;
    Error -> Error
  end.

%% @doc disconnect a link
-spec disconnect(atom()) -> ok.
disconnect(Name) ->
  case supervisor:terminate_child(teleport_link_sup, Name) of
    ok ->
      _ = supervisor:delete_child(teleport_link_sup, Name),
      ok;
    Error ->
      Error
  end.


%% @doc on a server node list incoming connections
incoming_conns() ->
  lists:usort(
    [Node || {_, _, Node} <- ets:tab2list(teleport_incoming_conns)]).

%% @doc on a client node list outgoing connections
outgoing_conns() ->
  lists:usort(
    [Node || {_, _, Node} <- ets:tab2list(teleport_outgoing_conns)]).

%% MONITOR API

%% @doc monitor all links
-spec monitor_links(boolean()) -> ok.
monitor_links(true) -> teleport_monitor:monitor_link('$all_links');
monitor_links(false) -> teleport_monitor:monitor_link('$all_links').

%% @doc monitor a link
monitor_link(Name) -> teleport_monitor:monitor_link(Name).

demonitor_link(Name) -> teleport_monitor:demonitor_link(Name).


%% RPC API

call(Name, M, F, A) -> call(Name, M, F, A, 5000).

call(Name, M, F, A, Timeout) ->
  teleport_link:call(Name, M, F, A, Timeout).

cast(Name, M, F, A) ->
  teleport_link:cast(Name, M, F, A).

blocking_call(Name, M, F, A) -> blocking_call(Name, M, F, A, 5000).

blocking_call(Name, M, F, A, Timeout) ->
  teleport_link:blocking_call(Name, M, F, A, Timeout).

abcast(Names, ProcName, Msg) ->
  teleport_link:abcast(Names, ProcName, Msg).

sbcast(Names, ProcName, Msg) ->
  teleport_link:sbcast(Names, ProcName, Msg).


%% internal

default_strategy() ->
  case application:get_env(teleport, default_strategy) of
    undefined -> random;
    {ok, Strategy} -> Strategy
  end.
