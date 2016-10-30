%% Copyright (c) 2016 Contributors as noted in the AUTHORS file
%%
%% This file is part teleport
%%
%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at http://mozilla.org/MPL/2.0/.

-module(teleport_server).
-author("Benoit Chesneau").
-behaviour(gen_server).

%% API
-export([start_link/3])
.
%% gen_server callbacks
-export([init/1,
  handle_call/3,
  handle_cast/2,
  handle_info/2,
  terminate/2,
  code_change/3]).


%%%===================================================================
%%% API
%%%===================================================================

start_link(Server, Name, Config) ->
  gen_server:start_link({local, Server}, ?MODULE, [Name, Config], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
%%%
init([Name, Config]) ->
  process_flag(trap_exit, true),
  {ok, HostName} = inet:gethostname(),
  Host = maps:get(host, Config, HostName),
  Port = maps:get(port, Config, 0),
  NumAcceptors = maps:get(num_acceptors, Config, 100),
  Transport = teleport_uri:parse_transport(Config),
  TransportOpts0 = case Transport of
                     ranch_tcp -> [{backlog, 2048}];
                     ranch_ssl ->
                       Host = maps:get(host, Config, inet:gethostname()),
                       teleport_lib:ssl_conf(server, Host)
                   end,
  TransportOpts = [{port, Port} | TransportOpts0],

  {ok, Listener} = ranch:start_listener(
    Name, NumAcceptors, Transport, TransportOpts,
    teleport_protocol, #{ host => Host, transport => Transport, name => Name}
  ),

  %% link the listener supervisor so we can catch exists
  true = link(Listener),

  {ok, #{ name => Name, listener => Listener}}.

handle_call(_Request, _From, State) -> {reply, ok, State}.

handle_cast(_Msg, State) -> {noreply, State}.

handle_info({'EXIT', Pid, Reason}, #{ listener := Pid} = State) ->
  {stop, Reason, State};
handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, #{ name := Name}) ->
  catch ranch:stop_listener(Name),
  ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.
