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
  monitor_conns/1
]).

-include("teleport.hrl").

start_server(Name, Config) ->
  teleport_server_sup:start_server(Name, Config).

stop_server(Name) ->
  teleport_server_sup:stop_server(Name).


connect(Name) when is_atom(Name) ->
  [_, Host] = string:tokens(atom_to_list(Name), "@"),
  connect(Name, #{host => Host, port => ?DEFAULT_PORT}).

connect(Name, Config) ->
  Self = self(),
  PassiveMonitor = spawn_link(
    fun() ->
        teleport_monitor:monitor_conn(Name),
        receive
          {connup, Name} -> Self ! {self(), ok}
        after 30000 ->
          Self ! {self(), timeout},
          teleport_monitor:demonitor_conn(Name)
        end
      end),
  case teleport_conns_sup:connect(Name, Config) of
    ok ->
      receive
        {PassiveMonitor, ok} -> ok;
        {PassiveMonitor, timeout} -> {error, timeout}
      end;
    Error ->
      exit(PassiveMonitor, kill),
      Error
  end.

disconnect(Name) ->
  teleport_conns_sup:disconnect(Name).

incoming_conns() ->
  lists:usort(
    [Node || {_, _, Node} <- ets:tab2list(teleport_incoming_conns)]).

outgoing_conns() ->
  lists:usort(
    [Node || {_, _, Node} <- ets:tab2list(teleport_outgoing_conns)]).


%% MONITOR API

monitor_nodes(true) -> teleport_monitor:monitor_node('$all_nodes');
monitor_nodes(false) -> teleport_monitor:demonitor_node('$all_nodes').

monitor_conns(true) -> teleport_monitor:monitor_conn('$all_conns');
monitor_conns(false) -> teleport_monitor:demonitor_conn('$all_conns').


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





