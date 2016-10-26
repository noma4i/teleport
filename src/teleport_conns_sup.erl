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

-include("teleport.hrl").


%%====================================================================
%% API functions
%%====================================================================

start_link() ->
  supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%%====================================================================
%% Supervisor callbacks
%%====================================================================

connect(Name, Config) ->
  %% start the load balancer
  case supervisor:start_child(?MODULE, lb_spec(Name)) of
    {error, already_present} -> ok;
    {error, {alread_started, _Pid}} -> ok;
    {ok, _Pid} ->
      lists:foreach(
        fun(Spec) ->
          supervisor:start_child(?MODULE, Spec)
        end, client_specs(Name, Config))
  end.

disconnect(Name) ->
  Children = supervisor:which_children(?MODULE),
  lists:foreach(
    fun({{'teleport_lb', X_Name}=LbId, _, _, _}) when X_Name =:= Name ->
          _ = supervisor:terminate_child(?MODULE, LbId),
          _ = supervisor:delete_child(?MODULE, LbId);
       ({{'teleport_client', X_Name, _, _}=ClientId, _, _, _}) when X_Name =:= Name ->
         _ = supervisor:terminate_child(?MODULE, ClientId),
         _ = supervisor:delete_child(?MODULE, ClientId)
    end, Children),
  ok.


%% Child :: {Id,StartFunc,Restart,Shutdown,Type,Modules}
init([]) ->
  Clients = application:get_env(teleport, clients, []),
  Specs = lists:map(fun({Name, Config}) ->
      [lb_spec(Name) | client_specs(Name, Config)]
    end, Clients),
  {ok, {{one_for_one, 1, 5}, Specs}}.


lb_spec(Name) ->
  #{id => {'teleport_lb', Name},
    start => {teleport_lb, start_link, [Name]},
    restart => temporary,
    shutdown => 5000,
    type => worker,
    modules => [teleport_lb]
  }.

client_specs(Name, Config) ->
  Configs = case is_map(Config) of
              true -> [Config];
              false when is_list(Config) -> Config;
              false -> error(badarg)
            end,
  
  
  ClientSpecs = lists:map(
    fun(Conf) ->
      NumClients = maps:get(num_connections, Conf, 1),
      Host = maps:get(host, Conf, "localhost"),
      Port = maps:get(port, Conf, ?DEFAULT_PORT),
      lists:map(
        fun(I) ->
          client_spec({'teleport_client', Name, {Host, Port}, I}, Name, Config)
        end,lists:seq(1, NumClients))
    end, Configs),
  lists:flatten(ClientSpecs).


client_spec(Id, Name, Config) ->
  #{id => Id,
    start => {teleport_client, start_link, [Name, Config]},
    restart => permanent,
    shutdown => 2000,
    type => worker,
    modules => [teleport_client]}.
