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
  start_child/2,
  stop_child/1
]).

%% supervisor callback
-export([init/1]).

start_link() ->
  {ok, Pid} = supervisor:start_link({local, ?MODULE}, ?MODULE, []),
  %% start preconfigured links
  Links = application:get_env(teleport, links, []),
  [start_child(Pid, [Name, Config]) || {Name, Config} <- Links],
  {ok, Pid}.

start_child(LinkSup, Args) when is_list(Args) -> supervisor:start_child(LinkSup, Args);
start_child(_, _) -> erlang:error(badarg).


stop_child(Pid) ->
  supervisor:terminate_child(?MODULE, Pid).

init([]) ->
  {ok, { simple_one_for_one_sup_options(5, 1), [link_spec()] } }.


simple_one_for_one_sup_options(Intensity, Period) ->
  #{
    strategy => simple_one_for_one,
    intensity => Intensity, % Num failures allowed,
    period => Period % Within this many seconds
  }.

link_spec() ->
  #{
    id => teleport_link,
    start => {teleport_link, start_link, []},
    restart => transient,
    shutdown => 2000,
    type => worker,
    modules => [teleport_link]
  }.
