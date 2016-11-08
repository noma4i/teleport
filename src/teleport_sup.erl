%% Copyright (c) 2016 Contributors as noted in the AUTHORS file
%%
%% This file is part teleport
%%
%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at http://mozilla.org/MPL/2.0/.

-module(teleport_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%====================================================================
%% API functions
%%====================================================================

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%%====================================================================
%% Supervisor callbacks
%%====================================================================

%% Child :: {Id,StartFunc,Restart,Shutdown,Type,Modules}
init([]) ->
  _ = ets:new(teleport_incoming_conns, [named_table, public]),
  _ = ets:new(teleport_outgoing_conns, [named_table, public]),

  Monitor = #{
    id => teleport_monitor,
    start => {teleport_monitor, start_link, []},
    restart => permanent,
    shutdown => 2000,
    type => worker,
    modules => [teleport_monitor]
  },

  ServerSup = #{
    id => teleport_server_sup,
    start => {teleport_server_sup, start_link, []},
    restart => permanent,
    shutdown => 5000,
    type => supervisor,
    modules => [teleport_server_sup]
  },

  LinkSup = #{
    id => teleport_link_sup,
    start => {teleport_link_sup, start_link, []},
    restart => permanent,
    shutdown => 5000,
    type => supervisor,
    modules => [teleport_link_sup]
  },
  
  {ok, { {one_for_one, 5, 10}, [Monitor, ServerSup, LinkSup]} }.

%%====================================================================
%% Internal functions
%%====================================================================
