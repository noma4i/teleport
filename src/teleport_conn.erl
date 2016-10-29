%% Copyright (c) 2016 Contributors as noted in the AUTHORS file
%%
%% This file is part teleport
%%
%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at http://mozilla.org/MPL/2.0/.

-module(teleport_conn).
-author("Benoit Chesneau").

%% API
-export([start_link/3]).

%% supervisor callback
-export([init/1]).


start_link(Sup, Name, Config) ->
  supervisor:start_link({local, Sup}, ?MODULE, [Name, Config]).

init([Name, Config]) ->
  LbSpec =
    #{id => {'teleport_lb', Name},
      start => {teleport_lb, start_link, [Name]},
      restart => permanent,
      shutdown => 2000,
      type => worker,
      modules => [teleport_lb]
    },

  ClientSup =
    #{id => {'teleport_client_sup', Name},
      start => {teleport_client_sup, start_link, [Name, Config]},
      restart => permanent,
      shutdown => 2000,
      type => supervisor,
      modules => [teleport_client_sup]
    },

  {ok, {{one_for_all, 5, 60}, [LbSpec, ClientSup]}}.
