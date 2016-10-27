%% Copyright (c) 2016 Contributors as noted in the AUTHORS file
%%
%% This file is part teleport
%%
%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at http://mozilla.org/MPL/2.0/.

-module(teleport_client).



-export([
  start_link/2,
  call/5,
  blocking_call/5,
  cast/4,
  abcast/3,
  sbcast/3
]).

%% internal callbacks
-export([
  init/3,
  retry_loop/2,
  wait_handshake/1
]).

-export([
  system_continue/3,
  system_terminate/4,
  system_code_change/4
]).

-include("teleport.hrl").


call(Name, Mod, Fun, Args, Timeout) ->
  case do_call(Name, call, Mod, Fun, Args) of
    {ok, Headers} -> wait_reply(Headers, Timeout);
    Error -> Error
  end.

cast(Name, Mod, Fun, Args) ->
  case do_call(Name, cast, Mod, Fun, Args) of
    {ok, _Headers} -> ok;
    Error -> Error
  end.

blocking_call(Name, Mod, Fun, Args, Timeout) ->
  case do_call(Name, blocking_call, Mod, Fun, Args) of
    {ok, Headers} -> wait_reply(Headers, Timeout);
    Error -> Error
  end.


abcast([Name | Rest], ProcName, Msg) ->
  case teleport_lb:get_conn_pid(Name) of
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
  case teleport_lb:get_conn_pid(Name) of
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



do_call(Name, CallType, Mod, Fun, Args) ->
  case teleport_lb:get_conn_pid(Name) of
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
      lager:info("teleport: error while retrieving a connection for ~p", [Name]),
      Error
  end.


wait_reply(Headers, Timeout) ->
  receive
    {call_result, Headers, Res} -> Res
  after Timeout ->
    {error, timeout}
  end.


start_link(Name, Config) ->
  proc_lib:start_link(?MODULE, init, [self(), Name, Config]).


init(Parent, Name, Config) ->
  ok = proc_lib:init_ack(Parent, {ok, self()}),
  process_flag(trap_exit, true),

  Host = maps:get(host, Config, "localhost"),
  Port = maps:get(port, Config, ?DEFAULT_PORT),

  Retry = maps:get(retry, Config, 5),
  Transport = maps:get(transport, Config, ranch_tcp),
  State = #{
    parent => Parent,
    name => Name,
    host => Host,
    port => Port,
    transport => Transport,
    missed_heartbeats => 0,
    conf => Config,
    peer_node => undefined
  },
  connect(State, Retry).

connect(State, Retries) ->
  #{name := Name,
    host := Host,
    port := Port,
    transport := Transport,
    conf := Conf} = State,
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
      teleport_lb:connected(Name, {Transport, Sock}),
      true = ets:insert(teleport_outgoing_conns, {self(), Host, undefined}),

      Transport:setopts(Sock, [{packet, 4}, {active, once}]),
      do_handshake(State#{sock => Sock,
                          heartbeat => HeartBeat,
                          missed_heartbeats => 0});
    {error, _} ->
      retry(State, Retries - 1)
  end.

%% Exit normally if the retry functionality has been disabled.
%% TODO: add exponential backlog
retry(_, 0) ->
  ok;
retry(State, Retries) ->
  retry_loop(State, Retries).

%% Too many retries, give up.
retry_loop(_, 0) ->
  error(gone);
retry_loop(State=#{parent := Parent, conf  := Conf}, Retries) ->
  _ = erlang:send_after(maps:get(retry_timeout, Conf, 5000), self(), retry),
  receive
    retry -> connect(State, Retries);
    {system, From, Request} ->
      sys:handle_system_msg(Request, From, Parent, ?MODULE, [],
        {retry_loop, State, Retries})
  end.

do_handshake(State = #{ name := Name, conf := Conf }) ->
  Cookie = erlang:get_cookie(),
  Packet = erlang:term_to_binary({connect, Cookie, Name}),
  case catch send(Packet, State) of
    ok ->
      wait_handshake(State);
    Error ->
      #{ host := Host, port:= Port} = State,
      lager:error(
        "teleport: error while sending handshake to ~p:~p : ~w",
        [Host, Port, Error]
      ),
      Retry = maps:get(retry, Conf, 5),
      connect(State#{
        heartbeat => undefined,
        sock => undefined,
        missed_heartbeats => 0
      }, Retry)
  end.

wait_handshake(State) ->
  #{parent := Parent,
    name := Name,
    host := Host,
    transport := Transport,
    sock := Sock} = State,
  Transport:setopts(Sock, [{active, once}]),
  {OK, Closed, Error} = Transport:messages(),
  receive
    {OK, Sock, Data} ->
      try erlang:binary_to_term(Data) of
        {connected, PeerNode} ->
          lager:info("teleport: client connected to peer-node ~p[~p]~n", [Name, PeerNode]),
          ets:insert(teleport_incoming_conns, {self(), Host, PeerNode}),
          teleport_monitor:nodeup(PeerNode),
          loop(State#{ peer_node => PeerNode });
        {connection_rejected, Reason} ->
          lager:error("teleport: connection rejected", [Reason]),
          exit({connection_rejected, Reason});
        heartbeat ->
          loop(State#{missed_heartbeats => 0});
        OtherMsg ->
          lager:debug("teleport: got unknown message ~p~n", [OtherMsg]),
          wait_handshake(State)
      catch
        error:badarg ->
          #{ host := Host, port:= Port} = State,
          lager:error(
            "teleport: error during handshake to ~p:~p : ~w",
            [Host, Port, Data]
          ),
          exit({badtcp, invalid_data})
      end;
    heartbeat ->
      handle_heartbeat(State, fun wait_handshake/1);
    {Closed, Sock} ->
      cleanup(State),
      exit(normal);
    {Error, Sock, _Reason} ->
      #{ host := Host, port:= Port} = State,
      lager:error(
        "teleport: tcp error during handshake with ~p:~p : ~w",
        [Host, Port, Error]
      ),
      cleanup(State),
      exit(normal);
    {system, From, Request} ->
      sys:handle_system_msg(Request, From, Parent, ?MODULE, [],
        {wait_handshake, State})
  end.


loop(State = #{parent := Parent, transport := Transport, sock := Sock}) ->
  Transport:setopts(Sock, [{packet, 4}, {active, once}]),
  {OK, Closed, Error} = Transport:messages(),
  receive
    {OK, Sock, Data} ->
      handle_data(Data, State);
    {Closed, Sock} ->
      cleanup(State),
      exit(normal);
    {Error, Sock, Reason} ->
      #{ host := Host, port:= Port} = State,
      lager:error(
        "teleport: tcp error with ~p:~p : ~w",
        [Host, Port, Reason]
      ),
      cleanup(State),
      exit(normal);
    {system, From, Request} ->
      sys:handle_system_msg(Request, From, Parent, ?MODULE, [],
        {loop, State});
    heartbeat ->
      handle_heartbeat(State, fun loop/1);
    Any ->
      lager:info("teleport:client got unknown message: ~p", [Any]),
      loop(State)
  end.

handle_data(Data, State) ->
  try erlang:binary_to_term(Data) of
    {call_result, Headers, Result} ->
      #{ pid := Pid} = Headers,
      _ = (catch Pid ! {call_result, Headers, Result}),
      loop(State);
    {sbcast_success, Headers = #{ pid := Pid}} ->
      _ = (catch Pid ! {sbcast_success, Headers}),
      loop(State);
    {sbcast_failed, Headers = #{ pid := Pid}} ->
      _ = (catch Pid ! {sbcast_failed, Headers}),
      loop(State);
    heartbeat ->
      loop(State#{missed_heartbeats => 0});
    _Else ->
      loop(State)
  catch
      error:badarg ->
        #{ db := Db, host := Host, port:= Port} = State,
        lager:error(
          "teleport: ~p, tcp error with ~p:~p : ~w",
          [Db, Host, Port, Data]
        ),
        exit({badtcp, invalid_data})
  end.


handle_heartbeat(State, Fun) ->
  #{ transport := Transport, sock := Sock, missed_heartbeats := M} = State,
  Packet = term_to_binary(heartbeat),
  ok = Transport:send(Sock, Packet),
  M2 = M + 1,
  if
    M2 > 3 ->
      #{ host := Host, port:= Port} = State,
      lager:info(
        "teleport: client missed ~p heartbeats from ~p:~p. Closing connection",
        [M2, Host, Port]
      ),
      cleanup(State);
    true ->
      Fun(State#{missed_heartbeats => M2})
  end.

system_continue(_, _, {retry_loop, State, Retry}) ->
  retry_loop(State, Retry);
system_continue(_, _, {wait_handshake, State}) ->
  wait_handshake(State);
system_continue(_, _, {loop, State}) ->
  loop(State).

-spec system_terminate(any(), _, _, _) -> no_return().
system_terminate(Reason, _, _, {_, State, _}) ->
  cleanup(State),
  exit(Reason);
system_terminate(Reason, _, _, {_, State}) ->
  cleanup(State),
  exit(Reason).

system_code_change(Misc, _, _, _) ->
  {ok, Misc}.


send(Msg,  #{transport := Transport, sock := Sock}) ->
  Res = Transport:send(Sock, Msg),
  Res.

cleanup(State) ->
  #{conf := Conf,
    heartbeat := Heartbeat,
    name := Name,
    sock := Sock,
    transport := Transport,
    peer_node := PeerNode} = State,
  
  if
    PeerNode =/= undefined -> teleport_monitor:nodedown(PeerNode);
    true -> ok
  end,
  
  _ = teleport_lb:disconnected(Name),
  catch ets:delete(teleport_incoming_conns, self()),

  catch Transport:close(Sock),
  catch timer:cancel(Heartbeat),
  Retry = maps:get(retry, Conf, 5),

  connect(State#{
    heartbeat => undefined,
    sock => undefined,
    missed_heartbeats => 0
  }, Retry).
