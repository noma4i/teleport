%% Copyright (c) 2016 Contributors as noted in the AUTHORS file
%%
%% This file is part teleport
%%
%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at http://mozilla.org/MPL/2.0/.


-module(teleport_link_sup).
-author("Benoit Chesneau").

%% API
-export([
  start_link/0,
  link_spec/2
]).

%% supervisor callback
-export([init/1]).

start_link() ->
  supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
  Links = application:get_env(teleport, links, []),
  Specs = lists:map(
    fun({Name, Config}) ->
      link_spec(Name, Config)
    end, Links),
  {ok, {{one_for_one, 1, 5}, Specs}}.

link_spec(Name, Config) ->
  #{id => Name,
    start => {teleport_link, start_link, [Name, Config]},
    restart => transient,
    shutdown => 2000,
    type => worker,
    modules => [teleport_link]}.
