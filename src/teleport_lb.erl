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
  start_link/1,
  connected/2,
  disconnected/1,
  is_connection_up/1,
  conn_status/0,
  get_conn_pid/1,
  get_conn_pid/2
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

-record(teleport_lb, {name, num_conns = 0, conns = []}).

start_link(Name) ->
  gen_server:start_link({local, Name}, ?MODULE, [Name], []).


connected(Name, Conn) ->
  safe_call(Name, {connected, {self(), Conn}}).

disconnected(Name) ->
  safe_call(Name, {disconnected, self()}).

is_connection_up(Name) ->
  case ets:lookup(teleport_lb, Name) of
    [#teleport_lb{num_conns = N}] when N > 0 -> true;
    _ -> false
  end.

conn_status() ->
  lists:map(fun(#teleport_lb{name = X_name}) ->
    {X_name, is_connection_up(X_name)}
            end, ets:tab2list(teleport_lb)).

get_conn_pid(Name) -> get_conn_pid(Name, rand).

get_conn_pid(Name, rand) ->
  case ets:lookup(teleport_lb, Name) of
    [#teleport_lb{conns = [Conn]}] ->
      {ok, Conn};
    [#teleport_lb{num_conns = N, conns = Conns}] when N > 0 ->
      N = generate_rand_int(N),
      {ok, lists:nth(N, Conns)};
    _ ->
      {badrpc, not_connected}
  end;
get_conn_pid(Name, lb) ->
  gen_server:call(Name, get_connection_pid).

%% TODO: use the rand module?
generate_rand_int(Range) ->
  {_, _, Int} = erlang:timestamp(),
  generate_rand_int(Range, Int).

generate_rand_int(Range, Int) ->
  (Int rem Range) + 1.

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

init([Name]) ->
  true = ets:insert(teleport_lb, #teleport_lb{name = Name}),
  {ok,
    #{name => Name,
      workers => queue:new()}}.


handle_call({connected, Client}, _From, State = #{ name := Name, workers := Workers}) ->
  Conn2 = case ets:lookup(teleport_lb, Name) of
            [] -> #teleport_lb{name=Name, num_conns=1, conns=[Client]};
            [Conn = #teleport_lb{num_conns=N, conns=Conns}] ->
              Conn#teleport_lb{num_conns = N+1, conns = Conns ++ [Client]}
          end,
  true = ets:insert(teleport_lb, Conn2),
  {reply, ok, State#{workers => queue:in(Client, Workers)}};

handle_call({disconnected, Pid}, _From, State = #{ name := Name}) ->
  case ets:lookup(teleport_lb, Name) of
    [] ->  ok;
    [Conn = #teleport_lb{num_conns = N, conns=Conns}] ->
      case lists:filter(
          fun({X_pid, _, _}) ->
            not (X_pid =:= Pid) end,
          Conns) of
        Conns ->
          ok;
        [] ->
          ets:delete(teleport_lb, Name);
        Conns1 ->
          ets:insert(teleport_lb, Conn#teleport_lb{num_conns = N - 1, conns = Conns1})
      end
  end,
  {reply, ok, State};

handle_call(get_conn_pid, _From, State = #{workers := Workers}) ->
  case queue:out(Workers) of
    {empty, _} -> {reply, not_connected, State};
    {{value, Client}, Workers1} ->
      {reply, {ok, Client}, State#{workers => queue:in(Client, Workers1)}}
  end;

handle_call(_Request, _From, State) ->
  Reply = ok,
  {reply, Reply, State}.

handle_cast(_Msg, State) ->
  {noreply, State}.

handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.
