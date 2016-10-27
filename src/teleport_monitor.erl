%% Copyright (c) 2016 Contributors as noted in the AUTHORS file
%%
%% This file is part teleport
%%
%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at http://mozilla.org/MPL/2.0/.

-module(teleport_monitor).

-behaviour(gen_server).

-define(TAB, ?MODULE).

-export([
  monitor_conn/1,
  demonitor_conn/1,
  monitor_node/1,
  demonitor_node/1
]).

-export([
  nodeup/1,
  nodedown/1,
  connup/1,
  conndown/1
]).

-export([start_link/0]).

-export([
  init/1,
  handle_call/3,
  handle_cast/2,
  handle_info/2,
  code_change/3,
  terminate/2
]).

-include_lib("stdlib/include/ms_transform.hrl").


%% MONITOR API

monitor_node(Name) ->
  ok = call({monitor_node, self(), Name}),
  case ets:insert_new(?TAB, {self(), m}) of
    true -> cast({monitor_me, self()});
    false -> ok
  end,
  ok.

demonitor_node(Name) -> call({demonitor_node, self(), Name}).

monitor_conn(Name) ->
  ok = call({monitor_conn, self(), Name}),
  case ets:insert_new(?TAB, {self(), m}) of
    true -> cast({monitor_me, self()});
    false -> ok
  end,
  ok.

demonitor_conn(Name) -> call({demonitor_conn, self(), Name}).

%% Internal API

nodeup(Name) ->call({nodeup, Name}).

nodedown(Name) -> call({nodedown, Name}).

connup(Name) -> call({connup, Name}).

conndown(Name) -> call({conndown, Name}).




start_link() ->
  IsNew = create_table(),
  gen_server:start_link({local, ?MODULE}, ?MODULE, [IsNew], []) .


create_table() ->
  case ets:info(?TAB, name) of
    undefined ->
      _ = ets:new(
        ?TAB,
        [ordered_set, named_table, public,
          {write_concurrency, true}, {read_concurrency, true}]
      ),
      true;
    _ ->
      false
  end.


%% gen_server callbacks

init([IsNew]) ->
  case IsNew of
    true -> ok;
    false -> remonitor()
  end,
  {ok, #{}}.


handle_call({connup, Name}=Msg, _From, State) ->
  broadcast(conn, Name, Msg),
  {reply, ok, State};
handle_call({conndown, Name}=Msg, _From, State) ->
  broadcast(conn, Name, Msg),
  {reply, ok, State};

handle_call({nodeup, Name}=Msg, _From, State) ->
  broadcast(node, Name, Msg),
  {reply, ok, State};
handle_call({nodedown, Name}=Msg, _From, State) ->
  broadcast(node, Name, Msg),
  {reply, ok, State};

handle_call({monitor_node, Pid, Name}, _From, State) ->
  ets:insert(?TAB, {{node, Name, Pid}, Pid}),
  {reply, ok, State};
handle_call({monitor_conn, Pid, Name}, _From, State) ->
  ets:insert(?TAB, {{conn, Name, Pid}, Pid}),
  {reply, ok, State};

handle_call({demonitor_node, Pid, Name}, _From, State) ->
  ets:delete(?TAB, {node, Name, Pid}),
  {reply, ok, State};
handle_call({demonitor_conn, Pid, Name}, _From, State) ->
  ets:delete(?TAB, {conn, Name, Pid}),
  {reply, ok, State};


handle_call(_Msg, _From, State) ->
  {reply, bad_call, State}.

handle_cast({monitor_me, Pid}, State) ->
  MRef = erlang:monitor(process, Pid),
  ets:insert(?TAB, {Pid, MRef}),
  {noreply, State};
handle_cast(_Msg, State) ->
  {noreply, State}.

handle_info({'DOWN', _MRef, process, Pid, _Info}, State) ->
  process_is_down(Pid),
  {noreply, State};
handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.


broadcast(Type, Name, Msg) ->
  All = case Type of
          node -> '$all_nodes';
          conn -> '$all_conns'
        end,
  Pattern = ets:fun2ms(
    fun({{T, N, _}, Pid})  when
      (T =:= Type andalso (N =:= Name orelse N =:= All)) ->
      Pid
    end),
  Subs = ets:select(?TAB, Pattern),
  lists:foreach(
    fun(Pid) ->
      catch Pid ! Msg
    end,
    Subs).

process_is_down(Pid) ->
  case ets:lookup(?TAB, Pid) of
    [] -> ok;
    [_] ->
      ets:delete(?TAB, Pid),
      Pattern = ets:fun2ms(fun({{Key, Name, P}, _}) when P =:= Pid -> {Key, Name, P} end),
      Subs = ets:select(?TAB, Pattern),
      lists:foreach(fun(Sub) -> ets:delete(?TAB, Sub) end, Subs)
  end.
  
remonitor() ->
  Pattern = ets:fun2ms(fun({Pid, _}) when is_pid(Pid) -> Pid end),
  Pids = ets:select(?TAB, Pattern),
  lists:foreach(
    fun(Pid) ->
      MRef = erlang:monitor(process, Pid),
      ets:insert(?TAB, {Pid, MRef})
    end, Pids).

call(Msg) -> gen_server:call(?MODULE, Msg).

cast(Msg) -> gen_server:cast(?MODULE, Msg).
