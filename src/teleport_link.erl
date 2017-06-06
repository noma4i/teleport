%% Copyright (c) 2016 Contributors as noted in the AUTHORS file
%%
%% This file is part teleport
%%
%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at http://mozilla.org/MPL/2.0/.

-module(teleport_link).
-behaviour(gen_statem).

%% API
-export([
  call/5,
  blocking_call/5,
  cast/4,
  abcast/3,
  sbcast/3,
  new_channel/1,
  close_channel/1,
  send_channel/3,
  recv_channel/2
]).

-export([
  start_link/1, start_link/2,
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

-record(channel, {
  id,
  ref,
  pid,
  mref
}).

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
  case get_connection(Name) of
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
  case get_connection(Name) of
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

new_channel(Name) ->
  Ref = make_ref(),
  {ok, ChannelId} = gen_statem:call(Name, {new_channel, Ref}),
  #{ link => Name, id => ChannelId, ref => Ref}.

close_channel(#{ link := Link,  ref := Ref}) ->
  gen_statem:call(Link, {close_channel, Ref}).

send_channel(#{ link := Link, id := Id}, To, Msg) ->
  case get_connection(Link) of
    {ok, {_Pid, {Transport, Sock}}} ->
      Packet = term_to_binary({channel_msg, Id, {To, Msg}}),
      Transport:send(Sock, Packet);
    Error ->
      Error
  end.

recv_channel(#{ link := Link, ref := Ref }, Timeout) ->
  MRef = erlang:monitor(process, whereis(Link)),
  receive
    {channel_msg, Ref, Msg} -> Msg;
    {channel_closed, Ref} -> channel_closed;
    {'DOWN', MRef, _, _, _} -> channel_closed
  after Timeout -> erlang:error(channel_timeout)
  end.

do_call(Name, CallType, Mod, Fun, Args) ->
  case get_connection(Name) of
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

start_link(Config) ->
  gen_statem:start_link(?MODULE, [Config], []).

start_link(Name, Config) ->
  gen_statem:start_link({local, Name}, ?MODULE,[Name, Config], []).

init([Config]) -> init_1(self(), Config);
init([Name, Config]) -> init_1(Name, Config).

init_1(Name, Config) ->
  process_flag(trap_exit, true),
  self() ! connect,
  %% initialize the data
  Host = maps:get(host, Config, "localhost"),
  Port = maps:get(port, Config, ?DEFAULT_PORT),
  Retries = maps:get(retry, Config, 3),
  Transport = teleport_lib:parse_transport(Config),
  {OK, _Closed, _Error} = Transport:messages(),
  Data =
    #{
      name => Name,
      host => Host,
      port => Port,
      transport => Transport,
      sock => undefined,
      heartbeat => undefined,
      missed_heartbeats => 0,
      conf => Config,
      peer_node => undefined,
      retry => {Retries, 200, ?TIMEOUT},
      ok => OK,
      channelid => 0,
      channels => []
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
connect({call, _From}, {new_channel, _}, Data) ->
  {keep_state, Data, postpone};
connect({call, _From}, {close_channel, _}, Data) ->
  {keep_state, Data, postpone};
connect(EventType, EventContent, Data) ->
  handle_event(EventType, connect, EventContent,Data).

wait_handshake(info, {OK, Sock, Payload}, Data = #{ sock := Sock, ok := OK}) ->
  #{name := Name, host := Host} = Data,
  try erlang:binary_to_term(Payload) of
    {connected, PeerNode} ->
      lager:info("teleport: client connected to peer-node ~p[~p]~n", [Name, PeerNode]),
      ets:insert(teleport_incoming_conns, {self(), Host, PeerNode}),
      teleport_monitor:linkup(Name),
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
wait_handshake({call, _From}, {new_channel, _}, Data) ->
  {keep_state, Data, postpone};
wait_handshake({call, _From}, {close_channel, _}, Data) ->
  {keep_state, Data, postpone};
wait_handshake(EventType, EventContent, Data) ->
  handle_event(EventType, wait_handshake, EventContent,Data).


wait_for_data({call, From}, get_connection, Data = #{ transport := Transport, sock := Sock}) ->
  Reply = {ok, {self(), {Transport, Sock}}},
  {keep_state, Data, [{reply, From, Reply}]};
wait_for_data(
  {call, From={Pid, _Tag}}, {new_channel, ChannelRef},
  Data=#{  transport := Transport, sock := Sock, channelid := ChannelId, channels := Channels }
) ->
  Packet = term_to_binary({new_channel, ChannelId}),
  ok = Transport:send(Sock, Packet),
  MRef = erlang:monitor(process, Pid),
  Channel = #channel{id=ChannelId, ref=ChannelRef, pid=Pid, mref=MRef},
  {keep_state, Data#{ channelid => ChannelId+2, channels => [Channel|Channels] },
    [{reply, From, {ok, ChannelId} }]};

wait_for_data(
  {call, From}, {close_channel, ChannelRef},
  Data=#{  transport := Transport, sock := Sock }
) ->
  Data2 = case get_channel_by_ref(ChannelRef, Data) of
            false -> Data;
            Channel ->
              Packet = term_to_binary({close_channel, Channel#channel.id}),
              Transport:send(Sock, Packet),
              erlang:demonitor(Channel#channel.mref, [flush]),
              delete_channel(Channel#channel.id, Data)
          end,
{keep_state, Data2, [{reply, From, ok}]};

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
    {channel_msg, ChannelId, Msg} ->
      %% TODO: we unknown channels, maybe we shouldn't
      case get_channel_by_id(ChannelId, Data) of
        false -> ok;
        #channel{pid=Pid, ref=Ref} -> Pid ! {channel_msg, Ref, Msg}
      end,
      {keep_state, activate_socket(Data)};
    {close_channel, ChannelId} ->
      Data2 = handle_channel_closed(ChannelId, Data),
      {keep_state, activate_socket(Data2)};
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

wait_for_data(
  info, {'DOWN', _Ref, process, Pid, _Info},
  Data = #{ transport := Transport, sock := Sock}
) ->
  Channel = get_channel_by_pid(Pid, Data),
  Packet = term_to_binary({close_channel, Channel#channel.id}),
  Transport:send(Sock, Packet),
  erlang:demonitor(Channel#channel.mref, [flush]),
  Data2 = delete_channel(Channel#channel.id, Data),
  {keep_state, Data2};

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
    {'EXIT', _} ->
      handle_conn_closed(Closed, State, Data);
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

handle_channel_closed(ChannelId, Data) ->
  Channel = get_channel_by_id(ChannelId, Data),
  Channel#channel.pid ! {channel_closed, Channel#channel.ref},
  erlang:demonitor(Channel#channel.mref, [flush]),
  delete_channel(Channel#channel.id, Data).

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
    transport := Transport} = Data,

  _ = teleport_monitor:linkdown(Name),
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

get_channel_by_id(ChannelId, #{ channels := Channels }) ->
  lists:keyfind(ChannelId, #channel.id, Channels).

get_channel_by_ref(ChannelRef, #{ channels := Channels }) ->
  lists:keyfind(ChannelRef, #channel.ref, Channels).

get_channel_by_pid(Pid, #{ channels := Channels }) ->
  lists:keyfind(Pid, #channel.pid, Channels).

delete_channel(ChannelId, Data = #{ channels := Channels }) ->
  Channels2 = lists:keydelete(ChannelId, #channel.id, Channels),
  Data#{ channels => Channels2}.
