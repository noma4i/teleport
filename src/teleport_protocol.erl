%% Copyright (c) 2016 Contributors as noted in the AUTHORS file
%%
%% This file is part teleport
%%
%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at http://mozilla.org/MPL/2.0/.

-module(teleport_protocol).
-author("Benoit Chesneau").


-export([
  start_link/4,
  init/4
]).

start_link(Ref, Socket, Transport, Opts) ->
  Pid = spawn_link(?MODULE, init, [Ref, Socket, Transport, Opts]),
  {ok, Pid}.


init(Ref, Socket, Transport, _Opts) ->
  ok = ranch:accept_ack(Ref),
  ok = Transport:setopts(Socket, [{active, once}, binary,  {packet, 4}]),
  {ok, Heartbeat} = timer:send_interval(5000, self(), heartbeat),
  {ok, {PeerHost, PeerPort}} = Transport:peername(Socket),
  ets:insert(teleport_incoming_conns, {self(), PeerHost, undefined}),
  State = #{
    transport => Transport,
    sock => Socket,
    heartbeat => Heartbeat,
    missed_heartbeats => 0,
    peer_host => PeerHost,
    peer_port => PeerPort
  },
  wait_for_handshake(State).


wait_for_handshake(State) ->
  #{ transport := Transport, sock := Sock, peer_host := PeerHost} = State,
  Transport:setopts(Sock, [{packet, 4}, {active, once}]),
  {OK, Closed, Error} = Transport:messages(),
  Cookie = erlang:get_cookie(),
  receive
    {OK, Sock, Data} ->
      try erlang:binary_to_term(Data) of
        {connect, ClientCookie, PeerNode}  when ClientCookie =:= Cookie ->
          lager:info("teleport: server connected to peer node: ~p~n", [PeerNode]),
          ets:insert(teleport_incoming_conns, {self(), PeerHost, PeerNode}),
          Packet = erlang:term_to_binary({connected, node()}),
          ok =  Transport:send(Sock, Packet),
          wait_for_data(State);
        {connect, _InvalidCookie} ->
          Packet = erlang:term_to_binary({connection_rejected, invalid_cookie}),
          _ = (catch erlang:send(Sock, Packet)),
          lager:error("teleport: invalid cookie from ~p", [PeerHost]),
          exit({badrpc, invalid_cookie});
        OtherMsg ->
          Packet = erlang:term_to_binary({connection_rejected, {invalid_msg, OtherMsg}}),
          _ = (catch erlang:send(Sock, Packet))
      catch
        error:badarg ->
          lager:error("teleport: bad handshake from ~p: ~w", [PeerHost, Data]),
          exit({badtcp, invalid_data})
      end;
    {Closed, Sock} ->
      handle_conn_closed(Closed, Sock),
      exit(normal);
    {Error, Sock, Reason} ->
      handle_conn_closed({Error, Reason}, State),
      exit(normal);
    heartbeat ->
      handle_heartbeat(State, fun wait_for_handshake/1);
    _Any ->
      wait_for_handshake(State)
  end.


wait_for_data(State) ->
  #{ transport := Transport, sock := Sock} = State,
  Transport:setopts(Sock, [{packet, 4}, {active, once}]),
  {OK, Closed, Error} = Transport:messages(),
  receive
    {OK, Sock, Data} ->
      handle_incoming_data(Data, State);
    heartbeat ->
      handle_heartbeat(State, fun wait_for_data/1);
    {Closed, Sock} ->
      handle_conn_closed(Closed, State),
      exit(normal);
    {Error, Sock, Reason} ->
      handle_conn_closed({Error, Reason}, State),
      exit(normal);
    _Any ->
      wait_for_data(State)
  end.


handle_incoming_data(Data, State) ->
  try erlang:binary_to_term(Data) of
    {call, Headers, Mod, Fun, Args} ->
      _ = spawn(fun() ->
                  worker(Headers, Mod, Fun, Args, State)
                end),
      wait_for_data(State);
    {cast, _Headers, Mod, Fun, Args} ->
      _ = spawn(fun() ->
                  worker(Mod, Fun, Args)
                end),
      wait_for_data(State);
    {blocking_call, Headers, Mod, Fun, Args} ->
      _ = worker(Headers, Mod, Fun, Args, State),
      wait_for_data(State);
    {abcast, ProcName, Msg} ->
      catch ProcName ! Msg,
      wait_for_data(State);
    {sbcast, Headers, ProcName, Msg} ->
      _ = worker(Headers, ProcName, Msg, State),
      wait_for_data(State);
    heartbeat ->
      wait_for_data(State#{ missed_heartbeats => 0});
    OtherMsg ->
      lager:error("teleport: invalid message: ~p~n", [OtherMsg]),
      Packet = erlang:term_to_binary({connection_rejected, unkown_msg}),
      _ = (catch send(State, Packet))
  catch
    error:badarg ->
      lager:debug("teleport: bad data: ~w", [Data]),
      cleanup(State),
      exit({badtcp, invalid_data})
  end.

handle_heartbeat(State, Fun) ->
  #{ transport := Transport, sock := Sock, missed_heartbeats := M} = State,
  Packet = term_to_binary(heartbeat),
  ok = Transport:send(Sock, Packet),
  M2 = M + 1,
  if
    M2 > 3 ->
      lager:info("Missed ~p heartbeats from ~p. Closing connection~n", [M2]),
      Transport:close(Sock),
      ok;
    true ->
      Fun(State#{missed_heartbeats => M2})
  end.

handle_conn_closed(Error, State = #{ peer_host := Host}) ->
  lager:info("Connection from ~p closed. Reason: ~p~n", [Host, Error]),
  cleanup(State).

worker(Mod, Fun, Args) -> apply(Mod, Fun, Args).

worker(Headers, ProcName, Msg, State) ->
  Reply = case catch ProcName ! Msg of
            {'EXIT', _} ->
              {sbcast_failed, Headers};
            Msg ->
              {sbcast_success, Headers}
          end,
  Packet = term_to_binary(Reply),
  ok = send(State, Packet).
  

worker(Headers, Mod, Fun, Args, State) ->
  Result = (catch apply(Mod , Fun, Args)),
  Packet = erlang:term_to_binary({call_result, Headers, Result}),
  ok = send(State, Packet).


send(#{ transport := Transport, sock := Sock}, Packet) ->
  Transport:send(Sock, Packet).

cleanup(#{ transport := Transport, sock := Sock}) ->
  catch ets:delete(teleport_incoming_conns, self()),
  catch Transport:close(Sock),
  ok.
