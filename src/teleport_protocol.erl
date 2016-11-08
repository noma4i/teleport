%% Copyright (c) 2016 Contributors as noted in the AUTHORS file
%%
%% This file is part teleport
%%
%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at http://mozilla.org/MPL/2.0/.

-module(teleport_protocol).
-author("Benoit Chesneau").

-behaviour(gen_statem).
-behaviour(ranch_protocol).

-export([
  start_link/4
]).

-export([
  terminate/3,
  code_change/4,
  init/1,
  callback_mode/0
]).

-export([
  wait_for_handshake/3,
  wait_for_data/3
]).

start_link(Ref, Socket, Transport, Opts) ->
  proc_lib:start_link(?MODULE, init, [{self(), Ref, Socket, Transport, Opts}]).


init({Parent, Ref, Socket, Transport, Opts}) ->
  proc_lib:init_ack(Parent, {ok, self()}),
  ok = ranch:accept_ack(Ref),
  process_flag(trap_exit, true),
  ok = Transport:setopts(Socket, [{active, once}, binary,  {packet, 4}]),
  {ok, Heartbeat} = timer:send_interval(5000, self(), heartbeat),
  {ok, {PeerHost, PeerPort}} = Transport:peername(Socket),
  ets:insert(teleport_incoming_conns, {self(), PeerHost, undefined}),
  {OK, _Closed, _Error} = Transport:messages(),
  #{ host := Host, transport := Transport, name := Name} = Opts,
  Data =
    #{
      transport => Transport,
      sock => Socket,
      heartbeat => Heartbeat,
      missed_heartbeats => 0,
      peer_host => PeerHost,
      peer_port => PeerPort,
      ok => OK,
      name => Name,
      host => Host,
      transport_uri => Transport,
      channels => []
    },
  gen_statem:enter_loop(?MODULE, [], wait_for_handshake,  activate_socket(Data)).

callback_mode() -> state_functions.

terminate(_Reason, _State, Data) ->
  _ = cleanup(Data),
  ok.

code_change(_OldVsn, State, Data, _Extra) ->
  {ok, State, Data}.

wait_for_handshake(info, {OK, Sock, PayLoad}, Data = #{ sock := Sock, ok := OK}) ->
  #{ peer_host := PeerHost} = Data,
  Cookie = erlang:get_cookie(),
  try erlang:binary_to_term(PayLoad) of
    {connect, ClientCookie, PeerNode}  when ClientCookie =:= Cookie ->
      lager:info("teleport: server connected to peer node: ~p~n", [PeerNode]),
      ets:insert(teleport_incoming_conns, {self(), PeerHost, PeerNode}),
      ok = send_handshake(Data),
      {next_state, wait_for_data, activate_socket(Data)};
    {connect, _InvalidCookie} ->
      lager:warning("teleport: invalid cookie from ~p", [PeerHost]),
      {stop, normal, Data};
    heartbeat ->
      {keep_state, activate_socket(Data#{missed_heartbeats => 0})};
    OtherMsg ->
      lager:error(
        "teleport: invalid message from ~p: ~w",
        [PeerHost, OtherMsg]
      ),
      {stop, normal, Data}
  catch
    error:badarg ->
      lager:warning("teleport: bad handshake from ~p: ~w", [PeerHost, Data]),
      {stop, normal, Data}
  end;
wait_for_handshake(EventType, Event, Data) ->
  handle_event(EventType, wait_for_handshake, Event, Data).

wait_for_data(info, {OK, Sock, PayLoad}, Data = #{ sock := Sock, ok := OK, channels := Channels}) ->
  try erlang:binary_to_term(PayLoad) of
    {call, Headers, Mod, Fun, Args} ->
      _ = spawn(fun() -> worker(Headers, Mod, Fun, Args, Data) end),
      {keep_state, activate_socket(Data)};
    {cast, _Headers, Mod, Fun, Args} ->
      _ = spawn(fun() -> worker(Mod, Fun, Args) end),
      {keep_state, activate_socket(Data)};
    {blocking_call, Headers, Mod, Fun, Args} ->
      _ = worker(Headers, Mod, Fun, Args, Data),
      {keep_state, activate_socket(Data)};
    {abcast, ProcName, Msg} ->
      catch ProcName ! Msg,
      {keep_state, activate_socket(Data)};
    {sbcast, Headers, ProcName, Msg} ->
      _ = worker(Headers, ProcName, Msg, Data),
      {keep_state, activate_socket(Data)};
    {new_channel, ChannelId} ->
      Pid = spawn_link(fun() -> channel(ChannelId, Data) end),
      Data2 = Data#{ channels := [{ChannelId, Pid} | Channels] },
      {keep_state, activate_socket(Data2)};
    {channel_msg, ChannelId, Msg} ->
      handle_channel_msg(ChannelId, Msg, Data),
      {keep_state, activate_socket(Data)};
    {close_channel, ChannelId} ->
      Data2 = handle_channel_closed(ChannelId, Data),
      {keep_state, activate_socket(Data2)};
    heartbeat ->
      {keep_state, activate_socket(Data#{missed_heartbeats => 0})};
    OtherMsg ->
      lager:error("teleport: invalid message: ~p~n", [OtherMsg]),
      {stop, error, normal}
  catch
    error:badarg ->
      lager:warning("teleport: bad data: ~w", [Data]),
      cleanup(Data),
      {stop, normal, Data}
  end;

wait_for_data(EventType, Event, Data) ->
  handle_event(EventType, wait_for_data, Event, Data).

handle_event(info, _State, heartbeat, Data) ->
  #{transport := Transport,
    sock := Sock,
    missed_heartbeats := M,
    peer_host := PeerHost} = Data,
  Packet = term_to_binary(heartbeat),
  ok = Transport:send(Sock, Packet),
  M2 = M + 1,
  if
    M2 > 3 ->
      lager:warning("Missed ~p heartbeats from ~p. Closing connection~n", [M2, PeerHost]),
      _ = cleanup(Data),
      {stop, normal, Data};
    true ->
      {keep_state, activate_socket(Data#{missed_heartbeats => M2})}
  end;
handle_event(info, _State, {'EXIT', Pid, _Reason}, Data = #{ channels := Channels }) ->
  case lists:keyfind(Pid, 2, Channels) of
    {ChannelId, Pid} ->
      Data2 = Data#{ channels => delete_channel(ChannelId, Channels) },
      {keep_state, activate_socket(Data2)};
    false ->
      {keep_state, activate_socket(Data)}
  end;
handle_event(EventType, State, Event, Data) ->
  #{ transport := Transport, sock := Sock } = Data,
  {_OK, Closed, Error} = Transport:messages(),
  case Event of
    {Closed, Sock} ->
      handle_conn_closed(Closed, State, Data);
    {Error, Sock, Reason} ->
      handle_conn_closed({Error, Reason}, State, Data);
    _ ->
      lager:error(
        "teleport: server [~p] received an unknown event: ~p ~p",
        [State, Event, EventType]
      ),
      {stop, normal, cleanup(Data)}
    end.

handle_conn_closed(Error, State, Data = #{ peer_host := Host}) ->
  lager:debug("teleport: connection from ~p closed (~p). Reason: ~p~n", [Host, State, Error]),
  {stop, normal, cleanup(Data)}.

worker(Mod, Fun, Args) -> apply(Mod, Fun, Args).

worker(Headers, ProcName, Msg, Data) ->
  Reply = case catch ProcName ! Msg of
            {'EXIT', _} ->
              {sbcast_failed, Headers};
            Msg ->
              {sbcast_success, Headers}
          end,
  Packet = term_to_binary(Reply),
  ok = send(Data, Packet).

worker(Headers, Mod, Fun, Args, Data) ->
  Result = (catch apply(Mod , Fun, Args)),
  Packet = erlang:term_to_binary({call_result, Headers, Result}),
  ok = send(Data, Packet).


channel(ChannelId, Data) ->
  receive
    {channel_msg, ChannelId, {To, '$channel_register'}} ->
      To ! {'$channel_register', ChannelId, self()},
      channel(ChannelId, Data);
    {channel_msg, ChannelId, {To, '$channel_unregister'}} ->
      To ! {'$channel_unregister', ChannelId, self()},
      channel(ChannelId, Data);
    {channel_msg, ChannelId, {To, {'$channel_req', Msg}}} ->
      To ! {'$channel_req', ChannelId, self(), Msg},
      channel(ChannelId, Data);
    {channel_msg, ChannelId, {To, Msg}} ->
      To ! Msg,
      channel(ChannelId, Data);
    {channel_closed, ChannelId} ->
      exit(normal);
    Msg ->
      Packet = erlang:term_to_binary({channel_msg, ChannelId, Msg}),
      ok = send(Data, Packet),
      channel(ChannelId, Data)
  end.


get_channel_by_id(ChannelId, #{ channels := Channels }) ->
  lists:keyfind(ChannelId, 1, Channels).

delete_channel(ChannelId, Data = #{ channels := Channels }) ->
  Channels2 = lists:keydelete(ChannelId, 1, Channels),
  Data#{ channels => Channels2}.

handle_channel_msg(ChannelId, Msg, Data) ->
  case get_channel_by_id(ChannelId, Data) of
    {ChannelId, Pid} ->
      Pid ! {channel_msg, ChannelId, Msg};
    false ->
      ok
  end.

handle_channel_closed(ChannelId, Data) ->
  case get_channel_by_id(ChannelId, Data) of
    {ChannelId, Pid} ->
      Pid ! {channel_closed, ChannelId},
      delete_channel(ChannelId, Data);
    false ->
      ok
  end.

activate_socket(Data = #{ transport := Transport, sock := Sock}) ->
  ok = Transport:setopts(Sock, [{active, once}, {packet, 4}]),
  Data.

send_handshake(#{name := Name, host := Host, transport := T, sock := S}) ->
  {ok, {_, Port}} = T:sockname(S),
  Node = binary_to_atom(
    iolist_to_binary(
      [teleport_lib:to_list(Name), "@", Host, ":", integer_to_list(Port)]
    ),
    latin1
  ),
  Packet = erlang:term_to_binary({connected, Node}),
  T:send(S, Packet).

send(#{ transport := Transport, sock := Sock}, Packet) ->
  Transport:send(Sock, Packet).

cleanup(State = #{ transport := Transport, sock := Sock}) ->
  catch ets:delete(teleport_incoming_conns, self()),
  catch Transport:close(Sock),
  State.
