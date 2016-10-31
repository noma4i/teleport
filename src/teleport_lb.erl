%% Copyright (c) 2016 Contributors as noted in the AUTHORS file
%%
%% This file is part teleport
%%
%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at http://mozilla.org/MPL/2.0/.

-module(teleport_lb).
-author("Benoit Chesneau").

%% API
-export([
  start_link/2,
  connected/2,
  disconnected/1,
  is_connection_up/1,
  conn_status/0,
  random_conn/1,
  hash_conn/2,
  next_conn/1,
  await_connection/2,
  get_config/1
]).


%% gen_server callbacks

-export([
  init/1,
  handle_call/3,
  handle_cast/2,
  handle_info/2,
  terminate/2,
  code_change/3
]).

-record(teleport_lb, {
  name,
  clients = 0,
  num_conns = 0,
  conns = [],
  conns_by_id = #{},
  waiting = []
}).

start_link(Name, Config) ->
  gen_server:start_link({local, Name}, ?MODULE, [Name, Config], []).


connected(Name, {Id, Conn}) ->
  safe_call(Name, {connected, Id, {self(), Conn}}).

disconnected(Name) ->
  safe_call(Name, {disconnected, self()}).

is_connection_up(Name) ->
  case ets:lookup(teleport_lb, Name) of
    [#teleport_lb{num_conns = N}] when N > 0 -> true;
    _ -> false
  end.

await_connection(Name, Timeout) ->
  case is_connection_up(Name) of
    true -> true;
    false ->
      case catch gen_server:call(Name, await, Timeout) of
        true -> true;
        _ -> false
      end
  end.

conn_status() ->
  lists:map(fun(#teleport_lb{name = X_name}) ->
    {X_name, is_connection_up(X_name)}
            end, ets:tab2list(teleport_lb)).

random_conn(Name) ->
  case ets:lookup(teleport_lb, Name) of
    [#teleport_lb{conns = [Conn]}] ->
      {ok, Conn};
    [#teleport_lb{num_conns = N, conns = Conns}] when N > 0 ->
      N2 = rand:uniform(N),
      {ok, lists:nth(N2, Conns)};
    _ ->
      {badrpc, not_connected}
  end.

hash_conn(Name, HashKey) ->
  case ets:lookup(teleport_lb, Name) of
    [#teleport_lb{conns = [Conn]}] ->
      {ok, Conn};
    [#teleport_lb{clients=N, conns_by_id=ById}] ->
      Index = 1 + erlang:phash2(HashKey, N),
      ClientId = teleport_client:client_name(Name, Index),
      case maps:find(ClientId, ById) of
        {ok, Conn} -> {ok, Conn};
        _error-> {badrpc, not_connected}
      end;
    _ ->
      {badrpc, not_connected}
  end.

next_conn(Name) ->
  gen_server:call(Name, next).

get_config(Name) -> safe_call(Name, get_config).

safe_call(Name, Args) ->
  case catch gen_server:call(Name, Args) of
    {'EXIT', {noproc, _}} ->
      {error, not_connected};
    Res ->
      Res
  end.
%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([Name, Config]) ->
  N = case is_map(Config) of
        true -> maps:get(num_connections, Config, 1);
        false -> length(Config)
      end,
  true = ets:insert(teleport_lb, #teleport_lb{name = Name, clients=N}),
  {ok,
    #{name => Name,
      config => Config,
      workers => queue:new()}}.


handle_call({connected, Id, Client}, _From, State = #{ name := Name, workers := Workers}) ->
  Conn2 = case ets:lookup(teleport_lb, Name) of
            [] ->
              #teleport_lb{
                name=Name,
                num_conns=1,
                conns=[Client],
                conns_by_id = #{ Id => Client}
              };
            [Conn = #teleport_lb{num_conns=N, conns=Conns, conns_by_id=ById, waiting=Waiting}] ->
              reply_waiting(lists:reverse(Waiting), true),
              Conn#teleport_lb{
                num_conns = N+1,
                conns = Conns ++ [Client],
                conns_by_id = ById#{Id => Client}
              }
          end,
  true = ets:insert(teleport_lb, Conn2),
  teleport_monitor:connup(Name),
  {reply, ok, State#{workers => queue:in(Client, Workers)}};

handle_call({disconnected, Pid}, _From, State = #{ name := Name}) ->
  case ets:lookup(teleport_lb, Name) of
    [] ->  ok;
    [Conn = #teleport_lb{num_conns = N, conns=Conns}] ->
      Conns1 = lists:filter(
        fun({X_pid, _}) ->
          not (X_pid =:= Pid)
        end, Conns),
       ets:insert(teleport_lb, Conn#teleport_lb{num_conns = N - 1, conns = Conns1})
  end,
  teleport_monitor:conndown(Name),
  {reply, ok, State};

handle_call(next, _From, State = #{workers := Workers}) ->
  case queue:out(Workers) of
    {empty, _} -> {reply, not_connected, State};
    {{value, Client}, Workers1} ->
      {reply, {ok, Client}, State#{workers => queue:in(Client, Workers1)}}
  end;

%% TODO: maybe we should start the client supervisor in the lb
%% so we can catch directly when it exit?
handle_call(await, From, State = #{ name := Name}) ->
  case ets:lookup(teleport_lb, Name) of
    [] ->
      ets:insert(teleport_lb, #teleport_lb{name=Name, waiting=[From]}),
      {noreply, State};
    [#teleport_lb{num_conns = N}] when N > 0 ->
      {reply, true, State};
    [Conn = #teleport_lb{waiting=Waiting}] ->
      ets:insert(teleport_lb, Conn#teleport_lb{waiting=[From|Waiting]}),
      {noreply, State}
  end;

handle_call(get_config, _From, State = #{ config := Config}) ->
  {reply, Config, State};

handle_call(_Request, _From, State) ->
  Reply = ok,
  {reply, Reply, State}.

handle_cast(_Msg, State) ->
  {noreply, State}.

handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, #{ name := Name}) ->
  ets:delete(teleport_lb, Name),
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.


reply_waiting([From|W], Rep) ->
  gen_server:reply(From, Rep),
  reply_waiting(W, Rep);
reply_waiting([], _) ->
  ok.
