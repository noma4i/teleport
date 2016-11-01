%% Copyright (c) 2016 Contributors as noted in the AUTHORS file
%%
%% This file is part teleport
%%
%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at http://mozilla.org/MPL/2.0/.

-module(teleport_client).
-behaviour(gen_statem).

%% API
-export([
  start_link/3,
  call/6,
  blocking_call/6,
  cast/5,
  abcast/3,
  sbcast/3
]).

-export([
  client_name/2,
  get_connection/1
]).


%% gen_statem callbacks
-export([
  terminate/3,
  code_change/4,
  init/1,
  callback_mode/0
]).

%% states
-export([
  connect/3,
  wait_handshake/3,
  wait_for_data/3
]).

-include("teleport.hrl").

-define(TIMEOUT, 5000).

call(Name, Mod, Fun, Args, Strategy, Timeout) ->
  case do_call(Name, call, Mod, Fun, Args, Strategy) of
    {ok, Headers} -> wait_reply(Headers, Timeout);
    Error -> Error
  end.

cast(Name, Mod, Fun, Args, Strategy) ->
  case do_call(Name, cast, Mod, Fun, Args, Strategy) of
    {ok, _Headers} -> ok;
    Error -> Error
  end.

blocking_call(Name, Mod, Fun, Args, Strategy, Timeout) ->
  case do_call(Name, blocking_call, Mod, Fun, Args, Strategy) of
    {ok, Headers} -> wait_reply(Headers, Timeout);
    Error -> Error
  end.


abcast([Name | Rest], ProcName, Msg) ->
  case teleport_lb:random_conn(Name) of
    {ok, {_Pid, {Transport, Sock}}} ->
      Packet = term_to_binary({abcast, ProcName, Msg}),
      ok = Transport:send(Sock, Packet),
      ok;
    _ -> ok
  end,
  abcast(Rest, ProcName, Msg);
abcast([], _ProcName, _Msg) ->
  abcast.

sbcast(Names, ProcName, Msg) ->
  Parent = self(),
  Pids = lists:map(
    fun(Name) ->
      spawn(fun() -> sbcast_1(Parent, Name, ProcName, Msg) end)
    end, Names),
  wait_for_sbcast(Pids, [], []).

sbcast_1(Parent, Name, ProcName, Msg) ->
  case teleport_lb:random_conn(Name) of
    {ok, {_Pid, {Transport, Sock}}} ->
      Headers =
        #{seq => erlang:unique_integer([positive, monotonic]),
          pid => self()},
      Packet = term_to_binary({sbcast, Headers, ProcName, Msg}),
      case Transport:send(Sock, Packet) of
        ok -> wait_sbcast_reply(Parent, Name, Headers);
        _ -> Parent ! {sbcast_failed, self(), Name}

      end;
    _ ->
      Parent ! {sbcast_failed, self(), Name}
  end.

%% TODO: add timeout?
wait_sbcast_reply(Parent, Name, Headers) ->
  receive
    {sbcast_success, Headers} ->
      Parent ! {sbcast_success, self(), Name};
    {sbcast_failed, Headers} ->
      Parent ! {sbcast_failed, self(), Name}

  end.

wait_for_sbcast([Pid | Rest], Good, Bad) ->
  receive
    {sbcast_success, Pid, Name} ->
      wait_for_sbcast(Rest, [Name | Good], Bad);
    {sbcast_failed, Pid, Name} ->
      wait_for_sbcast(Rest, Good, [Name | Bad])
  end;
wait_for_sbcast([], Good, Bad) ->
  {Good, Bad}.


do_call(Name, CallType, Mod, Fun, Args, Strategy) ->
  Res = case Strategy of
          random -> teleport_lb:random_conn(Name);
          next -> teleport_lb:next(Name);
          {hash, Key} -> teleport_lb:hash_conn(Name, Key)
        end,

  case Res of
    {ok, {_Pid, {Transport, Sock}}} ->
      Headers =
        #{seq => erlang:unique_integer([positive, monotonic]),
          pid => self()},
      Packet = term_to_binary({CallType, Headers, Mod, Fun, Args}),
      case Transport:send(Sock, Packet) of
        ok ->
          {ok, Headers};
        Error ->
          lager:error(
            "teleport: error sending request ~p on ~s: ~w",
            [[CallType, Mod, Fun, Args], Name, Error]
          ),
          Error
      end;
    Error ->
      lager:error("teleport: error while retrieving a connection for ~p", [Name]),
      Error
  end.


wait_reply(Headers, Timeout) ->
  receive
    {call_result, Headers, Res} -> Res
  after Timeout ->
    {error, timeout}
  end.

client_name(Name, I) ->
  list_to_atom(
    ?MODULE_STRING ++ [$-|atom_to_list(Name)] ++ [$-| integer_to_list(I)]
  ).

get_connection(Client) ->
  case catch robust_call(Client, get_connection) of
    {'EXIT', {noproc, _}} -> {badrpc, not_connected};
    Res -> Res
  end.

%% If the gen_statem crashes we want to give the supervisor
%% a decent chance to restart it before failing our calls.
robust_call(Mgr, Req) ->
   robust_call(Mgr, Req, 99). % (99+1)*100ms = 10s

robust_call(Mgr, Req, 0) ->
  gen_statem:call(Mgr, Req, infinity);
robust_call(Mgr, Req, Retries) ->
  try
    gen_statem:call(Mgr, Req, infinity)
  catch exit:{noproc, _} ->
    timer:sleep(100),
    robust_call(Mgr, Req, Retries - 1)
  end.

start_link(Id, Name, Config) ->
  gen_statem:start_link({local, Id}, ?MODULE,[Id, Name, Config], []).

init([Id, Name, Config]) ->
  process_flag(trap_exit, true),
  self() ! connect,
  %% initialize the data
  Host = maps:get(host, Config, "localhost"),
  Port = maps:get(port, Config, ?DEFAULT_PORT),
  Retries = maps:get(retry, Config, 3),
  Transport = teleport_uri:parse_transport(Config),
  {OK, _Closed, _Error} = Transport:messages(),
  Data =
    #{
      name => Name,
      id => Id,
      host => Host,
      port => Port,
      transport => Transport,
      sock => undefined,
      heartbeat => undefined,
      missed_heartbeats => 0,
      conf => Config,
      peer_node => undefined,
      retry => {Retries, 200, ?TIMEOUT},
      ok => OK
    },
  {ok, connect, Data}.

callback_mode() -> state_functions.

terminate(_Reason, _State, Data) ->
  _ = cleanup(Data),
  ok.

code_change(_OldVsn, State, Data, _Extra) ->
  {ok, State, Data}.

connect(info, connect, Data) ->
  #{host := Host,
    port := Port,
    transport := Transport,
    conf := Conf,
    retry := {Retries, Delay, Max}} = Data,

  TransportOpts = case Transport of
              ranch_ssl ->
                [{active, once}, binary, {packet, 4}, {reuseaddr, true}
                | teleport_lib:ssl_conf(client, Host)];
              ranch_tcp ->
                [{active, once}, binary, {packet, 4}, {reuseaddr, true}]
  end,
  ConnectTimeout = maps:get(connect_timeout, Conf, 5000),

  case Transport:connect(Host, Port, TransportOpts, ConnectTimeout) of
    {ok, Sock} ->
      {ok, HeartBeat} = timer:send_interval(5000, self(), heartbeat),
      true = ets:insert(teleport_outgoing_conns, {self(), Host, undefined}),
      Transport:setopts(Sock, [{packet, 4}, {active, once}]),
      Data2 = Data#{sock => Sock, heartbeat => HeartBeat,  missed_heartbeats => 0},
      ok = send_handshake(Data2),
      {next_state, wait_handshake, Data2};
    {error, _Error} ->
      if
        Retries /= 0 ->
          _ = erlang:send_after(Delay, self(), connect),
          {keep_state, Data#{ retry => {Retries - 1, rand_increment(Delay, Max), Max} }};
        true ->
          {stop, normal, Data}
      end
  end;
connect({call, _From}, get_connection, Data) ->
  {keep_state, Data, postpone};
connect(EventType, EventContent, Data) ->
  handle_event(EventType, connect, EventContent,Data).

wait_handshake(info, {OK, Sock, Payload}, Data = #{ transport := Transport, sock := Sock, ok := OK}) ->
  #{name := Name, id := Id, host := Host} = Data,
  try erlang:binary_to_term(Payload) of
    {connected, PeerNode} ->
      lager:info("teleport: client connected to peer-node ~p[~p]~n", [Name, PeerNode]),
      ets:insert(teleport_incoming_conns, {self(), Host, PeerNode}),
      teleport_monitor:nodeup(PeerNode),
      teleport_lb:connected(Name, {Id, {Transport, Sock}}),
      {next_state, wait_for_data, activate_socket(Data#{peer_node => PeerNode})};
    {connection_rejected, Reason} ->
      lager:warning("teleport: connection rejected", [Reason]),
      handle_conn_closed(Data, wait_handshake, {connection_rejected, Reason}),
      {stop, normal, Data};
    heartbeat ->
      {keep_statee, activate_socket(Data#{missed_heartbeats => 0})};
    _OtherMsg ->
      lager:warning("teleport: got unknown message ~p~n", [_OtherMsg]),
      {keep_state, activate_socket(Data)}
  catch
    error:badarg ->
      lager:warning(
        "teleport: client for ~p error during handshake to bad data : ~w",
        [Name, Payload]
      ),
      _ = cleanup(Data),
      {stop, normal, Data}
  end;
wait_handshake({call, _From}, get_connection, Data) ->
  {keep_state, Data, postpone};
wait_handshake(EventType, EventContent, Data) ->
  handle_event(EventType, wait_handshake, EventContent,Data).


wait_for_data({call, From}, get_connection, Data = #{ transport := Transport, sock := Sock}) ->
  Reply = {ok, {self, {Transport, Sock}}},
  {keep_state, Data, [{reply, From, Reply}]};
wait_for_data(info, {OK, Sock, PayLoad}, Data = #{ sock := Sock, ok := OK}) ->
  try erlang:binary_to_term(PayLoad) of
    {call_result, Headers, Result} ->
      #{ pid := Pid} = Headers,
      _ = (catch Pid ! {call_result, Headers, Result}),
      {keep_state, activate_socket(Data)};
    {sbcast_success, Headers = #{ pid := Pid}} ->
      _ = (catch Pid ! {sbcast_success, Headers}),
      {keep_state, activate_socket(Data)};
    {sbcast_failed, Headers = #{ pid := Pid}} ->
      _ = (catch Pid ! {sbcast_failed, Headers}),
      {keep_state, activate_socket(Data)};
    heartbeat ->
      {keep_state, activate_socket(Data#{missed_heartbeats => 0})};
    _Else ->
      {keep_state, activate_socket(Data)}
  catch
    error:badarg ->
      #{ db := Db, host := Host, port:= Port} = Data,
      lager:info(
        "teleport: ~p, tcp error with ~p:~p : ~w",
        [Db, Host, Port, Data]
      ),
    _ = cleanup(Data),
    {stop, normal, Data}
  end;
wait_for_data(EventType, EventContent, Data) ->
  handle_event(EventType, wait_for_data, EventContent ,Data).

handle_event(info, _State, heartbeat, Data) ->
  #{transport := Transport,
    sock := Sock,
    missed_heartbeats := M,
    peer_node := PeerNode} = Data,
  Packet = term_to_binary(heartbeat),
  ok = Transport:send(Sock, Packet),
  M2 = M + 1,
  if
    M2 > 3 ->
      lager:warning("Missed ~p heartbeats from ~p. Closing connection~n", [M2, PeerNode]),
      _ = cleanup(Data),
      {stop, normal, Data};
    true ->
      {keep_state, activate_socket(Data#{missed_heartbeats => M2})}
  end;
handle_event(EventType, State, Event, Data = #{ transport := Transport, sock := Sock }) ->
  {_OK, Closed, Error} = Transport:messages(),
  case Event of
    {Closed, Sock} ->
      handle_conn_closed(Closed, State, Data);
    {Error, Sock, Reason} ->
      handle_conn_closed({Error, Reason}, State, Data);
    _ ->
      lager:error(
        "teleport: client [~p] received an unknown event: ~p ~p",
        [State, Event, EventType]
      ),
      {stop, normal, cleanup(Data)}
  end.

handle_conn_closed(Error, State, Data = #{name := Name, peer_node := PeerNode}) ->
  lager:debug(
    "teleport:lost client connection in ~p from ~p[~p]. Reason: ~p~n",
    [State, Name, PeerNode, Error]
  ),
  {stop, normal, cleanup(Data)}.


send_handshake(State = #{ name := Name}) ->
  Cookie = erlang:get_cookie(),
  Packet = erlang:term_to_binary({connect, Cookie, Name}),
  send(Packet, State).

send(Msg,  #{transport := Transport, sock := Sock}) ->
  Res = Transport:send(Sock, Msg),
  Res.

cleanup(Data) ->
  #{heartbeat := Heartbeat,
    name := Name,
    sock := Sock,
    transport := Transport,
    peer_node := PeerNode} = Data,

  if
    PeerNode =/= undefined -> teleport_monitor:nodedown(PeerNode);
    true -> ok
  end,

  _ = teleport_lb:disconnected(Name),
  catch ets:delete(teleport_incoming_conns, self()),

  catch Transport:close(Sock),
  catch timer:cancel(Heartbeat),

  Data#{
    heartbeat => undefined,
    sock => undefined,
    missed_heartbeats => 0
  }.

rand_increment(N) ->
  %% New delay chosen from [N, 3N], i.e. [0.5 * 2N, 1.5 * 2N]
  Width = N bsl 1,
  N + rand:uniform(Width + 1) - 1.

rand_increment(N, Max) ->
  %% The largest interval for [0.5 * Time, 1.5 * Time] with maximum Max is
  %% [Max div 3, Max].
  MaxMinDelay = Max div 3,
  if
    MaxMinDelay =:= 0 ->
      rand:uniform(Max);
    N > MaxMinDelay ->
      rand_increment(MaxMinDelay);
    true ->
      rand_increment(N)
  end.

activate_socket(Data = #{ transport := Transport, sock := Sock}) ->
  ok = Transport:setopts(Sock, [{active, once}, {packet, 4}]),
  Data.
