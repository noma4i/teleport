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
  monitor_link/1,
  demonitor_link/1
]).

-export([
  start_link/0,
  linkup/1,
  linkdown/1
]).

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

monitor_link(Name) ->
  ok = call({monitor_link, self(), Name}),
  case ets:insert_new(?TAB, {self(), m}) of
    true -> cast({monitor_me, self()});
    false -> ok
  end,
  ok.

demonitor_link(Name) -> call({demonitor_link, self(), Name}).

%% API

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


%% internal API

linkup(Name) ->
  notify({linkup, Name}).

linkdown(Name) ->
  notify({linkdown, Name}).

%% TODO, maybe retry ?
notify(Msg) ->
  case whereis(?MODULE) of
    undefined -> noproc;
    Pid -> Pid ! Msg
  end.

%% gen_server callbacks

init([IsNew]) ->
  case IsNew of
    true -> ok;
    false -> remonitor()
  end,
  {ok, #{}}.


handle_call({monitor_link, Pid, Name}, _From, State) ->
  ets:insert(?TAB, {{link, Name, Pid}, Pid}),
  {reply, ok, State};

handle_call({demonitor_link, Pid, Name}, _From, State) ->
  ets:delete(?TAB, {link, Name, Pid}),
  {reply, ok, State};

handle_call(_Msg, _From, State) ->
  {reply, bad_call, State}.

handle_cast({monitor_me, Pid}, State) ->
  MRef = erlang:monitor(process, Pid),
  ets:insert(?TAB, {Pid, MRef}),
  {noreply, State};
handle_cast(_Msg, State) ->
  {noreply, State}.


handle_info({linkup, _Name}=Msg, State) ->
  broadcast(Msg),
  {noreply, State};
handle_info({linkdown, _Name}=Msg, State) ->
  broadcast(Msg),
  {noreply, State};
handle_info({'DOWN', _MRef, process, Pid, _Info}, State) ->
  process_is_down(Pid),
  {noreply, State};
handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.


broadcast({_LinkState, Name}=Msg) ->
  Pattern = ets:fun2ms(
    fun({{link, N, _}, Pid})  when
      N =:= Name orelse N =:= '$all_links' ->
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
