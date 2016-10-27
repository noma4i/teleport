%% Copyright (c) 2016 Contributors as noted in the AUTHORS file
%%
%% This file is part teleport
%%
%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at http://mozilla.org/MPL/2.0/.

-module(teleport_conns_sup).

%% API
-export([
  start_link/0,
  connect/2,
  disconnect/1
]).

%% Supervisor callbacks
-export([init/1]).


%%====================================================================
%% API functions
%%====================================================================

start_link() ->
  supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%%====================================================================
%% Supervisor callbacks
%%====================================================================

connect(Name, Config) ->
  Spec =conn_spec(Name, Config),

  %% start the load balancer
  case supervisor:start_child(?MODULE, Spec) of
    {error, already_present} -> ok;
    {error, {already_started, _Pid}} -> ok;
    {ok, _Pid} -> ok
  end.

disconnect(Name) ->
  Sup = conn_sup_name(Name),
  _ = supervisor:terminate_child(?MODULE, Sup),
  _ = supervisor:delete_child(?MODULE, Sup),
  ok.


%% Child :: {Id,StartFunc,Restart,Shutdown,Type,Modules}
init([]) ->
  Clients = application:get_env(teleport, clients, []),
  Specs = lists:map(fun({Name, Config}) ->
      conn_spec(Name, Config)
    end, Clients),
  {ok, { {one_for_one, 1, 5}, Specs}}.


conn_sup_name(Name) ->
  list_to_atom(atom_to_list(Name) ++ "-sup").

conn_spec(Name, Config) ->
  Sup = conn_sup_name(Name),
  
  #{id => Sup,
    start => {teleport_conn, start_link, [Sup, Name, Config]},
    restart => permanent,
    shutdown => 2000,
    type => supervisor,
    modules => [teleport_conn]}.
